#!/bin/sh
# fip-v4.0.sh — 给宿主机造一张假网桥：IPv6 或 IPv4，二选一
#
# 就三件事：
#   1. ip link add fip0 type bridge && ip link set fip0 up
#   2. 选 IPv6 → 加 2606:54c1:1:c4::1/64
#      选 IPv4 → 加 175.45.176.1/22
#   3. 完事
#
# 不碰 Incus、不碰容器、不建 profile、不写文件。
# 版本规则：每次改动 +0.1，新建文件，旧版本保留（fip-v4.0.sh → fip-v4.1.sh）。
#
# 用法：
#   fip                菜单
#   fip v6 [前缀]      建 IPv6 网桥（默认 2606:54c1:1:c4）
#   fip v4 [段]        建 IPv4 网桥（默认 175.45.176.0/22）
#   fip status         看网桥和地址
#   fip add <地址>     再往网桥上加点东西
#   fip down           删网桥
#   fip gen6 / gen4    生成一个完整 /128 或 /32
#   fip help / version
#
# 环境变量：
#   FIP_DEV=fip0           网桥名
#   FIP_PREFIX=2606:54c1:1:c4   IPv6 默认前缀
#   FIP_V4=175.45.176.0/22     IPv4 默认段
#   FIP_COLOR=0            关颜色
set -u

VERSION="4.0"

DEV="${FIP_DEV:-fip0}"
PREFIX="${FIP_PREFIX:-2606:54c1:1:c4}"
V4_NET="${FIP_V4:-175.45.176.0/22}"

PREFIXES="2606:54c1:1:c4 2a14:67c1:a02f 2a12:bec0:160"
V4S="175.45.176.0/22 104.29.195.20/30 104.29.195.20/32 104.29.195.21/32 104.29.195.22/32 104.29.195.23/32"

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
    BORD=$(printf '\033[38;5;99m')
  else
    ORNG_B="$BOLD_MAG"; VIO_B="$BOLD_MAG"; TEAL_B="$BOLD_CYN"
    PINK_B="$BOLD_MAG"; LIME_B="$BOLD"; SKY_B="$BOLD_CYN"; BORD="$MAG"
  fi
else
  RST=""; BOLD=""
  RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; GRY=""; GRA=""
  BRED=""; BGRN=""; BYEL=""; BOLD_W=""; BOLD_MAG=""; BOLD_CYN=""
  ORNG_B=""; VIO_B=""; TEAL_B=""; PINK_B=""; LIME_B=""; SKY_B=""; BORD=""
fi

# ── 输出 ────────────────────────────────────────────────
TERMW="${COLUMNS:-}"
[ -z "$TERMW" ] || [ "$TERMW" -eq 0 ] 2>/dev/null && TERMW=$(stty size 2>/dev/null | awk '{print $2}')
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
    n=$(( 33 + (i * 60 / TERMW) )); [ "$n" -gt 231 ] && n=231
    out="$out$(printf '\033[38;5;%sm─' "$n")"
    i=$((i + 1))
  done
  printf '%s%s' "$out" "$RST"
}

hr()  { printf '\n'; grad_line; printf '\n'; printf '  %s▌%s %s%s%s\n' "$BOLD_MAG" "$RST" "$BOLD" "$*" "$RST"; }
hrt() { printf '\n'; grad_line; printf '\n'; printf '  %s▌%s %s%s%s  %s%s%s\n' "$BOLD_MAG" "$RST" "$BOLD" "$*" "$RST" "$GRA" "v$VERSION" "$RST"; }
dim()  { printf '  %s%s%s\n' "$GRA" "$*" "$RST"; }
ok()   { printf '  %s%s%s\n' "$BGRN" "$*" "$RST"; }
warn() { printf '  %s%s%s\n' "$BYEL" "$*" "$RST"; }
err()  { printf '  %s%s%s\n' "$BRED" "$*" "$RST"; }
item() { printf '   %s▸%s  %s%s%s%s   %s%s%s\n' "$PINK_B" "$RST" "$BOLD_W" "$1" "$RST" "$RST" "$GRY" "$2" "$RST"; }
kvp()  { printf '  %s%-16s%s %s\n' "$GRA" "$1" "$RST" "$2"; }
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

# 完整 8 段、不用 ::
gen_v6_128() {
  _p="$PREFIX"
  _n=1; _s="$_p"
  while :; do
    case "$_s" in *:*) _s="${_s#*:}"; _n=$(( _n + 1 )) ;; *) break ;; esac
  done
  while [ "$_n" -lt 4 ]; do _p="$_p:0"; _n=$(( _n + 1 )); done
  printf '%s:0:%x:%x:%x/128\n' "$_p" "$(rand16 1)" "$(rand16 2)" "$(rand16 3)"
}

gen_v4_32() {
  _base="${V4_NET%%/*}"; _len="${V4_NET##*/}"
  case "$_len" in ''|*[!0-9]*) _len=22 ;; esac
  _size=$(( 1 << (32 - _len) ))
  [ "$_size" -gt 65536 ] && _size=65536
  _r="$(rand16 v4)"; _n=$(( _r % _size ))
  _b="$(ip2int "$_base")"
  printf '%s/32\n' "$(int2ip "$(( _b + _n ))")"
}

# ── 网桥 ─────────────────────────────────────────────────
dev_exists() { ip link show "$DEV" >/dev/null 2>&1; }

ensure_dev() {
  if dev_exists; then
    ip link set "$DEV" up 2>/dev/null
    return 0
  fi
  if ip link add "$DEV" type bridge 2>/dev/null; then
    ip link set "$DEV" up 2>/dev/null
    ok "已建网桥 $DEV"
    return 0
  fi
  err "建网桥失败：ip link add $DEV type bridge"
  return 1
}

dev_addrs() {
  ip -o addr show dev "$DEV" scope global 2>/dev/null | awk '{print $3 "  " $4}'
}

# IPv6：<前缀>::1/64
cmd_v6() {
  _p="$(norm_prefix "${1:-$PREFIX}")"
  valid_prefix "$_p" || { err "前缀不对：$_p（要 3~4 段，如 2606:54c1:1:c4）"; return 1; }
  hr "IPv6 网桥"
  ensure_dev || return 1
  kvp "网桥" "$DEV"
  kvp "前缀" "${_p}::/64"
  echo
  if ip -6 -o addr show dev "$DEV" scope global 2>/dev/null | grep -qF "${_p}::1/64"; then
    dim "已经有了：${_p}::1/64"
  elif ip addr add "${_p}::1/64" dev "$DEV" 2>/dev/null; then
    ok "已加：${_p}::1/64"
  else
    err "添加失败：ip addr add ${_p}::1/64 dev $DEV"
    return 1
  fi
  echo
  dev_addrs | sed 's/^/  /'
  return 0
}

# IPv4：<段> 的 .1，掩码取段的长度
cmd_v4() {
  _net="${1:-$V4_NET}"
  valid_cidr "$_net" || { err "段不对：$_net（如 175.45.176.0/22）"; return 1; }
  case "$_net" in *:*) err "这是 IPv6，用 fip v6"; return 1 ;; esac
  _base="${_net%%/*}"; _len="${_net##*/}"
  case "$_len" in ''|*[!0-9]*) _len=24 ;; esac
  _gw="$(int2ip "$(( $(ip2int "$_base") + 1 ))")"
  hr "IPv4 网桥"
  ensure_dev || return 1
  kvp "网桥" "$DEV"
  kvp "段" "$_net"
  kvp "网关地址" "${_gw}/${_len}"
  echo
  if ip -4 -o addr show dev "$DEV" scope global 2>/dev/null | grep -qF "${_gw}/${_len}"; then
    dim "已经有了：${_gw}/${_len}"
  elif ip addr add "${_gw}/${_len}" dev "$DEV" 2>/dev/null; then
    ok "已加：${_gw}/${_len}"
  else
    err "添加失败：ip addr add ${_gw}/${_len} dev $DEV"
    return 1
  fi
  echo
  dev_addrs | sed 's/^/  /'
  return 0
}

cmd_status() {
  hrt "状态"
  if dev_exists; then
    kvp "网桥" "$DEV"
    ip -o link show dev "$DEV" 2>/dev/null | sed 's/^[0-9]*: //' | cut -c1-90 | sed 's/^/  /'
    echo
    hr "地址"
    _a="$(dev_addrs)"
    if [ -n "$_a" ]; then printf '%s\n' "$_a" | sed 's/^/  /'; else dim "没有地址"; fi
  else
    dim "网桥 $DEV 未建（fip v6 或 fip v4）"
  fi
  return 0
}

cmd_add() {
  [ -n "${1:-}" ] || { err "用法：fip add <地址/段>"; return 1; }
  dev_exists || { err "网桥 $DEV 未建（先 fip v6 / fip v4）"; return 1; }
  hr "加地址到 $DEV"
  expand_addrs "$@" || return 1
  for _a in $ADDRS; do
    if ip addr add "$_a" dev "$DEV" 2>/dev/null; then
      ok "$DEV  $_a"
    else
      dim "$_a 已存在或失败"
    fi
  done
  return 0
}

cmd_down() {
  hr "删网桥"
  if ! dev_exists; then
    dim "网桥 $DEV 不存在"
    return 0
  fi
  if ip link del "$DEV" 2>/dev/null; then
    ok "已删除网桥 $DEV"
  else
    err "删除失败：ip link del $DEV"
    return 1
  fi
  return 0
}

# ── 菜单 ─────────────────────────────────────────────────
menu_status() {
  bar() { printf '   %s┃%s ' "$BORD" "$RST"; }
  if dev_exists; then
    bar; printf '%s◈%s %s网桥%s %s%s%s %s\n' "$SKY_B" "$RST" "$GRA" "$RST" "$BOLD_W" "$DEV" "$RST" "$(st_badge "$BGRN" "已建")"
  else
    bar; printf '%s◈%s %s网桥%s %s%s%s %s\n' "$SKY_B" "$RST" "$GRA" "$RST" "$GRA" "$DEV" "$RST" "$(st_badge "$GRA" "未建")"
  fi
  if dev_exists; then
    _v6="$(ip -6 -o addr show dev "$DEV" scope global 2>/dev/null | awk '{print $4}' | head -1)"
    _v4="$(ip -4 -o addr show dev "$DEV" scope global 2>/dev/null | awk '{print $4}' | head -1)"
    bar; printf '%s◈%s %sIPv6%s %s\n' "$VIO_B" "$RST" "$GRA" "$RST" "${_v6:-$GRA无$RST}"
    bar; printf '%s◈%s %sIPv4%s %s\n' "$LIME_B" "$RST" "$GRA" "$RST" "${_v4:-$GRA无$RST}"
  fi
}

banner() {
  printf '\n'
  printf '  %s╭──────────────────────────────────────╮%s\n' "$BORD" "$RST"
  printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$BOLD_W" "fip $VERSION   ·   HOST BRIDGE" "$RST" "$BORD" "$RST"
  printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$GRA" "IPv6 or IPv4, pick one" "$RST" "$BORD" "$RST"
  printf '  %s╰──────────────────────────────────────╯%s\n' "$BORD" "$RST"
  printf '   %s◆%s %sfip%s %s%s%s   %s·%s   %s宿主机网桥 · 二选一%s\n' \
    "$ORNG_B" "$RST" "$GRA" "$RST" "$BOLD_W" "$VERSION" "$RST" "$GRA" "$RST" "$TEAL_B" "$RST"
}

ui_v6() {
  hr "建 IPv6 网桥"
  _i=0
  for _p in $PREFIXES; do
    _i=$(( _i + 1 ))
    item "$_i" "${_p}::/64"
  done
  _c=$(( _i + 1 ))
  item "$_c" "手动输入前缀"
  echo
  readline "选择 [1-$_c]，回车取消：" ""
  case "$UI_IN" in
    '') dim "已取消"; return 0 ;;
    "$_c") readline "前缀（/48 或 /64）：" ""; _p="$(norm_prefix "$UI_IN")" ;;
    *) _p=""; _j=0
       for _x in $PREFIXES; do _j=$(( _j + 1 )); [ "$_j" = "$UI_IN" ] && _p="$_x"; done
       [ -n "$_p" ] || { err "无效选择"; return 0; } ;;
  esac
  echo
  cmd_v6 "$_p"
}

ui_v4() {
  hr "建 IPv4 网桥"
  _i=0
  for _n in $V4S; do
    _i=$(( _i + 1 ))
    item "$_i" "$_n"
  done
  _c=$(( _i + 1 ))
  item "$_c" "手动输入段"
  echo
  readline "选择 [1-$_c]，回车取消：" ""
  case "$UI_IN" in
    '') dim "已取消"; return 0 ;;
    "$_c") readline "段（如 175.45.176.0/22）：" ""; _n="$_UI_IN" ;;
    *) _n=""; _j=0
       for _x in $V4S; do _j=$(( _j + 1 )); [ "$_j" = "$UI_IN" ] && _n="$_x"; done
       [ -n "$_n" ] || { err "无效选择"; return 0; } ;;
  esac
  echo
  cmd_v4 "$_n"
}

ui_add() {
  hr "加地址到 $DEV"
  dim "多个用空格或逗号分隔；支持 CIDR 和 a-b 范围"
  readline "地址（回车取消）：" ""
  [ -n "$UI_IN" ] || { dim "已取消"; return 0; }
  dev_exists || { err "网桥 $DEV 未建（先 fip v6 / fip v4）"; return 1; }
  _hadf=0
  case "$-" in *f*) _hadf=1 ;; esac
  [ "$_hadf" = 1 ] || set -f
  _o="$IFS"; IFS=' ,'
  set -- $UI_IN
  IFS="$_o"
  [ "$_hadf" = 1 ] || set +f
  expand_addrs "$@" || return 1
  for _a in $ADDRS; do
    if ip addr add "$_a" dev "$DEV" 2>/dev/null; then
      ok "$DEV  $_a"
    else
      dim "$_a 已存在或失败"
    fi
  done
}

ui_gen() {
  hr "生成地址"
  item "1" "/128（${PREFIX}::/64）"
  item "2" "/32（${V4_NET}）"
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
  item "fip v6 [前缀]" "建 IPv6 网桥，加 <前缀>::1/64"
  item "fip v4 [段]"   "建 IPv4 网桥，加段的 .1"
  item "fip status"    "看网桥和地址"
  item "fip add <地址>" "再往网桥上加点东西"
  item "fip down"      "删网桥"
  item "fip gen6/gen4" "生成一个 /128 或 /32"
  echo
  dim "只动宿主机：ip link add $DEV type bridge + ip addr add"
  dim "不碰 Incus、不碰容器、不写文件"
  dim "环境变量：FIP_DEV=$DEV  FIP_PREFIX=$PREFIX  FIP_V4=$V4_NET"
}

cmd_menu() {
  while :; do
    ui_clear
    banner
    echo
    menu_status
    echo
    printf '   %s┄┄%s %s%s建桥%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$SKY_B" "$RST" "$BORD" "$RST"
    item "1" "IPv6 网桥（假 /64）"
    item "2" "IPv4 网桥（假段）"
    echo
    printf '   %s┄┄%s %s%s其它%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$VIO_B" "$RST" "$BORD" "$RST"
    item "3" "查看状态"
    item "4" "加地址"
    item "5" "生成地址（/128 或 /32）"
    item "6" "删除网桥"
    item "7" "帮助"
    item "0" "退出"
    echo
    printf '  %s❯%s %s请选择%s %s[0-7]%s %s:%s ' "$PINK_B" "$RST" "$BOLD_W" "$RST" "$TEAL_B" "$RST" "$GRA" "$RST"
    read -r c || return 0
    case "$c" in
      1) ui_v6; pause ;;
      2) ui_v4; pause ;;
      3) cmd_status; pause ;;
      4) ui_add; pause ;;
      5) ui_gen; pause ;;
      6) if ask "删除网桥 $DEV 上所有地址？"; then echo; cmd_down; fi; pause ;;
      7) ui_help; pause ;;
      0) printf '\n  %s再见 👋%s\n\n' "$TEAL_B" "$RST"; exit 0 ;;
      *) printf '  %s✘ 无效选项%s\n' "$BRED" "$RST"; pause ;;
    esac
  done
}

usage() {
  printf 'fip %s — 给宿主机造一张假网桥：IPv6 或 IPv4，二选一\n\n' "$VERSION"
  cat <<'EOF'
用法：
  fip                  菜单（终端）
  fip v6 [前缀]        建 IPv6 网桥，加 <前缀>::1/64（默认 2606:54c1:1:c4）
  fip v4 [段]          建 IPv4 网桥，加段的 .1（默认 175.45.176.0/22）
  fip status           看网桥和地址
  fip add <地址/段>    再往网桥上加（支持 CIDR、a-b 范围）
  fip down             删网桥
  fip gen6 / gen4      生成一个完整 /128 或 /32
  fip help / version

它就是：
  ip link add fip0 type bridge
  ip link set fip0 up
  ip addr add 2606:54c1:1:c4::1/64 dev fip0     # 或者
  ip addr add 175.45.176.1/22 dev fip0

不碰 Incus、不碰容器、不写文件。

环境变量：
  FIP_DEV=fip0                网桥名
  FIP_PREFIX=2606:54c1:1:c4   IPv6 默认前缀
  FIP_V4=175.45.176.0/22      IPv4 默认段
  FIP_COLOR=0                 关颜色
  FIP_MENU=0                  无参数不进菜单

安装：
  install -m 755 fip-v4.0.sh /usr/local/bin/fip
EOF
}

case "${1:-}" in
  '' )
      if [ -t 0 ] && [ -t 1 ] && [ "${FIP_MENU:-1}" != "0" ]; then
        cmd_menu
      else
        cmd_v6
      fi
      ;;
  menu|ui|tui)       cmd_menu ;;
  v6|6|ipv6)         cmd_v6 "${2:-}" ;;
  v4|4|ipv4)         cmd_v4 "${2:-}" ;;
  add|addr)          shift; cmd_add "$@" ;;
  status|show|stat)  cmd_status ;;
  down|off|del|delete) cmd_down ;;
  gen6)              gen_v6_128 ;;
  gen4)              gen_v4_32 ;;
  help|-h|--help)    usage ;;
  version|-v|--version) printf 'fip %s\n' "$VERSION" ;;
  *) printf '未知命令：%s\n\n' "$1"; usage; exit 1 ;;
esac
