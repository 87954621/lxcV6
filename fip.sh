#!/bin/sh
# fip-v3.2.sh — 只造假网桥：一段假 /64 + 假 IPv4 池，容器/地址分配交给面板
#
# 和 HE tunnelbroker 一样：你只负责把一段 /64 配到一个网桥上，
# 后面谁要用（面板 routed、容器挂网卡、你自己 ip addr add）都不归它管。
#
#   incus network create kp \
#     ipv4.address=175.45.176.1/22 ipv4.nat=false \
#     ipv6.address=2606:54c1:1:c4::1/64 ipv6.nat=false
#
# 本脚本**不碰** profile、不碰容器、不写任何文件。
# 版本规则：每次改动 +0.1，新建文件，旧版本保留（fip-v3.2.sh → fip-v3.3.sh）。
#
# 用法：
#   fip                菜单
#   fip up [前缀]      建 / 修复网桥
#   fip status         网桥状态（地址、谁在用）
#   fip check          体检
#   fip switch <前缀>  换段（先删再建）
#   fip down           删网桥
#   fip presets        原有 6 条内置地址
#   fip gen6 / gen4    打印一个 /128 或 /32
#   fip bridge add/del/list   网桥地址（宿主机侧）
#   fip help / version
#
# 环境变量：
#   FIP_BRIDGE=kp                网桥（Incus 网络）名
#   FIP_PREFIX=2606:54c1:1:c4     默认 /64 前缀
#   FIP_PREFIXES="..."           内置候选前缀
#   FIP_V4_BRIDGE=175.45.176.1/22 假 IPv4 池（none = 不开）
#   FIP_COLOR=0                  关颜色
set -u

VERSION="3.2"

BRIDGE="${FIP_BRIDGE:-kp}"
PREFIX="${FIP_PREFIX:-2606:54c1:1:c4}"
PREFIXES="${FIP_PREFIXES:-2606:54c1:1:c4 2a14:67c1:a02f 2a12:bec0:160}"
V4_BRIDGE="${FIP_V4_BRIDGE:-175.45.176.1/22}"
V4_IP="${V4_BRIDGE%%/*}"
BUILTIN="104.29.195.20/32 104.29.195.21/32 104.29.195.22/32 104.29.195.23/32 2606:54c1:1:c4::/64 175.45.176.0/22"

# ── 颜色 ────────────────────────────────────────────────
ESC="$(printf '\033')"
USE256=0
if [ -t 1 ] && [ "${FIP_COLOR:-auto}" != "0" ] && [ "${NO_COLOR:-}" = "" ]; then
  case "${COLORTERM:-}:${TERM:-}" in
    *truecolor*|*24bit*|*256color*) USE256=1 ;;
  esac
fi
if [ -t 1 ] && [ "${FIP_COLOR:-auto}" != "0" ] && [ "${NO_COLOR:-}" = "" ]; then
  RST=$(printf '\033[0m'); BOLD=$(printf '\033[1m')
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m')
  BLU=$(printf '\033[34m'); MAG=$(printf '\033[35m'); CYN=$(printf '\033[36m')
  GRY=$(printf '\033[37m'); GRA=$(printf '\033[90m')
  BRED=$(printf '\033[91m'); BGRN=$(printf '\033[92m'); BYEL=$(printf '\033[93m')
  BOLD_W=$(printf '\033[1;37m'); BOLD_MAG=$(printf '\033[1;35m'); BOLD_CYN=$(printf '\033[1;36m')
  if [ "$USE256" = "1" ]; then
    ORNG_B=$(printf '\033[1;38;5;214m'); VIO_B=$(printf '\033[1;38;5;141m')
    TEAL_B=$(printf '\033[1;38;5;45m');  PINK_B=$(printf '\033[1;38;5;213m')
    LIME_B=$(printf '\033[1;38;5;119m'); SKY_B=$(printf '\033[1;38;5;117m')
    BORD=$(printf '\033[38;5;99m');      BORD2=$(printf '\033[38;5;63m')
  else
    ORNG_B="$BOLD_MAG"; VIO_B="$BOLD_MAG"; TEAL_B="$BOLD_CYN"
    PINK_B="$BOLD_MAG"; LIME_B="$BOLD"; SKY_B="$BOLD_CYN"
    BORD="$MAG"; BORD2="$BLU"
  fi
else
  RST=""; BOLD=""
  RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; GRY=""; GRA=""
  BRED=""; BGRN=""; BYEL=""; BOLD_W=""; BOLD_MAG=""; BOLD_CYN=""
  ORNG_B=""; VIO_B=""; TEAL_B=""; PINK_B=""; LIME_B=""; SKY_B=""; BORD=""; BORD2=""
fi

# ── 输出 ────────────────────────────────────────────────
TERMW="${COLUMNS:-}"
if [ -z "$TERMW" ] || [ "$TERMW" -eq 0 ] 2>/dev/null; then
  TERMW=$(stty size 2>/dev/null | awk '{print $2}')
fi
case "$TERMW" in ''|*[!0-9]*) TERMW=46 ;; esac
[ "$TERMW" -lt 40 ] 2>/dev/null && TERMW=40
[ "$TERMW" -gt 72 ] 2>/dev/null && TERMW=72

LINE=""
i=0
while [ "$i" -lt "$TERMW" ]; do LINE="$LINE─"; i=$((i + 1)); done

grad_line() {
  if [ "$USE256" != "1" ]; then printf '%s%s%s' "$BOLD_CYN" "$LINE" "$RST"; return; fi
  n=0; out=""
  i=0
  while [ "$i" -lt "$TERMW" ]; do
    n=$(( 33 + (i * 60 / TERMW) ))
    [ "$n" -gt 231 ] && n=231
    out="$out$(printf '\033[38;5;%sm─' "$n")"
    i=$((i + 1))
  done
  printf '%s%s' "$out" "$RST"
}

hr()  { printf '\n'; grad_line; printf '\n'; \
        printf '  %s▌%s %s%s%s\n' "$BOLD_MAG" "$RST" "$BOLD" "$*" "$RST"; }
hrt() { printf '\n'; grad_line; printf '\n'; \
        printf '  %s▌%s %s%s%s  %s%s%s\n' "$BOLD_MAG" "$RST" "$BOLD" "$*" "$RST" "$GRA" "v$VERSION" "$RST"; }

dim()  { printf '  %s%s%s\n' "$GRA" "$*" "$RST"; }
ok()   { printf '  %s%s%s\n' "$BGRN" "$*" "$RST"; }
warn() { printf '  %s%s%s\n' "$BYEL" "$*" "$RST"; }
err()  { printf '  %s%s%s\n' "$BRED" "$*" "$RST"; }

item() { printf '   %s▸%s  %s%s%s%s   %s%s%s\n' \
           "$PINK_B" "$RST" "$BOLD_W" "$1" "$RST" "$RST" "$GRY" "$2" "$RST"; }
kvp()  { printf '  %s%-16s%s %s\n' "$GRA" "$1" "$RST" "$2"; }
sec()  { printf '\n   %s◆%s %s%s%s\n' "$ORNG_B" "$RST" "$BOLD" "$*" "$RST"; }
st_badge() { printf '%s▐ %s ▐%s' "$1" "$2" "$RST"; }

ask() {
  printf '  %s?%s %s%s%s %s[y/N]%s ' "$ORNG_B" "$RST" "$BOLD_W" "$1" "$RST" "$GRA" "$RST"
  read -r _y || return 1
  case "$_y" in [Yy]*) return 0 ;; *) return 1 ;; esac
}
pause() {
  printf '\n  %s▸ 按回车返回菜单...%s' "$GRA" "$RST"
  read -r _ || true
  printf '\n'
}
UI_IN=""
readline() {
  printf '  %s›%s %s%s%s ' "$ORNG_B" "$RST" "$BOLD_W" "$1" "$RST"
  UI_IN=""
  read -r UI_IN || return 1
  [ -n "$UI_IN" ] || UI_IN="${2:-}"
  return 0
}
ui_clear() {
  [ -t 1 ] || return 0
  printf '%s[H%s[2J%s[3J' "$ESC" "$ESC" "$ESC"
  return 0
}

# ── 地址工具 ─────────────────────────────────────────────
norm_prefix() {
  _p="$1"
  _p="${_p%%/*}"
  while [ "${_p%:}" != "$_p" ]; do _p="${_p%:}"; done
  printf '%s' "$_p"
}

valid_prefix() {
  case "$1" in ''|*[!0-9a-fA-F:.]*) return 1 ;; esac
  case "$1" in *:*:*) ;; *) return 1 ;; esac
  _n=1; _s="$1"
  while :; do
    case "$_s" in *:*) _s="${_s#*:}"; _n=$(( _n + 1 )) ;; *) break ;; esac
  done
  [ "$_n" -ge 3 ] && [ "$_n" -le 4 ] || return 1
  return 0
}

valid_ipv4() {
  case "$1" in ''|*[!0-9.]*) return 1 ;; esac
  _o="$IFS"; IFS=.
  set -- $1
  IFS="$_o"
  [ "$#" -eq 4 ] || return 1
  for _s in "$@"; do
    case "$_s" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_s" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

valid_ipv6() {
  _ip="$1"
  case "$_ip" in ''|*[!0-9a-fA-F:.]*) return 1 ;; esac
  case "$_ip" in *::*::*) return 1 ;; esac
  _c=0; _s="$_ip"
  while :; do
    case "$_s" in *:*) _s="${_s#*:}"; _c=$(( _c + 1 )) ;; *) break ;; esac
  done
  [ "$_c" -ge 2 ] && [ "$_c" -le 7 ] || return 1
  _s="$_ip"
  while [ -n "$_s" ]; do
    case "$_s" in
      *:*) _g="${_s%%:*}"; _s="${_s#*:}" ;;
      *)   _g="$_s"; _s="" ;;
    esac
    case "$_g" in
      '') ;;
      *.*) valid_ipv4 "$_g" || return 1 ;;
      *) [ "${#_g}" -le 4 ] || return 1 ;;
    esac
  done
  return 0
}

valid_cidr() {
  _a="$1"; _l=""
  case "$_a" in */*) _l="${_a##*/}"; _a="${_a%%/*}" ;; esac
  case "$_a" in
    ''|*[!0-9a-fA-F:.]*) return 1 ;;
    *:*) valid_ipv6 "$_a" || return 1 ;;
    *)   valid_ipv4 "$_a" || return 1 ;;
  esac
  if [ -n "$_l" ]; then
    case "$_l" in *[!0-9]*) return 1 ;; esac
    case "$_a" in
      *:*) [ "$_l" -le 128 ] 2>/dev/null || return 1 ;;
      *)   [ "$_l" -le 32 ]  2>/dev/null || return 1 ;;
    esac
  fi
  return 0
}

ip2int() {
  _o="$IFS"; IFS=.
  set -- $1
  IFS="$_o"
  printf '%s' "$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))"
}
int2ip() {
  _n="$1"
  _a=$(( _n / 16777216 )); _n=$(( _n % 16777216 ))
  _b=$(( _n / 65536 ));    _n=$(( _n % 65536 ))
  _c=$(( _n / 256 ))
  _d=$(( _n % 256 ))
  printf '%s.%s.%s.%s' "$_a" "$_b" "$_c" "$_d"
}

range_to_cidr() {
  _r="$1"
  case "$_r" in *-*) ;; *) return 1 ;; esac
  _s="${_r%%-*}"; _e="${_r#*-}"
  case "$_s$_e" in *:*) return 1 ;; esac
  valid_ipv4 "$_s" && valid_ipv4 "$_e" || return 1
  _si="$(ip2int "$_s")"; _ei="$(ip2int "$_e")"
  [ "$_si" -le "$_ei" ] || return 1
  _rem=$(( _ei - _si + 1 ))
  while [ "$_rem" -gt 0 ]; do
    _align=1
    while [ "$_align" -lt 2147483648 ] && [ $(( _si % (_align * 2) )) -eq 0 ]; do
      _align=$(( _align * 2 ))
    done
    _cap=1
    while [ "$_cap" -lt 2147483648 ] && [ $(( _cap * 2 )) -le "$_rem" ]; do
      _cap=$(( _cap * 2 ))
    done
    if [ "$_align" -le "$_cap" ]; then _size="$_align"; else _size="$_cap"; fi
    _p=32; _t="$_size"
    while [ "$_t" -gt 1 ]; do _t=$(( _t / 2 )); _p=$(( _p - 1 )); done
    printf '%s/%s\n' "$(int2ip "$_si")" "$_p"
    _si=$(( _si + _size ))
    _rem=$(( _rem - _size ))
  done
  return 0
}

expand_one() {
  case "$1" in
    *-*) range_to_cidr "$1" ;;
    *) valid_cidr "$1" || return 1
       case "$1" in
         */*) printf '%s\n' "$1" ;;
         *:*) printf '%s/128\n' "$1" ;;
         *)   printf '%s/32\n' "$1" ;;
       esac ;;
  esac
}

expand_addrs() {
  ADDRS=""; _bad=""
  for _t in "$@"; do
    if _out="$(expand_one "$_t")"; then
      for _l in $_out; do ADDRS="$ADDRS $_l"; done
    else
      _bad="$_bad $_t"
    fi
  done
  if [ -n "$_bad" ]; then
    err "写法不对：$_bad"
    dim "支持 1.2.3.4、1.2.3.4/24、2606:54c1:1:c4::/64、1.2.3.4-1.2.3.20"
    return 1
  fi
  [ -n "$ADDRS" ] || { err "没有可用地址"; return 1; }
  return 0
}

rand16() {
  if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    _r="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')"
    case "$_r" in ''|*[!0-9]*) ;; *) printf '%s' "$_r"; return 0 ;; esac
  fi
  _r="$(printf '%s' "$(date +%s 2>/dev/null)-$$-${1:-fip}" | cksum 2>/dev/null | awk '{print $1}')"
  case "$_r" in ''|*[!0-9]*) _r=1 ;; esac
  printf '%s' "$(( _r % 65536 ))"
}

gen_v6_128() {
  _p="$(cur_prefix)"
  _n=1; _s="$_p"
  while :; do
    case "$_s" in *:*) _s="${_s#*:}"; _n=$(( _n + 1 )) ;; *) break ;; esac
  done
  while [ "$_n" -lt 4 ]; do _p="$_p:0"; _n=$(( _n + 1 )); done
  printf '%s:0:%x:%x:%x/128\n' "$_p" "$(rand16 1)" "$(rand16 2)" "$(rand16 3)"
}

gen_v4_32() {
  _r="$(rand16 v4)"
  _n=$(( _r % 1024 ))
  _b="$(ip2int "175.45.176.0")"
  printf '%s/32\n' "$(int2ip "$(( _b + _n ))")"
}

# ── Incus 网桥 ───────────────────────────────────────────
have_incus() { command -v incus >/dev/null 2>&1; }
need_incus() { have_incus || { err "没找到 incus（要在 Incus 宿主机上跑）"; return 1; }; }
net_obj()    { incus network show "$BRIDGE" >/dev/null 2>&1; }
net_dev()    { ip link show "$BRIDGE" >/dev/null 2>&1; }
net_state() {
  if net_obj; then
    if net_dev; then printf 'ok'; else printf 'stale'; fi
  else
    printf 'none'
  fi
}

cur_prefix() {
  if net_dev; then
    _a="$(ip -6 -o addr show dev "$BRIDGE" scope global 2>/dev/null | awk '{print $4}' | head -1)"
    _a="${_a%%/*}"
    case "$_a" in
      *::1) _a="${_a%::1}" ;;
      *::)  _a="${_a%::}" ;;
    esac
    if [ -n "$_a" ]; then printf '%s' "$_a"; return 0; fi
  fi
  printf '%s' "$PREFIX"
}

# 谁在用这张网络（只读，用来提示，不动它们）
used_by() {
  incus network show "$BRIDGE" 2>/dev/null | sed -n '/^used_by:/,$p' | grep '^- ' | sed 's/^-  *//'
}

# ── 命令 ─────────────────────────────────────────────────
cmd_up() {
  need_incus || return 1
  _want="$(norm_prefix "${1:-$PREFIX}")"
  valid_prefix "$_want" || { err "前缀不对：$_want"; return 1; }

  hr "建假网桥"
  dim "只造桥：${_want}::/64 + $V4_BRIDGE；容器怎么用不归它管"

  if [ "$(net_state)" = "stale" ]; then
    warn "Incus 里有 $BRIDGE，但 Linux 设备不在，先删掉对象再建"
    if ! incus network delete "$BRIDGE" >/dev/null 2>&1; then
      err "删不掉，还有东西在用："
      used_by | sed 's/^/    /'
      dim "先在面板/容器上摘掉这张网卡，再 fip up"
      return 1
    fi
  fi

  if net_obj; then
    _cur="$(cur_prefix)"
    if [ "$_cur" != "$_want" ]; then
      err "网桥现在用的是 $_cur"
      dim "换段：fip switch $_want"
      return 1
    fi
    ok "网桥 $BRIDGE 已存在（$_cur::/64），不用重建"
    return 0
  fi

  if incus network create "$BRIDGE" ipv4.address="$V4_BRIDGE" ipv4.nat=false \
       ipv6.address="${_want}::1/64" ipv6.nat=false >/dev/null 2>&1; then
    ok "已建网桥 $BRIDGE"
    kvp "IPv6" "${_want}::1/64"
    kvp "IPv4" "$V4_BRIDGE"
    echo
    dim "后面怎么用都行：面板 routed（父接口填 $BRIDGE）、容器加网卡、或 fip bridge add"
  else
    err "建网桥失败"
    dim "手动：incus network create $BRIDGE ipv4.address=$V4_BRIDGE ipv6.address=${_want}::1/64"
    return 1
  fi
  return 0
}

cmd_status() {
  need_incus || return 1
  hrt "网桥状态"
  case "$(net_state)" in
    ok)
      kvp "名称" "$BRIDGE"
      _h="$(ip -6 -o addr show dev "$BRIDGE" scope global 2>/dev/null | awk '{print $4}' | head -1)"
      _h4="$(ip -4 -o addr show dev "$BRIDGE" scope global 2>/dev/null | awk '{print $4}' | head -1)"
      kvp "IPv6" "${_h:-无}"
      kvp "IPv4" "${_h4:-无}"
      echo
      hr "网桥上的地址"
      ip -o addr show dev "$BRIDGE" 2>/dev/null | awk '{print "  " $3 "  " $4}'
      echo
      hr "谁在用（只读）"
      _u="$(used_by)"
      if [ -n "$_u" ]; then
        printf '%s\n' "$_u" | sed 's/^/    /'
        dim "这些是引用该网络的 profile / 容器；脚本不会动它们"
      else
        dim "没有"
      fi
      ;;
    stale)
      kvp "名称" "$BRIDGE"
      dim "Incus 有对象，Linux 设备不在 → fip up 会删掉重建"
      ;;
    *) dim "未建（fip up）" ;;
  esac
  return 0
}

cmd_check() {
  need_incus || return 1
  hr "体检"
  _bad=0
  case "$(net_state)" in
    ok)
      ok "网桥 $BRIDGE 设备正常" ;;
    stale)
      err "网桥 $BRIDGE：Incus 有对象，Linux 设备不在"
      dim "  修：fip up"
      _bad=$(( _bad + 1 )) ;;
    *)
      warn "网桥 $BRIDGE 未建"
      dim "  修：fip up"
      _bad=$(( _bad + 1 )) ;;
  esac

  if [ "$(net_state)" = "ok" ]; then
    _cp="$(cur_prefix)"
    if ip -6 -o addr show dev "$BRIDGE" scope global 2>/dev/null | grep -qF "${_cp}::1"; then
      ok "IPv6 段在（${_cp}::/64）"
    else
      warn "网桥上没看到 ${_cp}::1，检查前缀"
      _bad=$(( _bad + 1 ))
    fi
    if ps ax 2>/dev/null | grep -v grep | grep -q 'dnsmasq'; then
      ok "dnsmasq 在跑（RA/DHCP 有人发）"
    else
      warn "没看到 dnsmasq，容器可能收不到 RA"
      _bad=$(( _bad + 1 ))
    fi
  fi

  echo
  [ "$_bad" -eq 0 ] && ok "一切正常" || warn "共 $_bad 项要处理"
  return 0
}

cmd_down() {
  need_incus || return 1
  hr "删网桥"
  if ! net_obj; then
    dim "网桥 $BRIDGE 不存在"
    return 0
  fi
  if incus network delete "$BRIDGE" >/dev/null 2>&1; then
    ok "已删除网桥 $BRIDGE"
  else
    err "删不掉，还有东西在用："
    used_by | sed 's/^/    /'
    echo
    dim "这个脚本不动容器/profile；先在上面把这张网卡摘掉再来删"
    return 1
  fi
  return 0
}

cmd_switch() {
  need_incus || return 1
  _want="$(norm_prefix "${1:-}")"
  [ -n "$_want" ] || { err "用法：fip switch <前缀>"; return 1; }
  valid_prefix "$_want" || { err "前缀不对：$_want"; return 1; }
  if net_obj; then
    cmd_down || return 1
  fi
  cmd_up "$_want"
}

cmd_bridge() {
  need_incus || return 1
  _act="${1:-list}"
  case "$_act" in
    add|a)
      _a="${2:-}"
      [ -n "$_a" ] || { err "用法：fip bridge add <地址/段>"; return 1; }
      valid_cidr "$_a" || { err "地址不对：$_a"; return 1; }
      net_dev || { err "网桥 $BRIDGE 不在（先 fip up）"; return 1; }
      if ip addr add "$_a" dev "$BRIDGE" 2>/dev/null; then
        ok "$BRIDGE  $_a"
      else
        dim "$_a 已存在或添加失败"
        return 1
      fi ;;
    del|d)
      _a="${2:-}"
      [ -n "$_a" ] || { err "用法：fip bridge del <地址/段>"; return 1; }
      if ip addr del "$_a" dev "$BRIDGE" 2>/dev/null; then
        ok "已删除 $_a"
      else
        dim "网桥上没有 $_a"
      fi ;;
    list|ls|'')
      hr "网桥 $BRIDGE 的地址"
      ip -o addr show dev "$BRIDGE" 2>/dev/null | awk '{print "  " $3 "  " $4}' ;;
    *) err "用法：fip bridge [add|del|list]"; return 1 ;;
  esac
  return 0
}

cmd_presets() {
  hr "原有 6 条内置地址"
  _i=0
  for _a in $BUILTIN; do
    _i=$(( _i + 1 ))
    case "$_a" in
      *:*) kvp "$_i. $_a" "IPv6 段，网桥已覆盖" ;;
      *)   kvp "$_i. $_a" "IPv4，手绑：fip bridge add $_a" ;;
    esac
  done
  dim "175.45.176.0/22 已是网桥的 IPv4 池"
  return 0
}

# ── 菜单 ─────────────────────────────────────────────────
menu_status() {
  dot_on() { printf '%s◉%s' "$LIME_B" "$RST"; }
  dot_na() { printf '%s◌%s' "$GRA" "$RST"; }
  bar() { printf '   %s┃%s ' "$BORD" "$RST"; }

  bar
  printf '%s◈%s %s网桥%s ' "$SKY_B" "$RST" "$GRA" "$RST"
  case "$(net_state)" in
    ok)    printf '%s %s%s%s %s' "$(dot_on)" "$BOLD_W" "$BRIDGE" "$RST" "$(st_badge "$BGRN" "正常")" ;;
    stale) printf '%s %s%s%s %s' "$(dot_na)" "$BOLD_W" "$BRIDGE" "$RST" "$(st_badge "$ORNG_B" "设备不在")" ;;
    *)     printf '%s %s%s%s %s' "$(dot_na)" "$GRA" "$BRIDGE" "$RST" "$(st_badge "$GRA" "未建")" ;;
  esac
  echo

  bar
  printf '%s◈%s %s前缀%s ' "$VIO_B" "$RST" "$GRA" "$RST"
  printf '%s%s::/64%s' "$BOLD_W" "$(cur_prefix)" "$RST"
  echo

  bar
  printf '%s◈%s %sIPv4%s ' "$LIME_B" "$RST" "$GRA" "$RST"
  printf '%s%s%s' "$BOLD_W" "$V4_BRIDGE" "$RST"
  echo

  bar
  printf '%s◈%s %s引用%s ' "$TEAL_B" "$RST" "$GRA" "$RST"
  _u="$(used_by)"
  if [ -n "$_u" ]; then
    printf '%s%d 个%s' "$BOLD_W" "$(printf '%s\n' "$_u" | wc -l | tr -d ' ')" "$RST"
  else
    printf '%s0%s' "$GRA" "$RST"
  fi
  echo
}

banner() {
  printf '\n'
  printf '  %s╭──────────────────────────────────────╮%s\n' "$BORD" "$RST"
  printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$BOLD_W" "fip $VERSION   ·   FAKE BRIDGE" "$RST" "$BORD" "$RST"
  printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$GRA" "a fake /64 on an Incus bridge" "$RST" "$BORD" "$RST"
  printf '  %s╰──────────────────────────────────────╯%s\n' "$BORD" "$RST"
  printf '   %s◆%s %sfip%s %s%s%s   %s·%s   %s只造桥 · 不管容器%s\n' \
    "$ORNG_B" "$RST" "$GRA" "$RST" "$BOLD_W" "$VERSION" "$RST" "$GRA" "$RST" "$TEAL_B" "$RST"
}

ui_prefix() {
  hr "建 / 换前缀"
  if [ "$(net_state)" = ok ]; then
    kvp "当前" "$BRIDGE（$(cur_prefix)::/64）"
  else
    kvp "当前" "未建"
  fi
  echo
  _i=0
  for _p in $PREFIXES; do
    _i=$(( _i + 1 ))
    _pp="$(norm_prefix "$_p")"
    item "$_i" "$_pp  →  ${_pp}::/64"
  done
  _custom=$(( _i + 1 ))
  item "$_custom" "手动输入前缀"
  echo
  readline "选择 [1-$_custom]，回车取消：" ""
  case "$UI_IN" in
    '') dim "已取消"; return 0 ;;
    "$_custom")
      readline "输入前缀（/48 或 /64）：" ""
      _want="$(norm_prefix "$UI_IN")" ;;
    *)
      _want=""; _j=0
      for _p in $PREFIXES; do
        _j=$(( _j + 1 ))
        [ "$_j" = "$UI_IN" ] && { _want="$(norm_prefix "$_p")"; break; }
      done
      [ -n "$_want" ] || { err "无效选择"; return 0; } ;;
  esac
  valid_prefix "$_want" || { err "前缀不对：$_want"; return 0; }

  _st="$(net_state)"
  if [ "$_st" = "ok" ] && [ "$(cur_prefix)" != "$_want" ]; then
    if ask "网桥现在用 $(cur_prefix)，拆了换成 $_want？"; then
      echo
      cmd_switch "$_want"
    else
      dim "已取消"
    fi
  else
    cmd_up "$_want"
  fi
}

ui_manual() {
  hr "手动输入 IP / 段（加到网桥 $BRIDGE）"
  dim "多个用空格或逗号分隔；段用 CIDR 或 a-b 范围"
  dim "例：175.45.176.0/22  或  2606:54c1:1:c4::/64  或  1.2.3.4,5.6.7.8"
  readline "地址（回车取消）：" ""
  [ -n "$UI_IN" ] || { dim "已取消"; return 0; }
  net_dev || { err "网桥 $BRIDGE 不在（先 fip up）"; return 1; }
  _hadf=0
  case "$-" in *f*) _hadf=1 ;; esac
  [ "$_hadf" = 1 ] || set -f
  _o="$IFS"; IFS=' ,'
  set -- $UI_IN
  IFS="$_o"
  [ "$_hadf" = 1 ] || set +f
  [ "$#" -gt 0 ] || { dim "已取消"; return 0; }
  echo
  expand_addrs "$@" || return 1
  for _a in $ADDRS; do
    if ip addr add "$_a" dev "$BRIDGE" 2>/dev/null; then
      ok "$BRIDGE  $_a"
    elif ip -o addr show dev "$BRIDGE" 2>/dev/null | grep -qF " $_a "; then
      dim "已存在：$_a"
    else
      err "添加失败：$_a"
    fi
  done
  dim "宿主机网桥上的地址：容器不继承、面板不显示"
}

ui_builtin() {
  hr "原有 6 条（加到网桥）"
  _i=0
  for _a in $BUILTIN; do
    _i=$(( _i + 1 ))
    item "$_i" "$_a"
  done
  echo
  readline "选择 [1-$_i]，回车取消：" ""
  case "$UI_IN" in ''|q|Q) dim "已取消"; return 0 ;; esac
  _sel=""; _j=0
  for _a in $BUILTIN; do
    _j=$(( _j + 1 ))
    [ "$_j" = "$UI_IN" ] && _sel="$_a"
  done
  [ -n "$_sel" ] || { err "无效选择"; return 0; }
  net_dev || { err "网桥 $BRIDGE 不在（先 fip up）"; return 1; }
  echo
  if ip addr add "$_sel" dev "$BRIDGE" 2>/dev/null; then
    ok "$BRIDGE  $_sel"
  else
    dim "$_sel 已存在/失败"
  fi
  dim "宿主机网桥上的地址：容器不继承、面板不显示"
}

ui_gen() {
  hr "生成地址"
  item "1" "/128（$(cur_prefix)::/64 里随机）"
  item "2" "/32（175.45.176.0/22 里随机）"
  echo
  readline "选择 [1-2]，回车取消：" ""
  case "$UI_IN" in
    1) echo; kvp "地址" "$(gen_v6_128)" ;;
    2) echo; kvp "地址" "$(gen_v4_32)" ;;
    *) dim "已取消" ;;
  esac
}

ui_help() {
  hr "速查"
  sec "只造桥"
  note "  fip up [前缀]          建网桥 $BRIDGE（假 /64 + 假 v4 池）"
  note "  fip status             网桥地址、谁在引用"
  note "  fip check              体检"
  note "  fip switch <前缀>      换段"
  note "  fip down               删网桥"

  sec "工具"
  note "  fip presets            原有 6 条内置地址"
  note "  fip gen6 / gen4        生成 /128 或 /32"
  note "  fip bridge add/del/list  网桥地址"

  sec "说明"
  dim "本脚本不建 profile、不碰容器、不写文件"
  dim "容器怎么拿地址：面板 routed（父接口填 $BRIDGE）、或你自己挂网卡"
}

cmd_menu() {
  while :; do
    ui_clear
    banner
    echo
    menu_status
    echo
    printf '   %s┄┄%s %s%s网桥%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$SKY_B" "$RST" "$BORD" "$RST"
    item "1" "建网桥 / 换前缀"
    item "2" "查看状态"
    item "3" "体检"
    echo
    printf '   %s┄┄%s %s%s地址%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$VIO_B" "$RST" "$BORD" "$RST"
    item "4" "手动输入 IP / 段（加到网桥）"
    item "5" "原有 6 条（加到网桥）"
    item "6" "生成地址（/128 或 /32）"
    echo
    printf '   %s┄┄%s %s%s其他%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$ORNG_B" "$RST" "$BORD" "$RST"
    item "7" "删除网桥"
    item "8" "帮助 / 速查"
    item "0" "退出"
    echo
    printf '  %s❯%s %s请选择%s %s[0-8]%s %s:%s ' "$PINK_B" "$RST" "$BOLD_W" "$RST" "$TEAL_B" "$RST" "$GRA" "$RST"
    read -r c || return 0
    case "$c" in
      1) ui_prefix; pause ;;
      2) cmd_status; pause ;;
      3) cmd_check; pause ;;
      4) ui_manual; pause ;;
      5) ui_builtin; pause ;;
      6) ui_gen; pause ;;
      7) if ask "删除网桥 $BRIDGE？（不动容器）"; then echo; cmd_down; fi; pause ;;
      8) ui_help; pause ;;
      0) printf '\n  %s再见 👋%s\n\n' "$TEAL_B" "$RST"; exit 0 ;;
      *) printf '  %s✘ 无效选项%s\n' "$BRED" "$RST"; pause ;;
    esac
  done
}

usage() {
  printf 'fip %s — 只造假网桥（假 /64 + 假 IPv4 池），容器交给面板\n\n' "$VERSION"
  cat <<'EOF'
用法：
  fip                     菜单（终端）
  fip up [前缀]           建网桥 kp（默认 2606:54c1:1:c4）
  fip status              网桥地址、谁在引用（只读）
  fip check               体检
  fip switch <前缀>       换段（先删再建）
  fip down                删网桥
  fip presets             原有 6 条内置地址
  fip gen6 / gen4         打印一个 /128 或 /32
  fip bridge add <地址>   手动加到网桥（宿主机侧）
  fip bridge del/list     删除 / 查看

它只做这一件事：
  incus network create kp \
    ipv4.address=175.45.176.1/22 ipv4.nat=false \
    ipv6.address=2606:54c1:1:c4::1/64 ipv6.nat=false

不建 profile、不碰容器、不写任何文件。
容器怎么拿到地址：面板 routed（父接口填 kp）／你自己挂网卡／fip bridge 只影响宿主机。

环境变量：
  FIP_BRIDGE=kp                  网桥（Incus 网络）名
  FIP_PREFIX=2606:54c1:1:c4       默认前缀
  FIP_PREFIXES="..."             内置候选前缀
  FIP_V4_BRIDGE=175.45.176.1/22  假 IPv4 池（none 关）
  FIP_COLOR=0                    关颜色
  FIP_MENU=0                     无参数不进菜单

注意：
  * 宿主机上会多一条 <前缀>::/64 dev kp 的直连路由。
  * fip down 删不掉时，会打印 used_by；先去面板/容器上摘网卡。

安装：
  install -m 755 fip-v3.2.sh /usr/local/bin/fip
EOF
}

case "${1:-}" in
  '' )
      if [ -t 0 ] && [ -t 1 ] && [ "${FIP_MENU:-1}" != "0" ]; then
        cmd_menu
      else
        cmd_up
      fi
      ;;
  menu|ui|tui)          cmd_menu ;;
  up|on|init|create)    cmd_up "${2:-}" ;;
  switch|rebuild)       cmd_switch "${2:-}" ;;
  status|show|stat)     cmd_status ;;
  check|doctor)         cmd_check ;;
  presets|builtin)      cmd_presets ;;
  gen6|v6)              gen_v6_128 ;;
  gen4|v4)              gen_v4_32 ;;
  bridge|br)            cmd_bridge "${2:-list}" "${3:-}" ;;
  down|off|del|delete)  cmd_down ;;
  help|-h|--help)       usage ;;
  version|-v|--version) printf 'fip %s\n' "$VERSION" ;;
  *) printf '未知命令：%s\n\n' "$1"; usage; exit 1 ;;
esac
