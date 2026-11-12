#!/bin/sh
# fip-v2.6.sh — 假 IPv6 网桥：Incus 里建一段假 /64，容器自动拿地址
#
# 全新思路：不再往宿主机绑 dummy 网卡、也不再逐台 ip addr add。
# 在 Incus 里建一个「managed network」（网桥），把假 /64 配给它：
#
#   incus network create kp ipv4.address=175.45.176.1/22 ipv6.address=2606:54c1:1:c4::1/64
#   incus profile device add default kp nic network=kp
#
# Incus 会为这个网络起 dnsmasq 发 RA，容器挂上这张网卡后**内核自己 SLAAC**
# 出 2606:54c1:1:c4:xxxx:xxxx:xxxx:xxxx，新建容器自动带、重启自动回来。
#
# 版本规则：每次改动 +0.1，新建一个文件，旧版本保留不删（fip-v2.6.sh → fip-v2.7.sh）。
#
# 用法：
#   fip                     菜单
#   fip up [前缀]           建网桥（默认用内置第一个段）
#   fip switch <前缀>       换段（先拆再建）
#   fip status              网桥 / profile / 每台容器的地址
#   fip attach [容器]       给一台（或不给=全部）挂上假网段
#   fip detach [容器]       摘掉
#   fip fix6                批量打开容器里的 IPv6（disable_ipv6=1 时用）
#   fip gen6                打印一个 /128；gen4 打印一个 /32
#   fip down                摘网卡 + 删网桥
#   fip help / version
#
# 环境变量：
#   FIP_BRIDGE=kp               网桥（Incus 网络）名
#   FIP_PREFIX=2606:54c1:1:c4   假 /64 前缀（不带 :: 和掩码）
#   FIP_PREFIXES="..."          内置候选前缀，空格分隔
#   FIP_PROFILE=default         自动挂网卡用的 profile
#   FIP_COLOR=0                 关颜色
set -u

VERSION="2.6"

BRIDGE="${FIP_BRIDGE:-kp}"
PREFIX="${FIP_PREFIX:-2606:54c1:1:c4}"
# 内置候选：第一个是默认；/48 会自动取它的第一个 /64（SLAAC 需要 /64）
PREFIXES="${FIP_PREFIXES:-2606:54c1:1:c4 2a14:67c1:a02f 2a12:bec0:160}"
PROFILE="${FIP_PROFILE:-default}"

# 假 IPv4 池：网桥地址用 .1，容器由 Incus DHCP 自动发（none = 不开）
V4_BRIDGE="${FIP_V4_BRIDGE:-175.45.176.1/22}"
V4_IP="${V4_BRIDGE%%/*}"

# 原有内置 6 条（4 个 v4 /32 + v6 /64 + v4 /22），列出来当预设用
BUILTIN="104.29.195.20/32 104.29.195.21/32 104.29.195.22/32 104.29.195.23/32 2606:54c1:1:c4::/64 175.45.176.0/22"

# 生成 /32 用的 IPv4 段
GEN4_CIDR="${FIP_GEN4_CIDR:-175.45.176.0/22}"

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
    ORNG_B=$(printf '\033[1;38;5;214m')
    VIO_B=$(printf '\033[1;38;5;141m')
    TEAL_B=$(printf '\033[1;38;5;45m')
    PINK_B=$(printf '\033[1;38;5;213m')
    LIME_B=$(printf '\033[1;38;5;119m')
    SKY_B=$(printf '\033[1;38;5;117m')
    BORD=$(printf '\033[38;5;99m')
    BORD2=$(printf '\033[38;5;63m')
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
res()  { printf '%s%s%s\n' "$2" "$1" "$RST"; }
kvp()  { printf '  %s%-16s%s %s\n' "$GRA" "$1" "$RST" "$2"; }
kvn()  { printf '  %s%-16s%s '     "$GRA" "$1" "$RST"; }
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
prompt() { printf '  %s›%s %s%s%s ' "$ORNG_B" "$RST" "$BOLD_W" "$1" "$RST"; }
UI_IN=""
readline() {
  prompt "$1"
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

# ── 校验 / 生成 ──────────────────────────────────────────
valid_prefix() {
  case "$1" in ''|*[!0-9a-fA-F:.]*) return 1 ;; esac
  case "$1" in *:*:*) ;; *) return 1 ;; esac
  case "$1" in *::*) return 1 ;; esac
  # 段数 3（/48）或 4（/64）
  _n=1; _s="$1"
  while :; do
    case "$_s" in *:*) _s="${_s#*:}"; _n=$(( _n + 1 )) ;; *) break ;; esac
  done
  [ "$_n" -ge 3 ] && [ "$_n" -le 4 ] || return 1
  return 0
}

# 去掉 /48 /64 掩码和尾部冒号
norm_prefix() {
  _p="$1"
  _p="${_p%%/*}"
  while [ "${_p%:}" != "$_p" ]; do _p="${_p%:}"; done
  printf '%s' "$_p"
}

# 当前网桥用的前缀（没网桥就用默认）
cur_prefix() {
  if net_exists; then
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

# ── 地址校验 / 展开（v1.0 那套：IP、CIDR、a-b 范围、多条）──
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

valid_ip() {
  case "$1" in
    '') return 1 ;;
    *:*) valid_ipv6 "$1" ;;
    *)   valid_ipv4 "$1" ;;
  esac
}

valid_cidr() {
  _a="$1"; _l=""
  case "$_a" in */*) _l="${_a##*/}"; _a="${_a%%/*}" ;; esac
  valid_ip "$_a" || return 1
  if [ -n "$_l" ]; then
    case "$_l" in *[!0-9]*) return 1 ;; esac
    case "$_a" in
      *:*) [ "$_l" -le 128 ] 2>/dev/null || return 1 ;;
      *)   [ "$_l" -le 32 ]  2>/dev/null || return 1 ;;
    esac
  fi
  return 0
}

# 175.45.176.0-175.45.179.255 → 175.45.176.0/22（必要时拆成多条）
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
# 0..65535 的随机数
rand16() {
  if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    _r="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')"
    case "$_r" in ''|*[!0-9]*) ;; *) printf '%s' "$_r"; return 0 ;; esac
  fi
  _r="$(printf '%s' "$(date +%s 2>/dev/null)-$$-${1:-fip}" | cksum 2>/dev/null | awk '{print $1}')"
  case "$_r" in ''|*[!0-9]*) _r=1 ;; esac
  printf '%s' "$(( _r % 65536 ))"
}

# 完整 8 段、无 :: 的 /128
gen_v6_128() {
  _p="$(cur_prefix)"
  # 前缀不足 4 段时补 0，保证拼出来是 8 段
  _n=1; _s="$_p"
  while :; do
    case "$_s" in *:*) _s="${_s#*:}"; _n=$(( _n + 1 )) ;; *) break ;; esac
  done
  while [ "$_n" -lt 4 ]; do _p="$_p:0"; _n=$(( _n + 1 )); done
  printf '%s:0:%x:%x:%x/128\n' "$_p" "$(rand16 1)" "$(rand16 2)" "$(rand16 3)"
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
gen_v4_32() {
  _cidr="$GEN4_CIDR"
  _base="${_cidr%%/*}"; _len="${_cidr##*/}"
  case "$_len" in ''|*[!0-9]*) _len=22 ;; esac
  _size=$(( 1 << (32 - _len) ))
  _r="$(rand16 v4)"
  _n=$(( _r % _size ))
  _b="$(ip2int "$_base")"
  printf '%s/32\n' "$(int2ip "$(( _b + _n ))")"
}

# ── Incus 小工具 ─────────────────────────────────────────
have_incus() { command -v incus >/dev/null 2>&1; }
net_exists()  { incus network show "$BRIDGE" >/dev/null 2>&1; }

incus_containers() {
  incus list -c n,t --format csv 2>/dev/null | awk -F, '$2=="CONTAINER"{print $1}'
}
incus_vms() {
  incus list -c n,t --format csv 2>/dev/null | awk -F, '$2=="VIRTUAL-MACHINE"{print $1}'
}

has_dev() {
  incus config device show "$1" 2>/dev/null | grep -q "network: $BRIDGE"
}
profile_has_dev() {
  incus profile device show "$PROFILE" 2>/dev/null | grep -q "network: $BRIDGE"
}

addr_of() {
  incus exec "$1" -- ip -6 -o addr show scope global 2>/dev/null |
    awk '{print $4}' | grep -F "${PREFIX}:" | grep -v '^::' | head -1
}

# 容器里把非 eth0 网卡的 IPv6 打开并拉起
enable_v6() {
  incus exec "$1" -- sh -c '
    for i in /sys/class/net/*; do
      n="${i##*/}"
      case "$n" in lo|eth0) continue ;; esac
      sysctl -w "net.ipv6.conf.$n.disable_ipv6=0" >/dev/null 2>&1 || \
        echo 0 > "/proc/sys/net/ipv6/conf/$n/disable_ipv6" 2>/dev/null
      sysctl -w "net.ipv6.conf.$n.accept_ra=2" >/dev/null 2>&1
      sysctl -w "net.ipv6.conf.$n.autoconf=1" >/dev/null 2>&1
      ip link set "$n" up 2>/dev/null
    done
  ' >/dev/null 2>&1
}

# 假网桥的 DHCP 会给容器塞一条默认路由，删掉它，免得把 IPv4 出口带沟里
drop_v4_default() {
  [ -n "$V4_IP" ] || return 0
  [ "$V4_IP" = "none" ] && return 0
  incus exec "$1" -- ip -4 route del default via "$V4_IP" >/dev/null 2>&1
  return 0
}

# 容器里假网段上的那个 IPv4
addr_v4_of() {
  _pfx="$(printf '%s' "$V4_IP" | awk -F. '{print $1"."$2}')"
  [ -n "$_pfx" ] || return 0
  incus exec "$1" -- ip -4 -o addr show scope global 2>/dev/null |
    awk '{print $4}' | grep -F "${_pfx}." | head -1
}

need_incus() {
  if ! have_incus; then
    err "没找到 incus 命令（要在 Incus 宿主机上跑）"
    return 1
  fi
  return 0
}

# ── 命令 ─────────────────────────────────────────────────
cmd_up() {
  need_incus || return 1
  _want="$(norm_prefix "${1:-$PREFIX}")"
  if ! valid_prefix "$_want"; then
    err "前缀不对：$_want（要 3~4 段，如 2606:54c1:1:c4 或 2a14:67c1:a02f）"
    return 1
  fi
  hr "启用假 IPv6 网桥"
  dim "把 ${_want}::/64 配成一个 Incus 网络，容器挂上就自动 SLAAC"

  if net_exists; then
    _cur="$(cur_prefix)"
    if [ "$_cur" != "$_want" ]; then
      err "网桥 $BRIDGE 现在用的是 $_cur"
      dim "要换段：fip switch $_want（先拆再建）"
      return 1
    fi
    dim "网桥 $BRIDGE 已存在（$_cur），跳过创建"
  elif incus network create "$BRIDGE" ipv4.address="$V4_BRIDGE" ipv4.nat=false \
         ipv6.address="${_want}::1/64" ipv6.nat=false >/dev/null 2>&1; then
    ok "已建网桥 $BRIDGE（${_want}::1/64 + $V4_BRIDGE）"
  else
    err "建网桥失败"
    dim "手动：incus network create $BRIDGE ipv4.address=$V4_BRIDGE ipv6.address=${_want}::1/64"
    return 1
  fi

  echo
  if profile_has_dev; then
    dim "profile $PROFILE 已挂着 $BRIDGE"
  elif incus profile device add "$PROFILE" "$BRIDGE" nic network="$BRIDGE" >/dev/null 2>&1; then
    ok "profile $PROFILE 挂上 $BRIDGE（新建容器自动带）"
  else
    warn "profile $PROFILE 挂载失败（可能没有这个 profile）"
  fi

  echo
  hr "现有容器"
  _n=0
  for _c in $(incus_containers); do
    _n=$(( _n + 1 ))
    if has_dev "$_c"; then
      dim "$_c  已挂着 $BRIDGE"
    elif incus config device add "$_c" "$BRIDGE" nic network="$BRIDGE" >/dev/null 2>&1; then
      ok "$_c  挂上 $BRIDGE"
      sleep 1
    else
      warn "$_c  挂载失败"
    fi
    enable_v6 "$_c"
    drop_v4_default "$_c"
  done
  [ "$_n" -eq 0 ] && dim "没有容器"

  echo
  dim "等容器收 RA 自动配地址（最多 10 秒）…"
  _w=0
  while [ "$_w" -lt 10 ]; do
    _left=0
    for _c in $(incus_containers); do
      [ -n "$(addr_of "$_c")" ] || _left=$(( _left + 1 ))
    done
    [ "$_left" -eq 0 ] && break
    sleep 1
    _w=$(( _w + 1 ))
  done

  hr "结果"
  for _c in $(incus_containers); do
    _a="$(addr_of "$_c")"
    kvp "$_c" "${_a:-（还没拿到：fip fix6 再试一次）}"
  done
  echo
  dim "新建容器：会自动带 $BRIDGE，开机自己 SLAAC，不用再操作"
  dim "探针只报这张卡：哪吒 nic_allowlist / Komari INCLUDE_NICS 填对应网卡名"
  return 0
}

# 换段：先拆再建
cmd_switch() {
  need_incus || return 1
  _want="$(norm_prefix "${1:-}")"
  [ -n "$_want" ] || { err "用法：fip switch <前缀>"; return 1; }
  valid_prefix "$_want" || { err "前缀不对：$_want"; return 1; }
  if net_exists; then
    dim "先拆掉现有网桥（$(cur_prefix)）…"
    cmd_down || return 1
  fi
  cmd_up "$_want"
}

cmd_status() {
  need_incus || return 1
  hrt "FIP 状态"

  hr "网桥"
  if net_exists; then
    kvp "名称" "$BRIDGE"
    incus network show "$BRIDGE" 2>/dev/null | grep -E '^  (ipv4|ipv6)\.' | sed 's/^  /  · /'
    _h="$(ip -6 -o addr show dev "$BRIDGE" scope global 2>/dev/null | awk '{print $4}' | head -1)"
    kvp "IPv6 地址" "${_h:-无}"
    _h4="$(ip -4 -o addr show dev "$BRIDGE" scope global 2>/dev/null | awk '{print $4}' | head -1)"
    kvp "IPv4 地址" "${_h4:-无}"
  else
    dim "未建（fip up）"
  fi

  hr "profile"
  if profile_has_dev; then
    kvp "$PROFILE" "已挂着 $BRIDGE（新建容器自动带）"
  else
    dim "$PROFILE 没挂 $BRIDGE"
  fi

  hr "容器"
  _n=0
  for _c in $(incus_containers); do
    _n=$(( _n + 1 ))
    _a="$(addr_of "$_c")"; _a4="$(addr_v4_of "$_c")"
    if has_dev "$_c"; then
      kvp "$_c" "${_a4:-无 v4}  ${_a:-无 v6}"
    else
      dim "$_c  未挂载"
    fi
  done
  [ "$_n" -eq 0 ] && dim "没有容器"

  _v="$(incus_vms | tr '\n' ' ')"
  [ -n "$_v" ] && { echo; dim "注意：有虚拟机 $_v（网桥这种方式只对容器生效）"; }
  return 0
}

cmd_attach() {
  need_incus || return 1
  _one="${1:-}"
  hr "挂网卡"
  if [ -n "$_one" ]; then
    _list="$_one"
  else
    _list="$(incus_containers)"
  fi
  [ -n "$_list" ] || { dim "没有容器"; return 0; }
  for _c in $_list; do
    if has_dev "$_c"; then
      dim "$_c  已挂着 $BRIDGE"
    elif incus config device add "$_c" "$BRIDGE" nic network="$BRIDGE" >/dev/null 2>&1; then
      ok "$_c  挂上 $BRIDGE"
      sleep 1
    else
      warn "$_c  挂载失败"
    fi
    enable_v6 "$_c"
    drop_v4_default "$_c"
    _a="$(addr_of "$_c")"
    kvp "$_c" "${_a:-（还没拿到地址）}"
  done
  return 0
}

cmd_detach() {
  need_incus || return 1
  _one="${1:-}"
  hr "摘网卡"
  if [ -n "$_one" ]; then
    _list="$_one"
  else
    _list="$(incus_containers)"
  fi
  for _c in $_list; do
    if incus config device remove "$_c" "$BRIDGE" >/dev/null 2>&1; then
      ok "$_c  已摘除 $BRIDGE"
    else
      dim "$_c  没挂着 $BRIDGE"
    fi
  done
  return 0
}

cmd_presets() {
  hr "内置 6 条（预设）"
  _i=0
  for _a in $BUILTIN; do
    _i=$(( _i + 1 ))
    case "$_a" in
      *:*) kvp "$_i. $_a" "IPv6，网桥已覆盖（SLAAC 自动发）" ;;
      *)   kvp "$_i. $_a" "IPv4，需要时手绑到某台容器" ;;
    esac
  done
  echo
  dim "175.45.176.0/22 已做成网桥的 IPv4 池，容器会自动拿到 175.45.176.x"
  dim "四个 /32 是单地址，手绑：incus exec <容器> -- ip addr add 104.29.195.20/32 dev eth1"
  return 0
}

# 容器的假网卡名（非 eth0、且已经有地址的那张，兜底 eth1）
kp_iface() {
  incus exec "$1" -- sh -c '
    for i in /sys/class/net/*; do
      n="${i##*/}"
      case "$n" in lo|eth0) continue ;; esac
      if ip -4 -o addr show dev "$n" 2>/dev/null | grep -q . || \
         ip -6 -o addr show dev "$n" scope global 2>/dev/null | grep -q .; then
        echo "$n"; exit 0
      fi
    done
    echo eth1
  ' 2>/dev/null | head -1
}

# 手动把任意 IP / 段加到容器的假网卡上
cmd_add_addr() {
  need_incus || return 1
  _c="${1:-}"; _a="${2:-}"
  if [ -z "$_c" ] || [ -z "$_a" ]; then
    err "用法：fip add <容器> <地址或段>"
    return 1
  fi
  hr "手动加地址"
  _if="$(kp_iface "$_c")"
  [ -n "$_if" ] || _if=eth1
  kvp "容器" "$_c"
  kvp "网卡" "$_if"
  kvp "地址" "$_a"
  echo
  if incus exec "$_c" -- ip addr add "$_a" dev "$_if" 2>/dev/null; then
    ok "已加：$_a"
  elif incus exec "$_c" -- ip -o addr show dev "$_if" 2>/dev/null | grep -qF " $_a "; then
    dim "已存在：$_a"
  else
    err "添加失败（格式或权限？）"
    dim "手动：incus exec $_c -- ip addr add $_a dev $_if"
    return 1
  fi
  return 0
}

cmd_fix6() {
  need_incus || return 1
  hr "修复容器 IPv6"
  dim "把非 eth0 网卡的 disable_ipv6 打开、accept_ra=2、拉起，再等 10 秒"
  for _c in $(incus_containers); do
    enable_v6 "$_c"
    drop_v4_default "$_c"
  done
  _w=0
  while [ "$_w" -lt 10 ]; do
    _left=0
    for _c in $(incus_containers); do
      [ -n "$(addr_of "$_c")" ] || _left=$(( _left + 1 ))
    done
    [ "$_left" -eq 0 ] && break
    sleep 1
    _w=$(( _w + 1 ))
  done
  for _c in $(incus_containers); do
    _a="$(addr_of "$_c")"
    kvp "$_c" "${_a:-（还没拿到）}"
  done
  return 0
}

cmd_down() {
  need_incus || return 1
  hr "拆除假 IPv6 网桥"
  if profile_has_dev; then
    incus profile device remove "$PROFILE" "$BRIDGE" >/dev/null 2>&1 &&
      ok "profile $PROFILE 已摘除 $BRIDGE"
  fi
  for _c in $(incus_containers); do
    incus config device remove "$_c" "$BRIDGE" >/dev/null 2>&1 &&
      ok "$_c  已摘除 $BRIDGE"
  done
  if net_exists; then
    if incus network delete "$BRIDGE" >/dev/null 2>&1; then
      ok "已删除网桥 $BRIDGE"
    else
      err "删除网桥失败（可能还有网卡在用）"
      return 1
    fi
  else
    dim "网桥 $BRIDGE 不存在"
  fi
  return 0
}

# ── 菜单 ─────────────────────────────────────────────────
menu_status() {
  dot_on() { printf '%s◉%s' "$LIME_B" "$RST"; }
  dot_na() { printf '%s◌%s' "$GRA" "$RST"; }
  bar() { printf '   %s┃%s ' "$BORD" "$RST"; }

  bar
  printf '%s◈%s %s网桥%s ' "$SKY_B" "$RST" "$GRA" "$RST"
  if net_exists; then
    printf '%s %s%s%s %s' "$(dot_on)" "$BOLD_W" "$BRIDGE" "$RST" "$(st_badge "$BGRN" "已建")"
  else
    printf '%s %s%s%s %s' "$(dot_na)" "$GRA" "$BRIDGE" "$RST" "$(st_badge "$GRA" "未建")"
  fi
  echo

  bar
  printf '%s◈%s %s前缀%s ' "$VIO_B" "$RST" "$GRA" "$RST"
  _cp="$(cur_prefix)"
  printf '%s%s::/64%s' "$BOLD_W" "$_cp" "$RST"
  echo

  bar
  printf '%s◈%s %sprofile%s ' "$LIME_B" "$RST" "$GRA" "$RST"
  if profile_has_dev; then
    printf '%s %s%s%s %s' "$(dot_on)" "$BOLD_W" "$PROFILE" "$RST" "$(st_badge "$BGRN" "自动挂载")"
  else
    printf '%s %s%s%s %s' "$(dot_na)" "$GRA" "$PROFILE" "$RST" "$(st_badge "$GRA" "未挂")"
  fi
  echo

  bar
  printf '%s◈%s %s容器%s ' "$TEAL_B" "$RST" "$GRA" "$RST"
  _t=0; _g=0
  for _c in $(incus_containers); do
    _t=$(( _t + 1 ))
    [ -n "$(addr_of "$_c")" ] && _g=$(( _g + 1 ))
  done
  printf '%s%d 台，%d 台有假地址%s' "$BOLD_W" "$_t" "$_g" "$RST"
  echo
}

banner() {
  printf '\n'
  printf '  %s╭──────────────────────────────────────╮%s\n' "$BORD" "$RST"
  printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$BOLD_W" "fip $VERSION   ·   FAKE IP" "$RST" "$BORD" "$RST"
  printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$GRA" "a fake /64 inside Incus" "$RST" "$BORD" "$RST"
  printf '  %s╰──────────────────────────────────────╯%s\n' "$BORD" "$RST"
  printf '   %s◆%s %sfip%s %s%s%s   %s·%s   %s假网桥 · 自动分配%s\n' \
    "$ORNG_B" "$RST" "$GRA" "$RST" "$BOLD_W" "$VERSION" "$RST" "$GRA" "$RST" "$TEAL_B" "$RST"
}

ui_prefix() {
  hr "启用 / 切换前缀"
  if net_exists; then
    kvp "当前网桥" "$BRIDGE（$(cur_prefix)::/64）"
  else
    kvp "当前网桥" "未建"
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
        readline "输入前缀（/48 或 /64，如 2a14:67c1:a02f）：" ""
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

  if net_exists; then
    if [ "$(cur_prefix)" = "$_want" ]; then
      dim "已经是这个段，只补挂"
      cmd_up "$_want"
    elif ask "网桥现在用的是 $(cur_prefix)，重建成 $_want？"; then
      echo
      cmd_switch "$_want"
    else
      dim "已取消"
    fi
  else
    cmd_up "$_want"
  fi
}

# ── 手动输入：直接加到网桥（宿主机侧，和 v1.0 的 fip0 一个意思）──
ui_manual() {
  hr "创建 — 自己输入（加到网桥 $BRIDGE）"
  dim "多个用空格或逗号分隔；段用 CIDR 或 a-b 范围"
  dim "例：175.45.176.0/22  或  2606:54c1:1:c4::/64  或  1.2.3.4,5.6.7.8"
  dim "只加到宿主机网桥：容器不继承、面板不显示"
  readline "地址（回车取消）：" ""
  [ -n "$UI_IN" ] || { dim "已取消"; return 0; }
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
  echo
  dim "宿主机网桥上的地址：容器不继承、面板不显示；重启会丢"
  return 0
}

ui_builtin_pick() {
  hr "内置 6 条（加到网桥 $BRIDGE）"
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
  echo
  if ip addr add "$_sel" dev "$BRIDGE" 2>/dev/null; then
    ok "$BRIDGE  $_sel"
  else
    dim "$_sel 已存在/失败"
  fi
  dim "宿主机网桥上的地址：容器不继承、面板不显示"
  return 0
}

# 网桥地址的增删查
cmd_bridge() {
  need_incus || return 1
  _act="${1:-list}"
  case "$_act" in
    add|a)
      _a="${2:-}"
      [ -n "$_a" ] || { err "用法：fip bridge add <地址/段>"; return 1; }
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
    *) err "用法：fip bridge [add|del|list]" ; return 1 ;;
  esac
  return 0
}

ui_attach() {
  hr "挂网卡"
  readline "容器名（回车 = 全部）：" ""
  echo
  cmd_attach "$UI_IN"
}

ui_detach() {
  hr "摘网卡"
  readline "容器名（回车 = 全部）：" ""
  echo
  if [ -n "$UI_IN" ]; then
    cmd_detach "$UI_IN"
  elif ask "从所有容器摘除 $BRIDGE？"; then
    echo
    cmd_detach ""
  else
    dim "已取消"
  fi
}

ui_gen() {
  hr "生成地址"
  item "1" "/128（${PREFIX}::/64 里随机）"
  item "2" "/32（${GEN4_CIDR} 里随机）"
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
  sec "管理"
  note "  fip up [前缀]          建网桥（默认 $PREFIX）"
  note "  fip switch <前缀>      换段（先拆再建）"
  note "  fip status             网桥 / profile / 容器地址"
  note "  fip attach [容器]      给一台（不给=全部）挂网卡"
  note "  fip detach [容器]      摘掉"
  note "  fip fix6               批量打开容器 IPv6（disable_ipv6=1 时）"
  note "  fip down               摘网卡 + 删网桥"
  echo
  dim "内置候选：$PREFIXES"

  sec "生成"
  note "  fip add <容器> <地址>  手动把 IP / 段加到容器的假网卡上"
  note "  fip bridge add <地址>  手动把 IP / 段加到网桥（宿主机侧）"
  note "  fip presets            列出原有 6 条内置地址"
  note "  fip gen6               打印一个 /128"
  note "  fip gen4               打印一个 /32"

  sec "原理"
  dim "网桥 = Incus managed network，Incus 给它起 dnsmasq 发 RA"
  dim "容器挂上这张网卡，内核自己 SLAAC 出地址"
  dim "新建容器带 profile → 自动有；重启自动回来"

  sec "环境变量"
  dim "FIP_BRIDGE=$BRIDGE   FIP_PREFIX=$PREFIX   FIP_PROFILE=$PROFILE"
  echo
  dim "探针只报这张卡：哪吒 nic_allowlist / Komari INCLUDE_NICS 填网卡名"
}

cmd_menu() {
  while :; do
    ui_clear
    banner
    echo
    menu_status
    echo
    printf '   %s┄┄%s %s%s管理%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$SKY_B" "$RST" "$BORD" "$RST"
    item "1" "启用 / 切换前缀（网桥）"
    item "2" "查看状态"
    item "3" "手动输入 IP / 段（加到网桥）"
    item "4" "内置 6 条（加到网桥）"
    item "5" "给容器挂网卡"
    item "6" "修复容器 IPv6"
    echo
    printf '   %s┄┄%s %s%s工具%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$VIO_B" "$RST" "$BORD" "$RST"
    item "7" "生成地址（/128 或 /32）"
    item "8" "拆除（摘网卡 + 删网桥）"
    echo
    printf '   %s┄┄%s %s%s其他%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$ORNG_B" "$RST" "$BORD" "$RST"
    item "9" "帮助 / 速查"
    item "0" "退出"
    echo
    printf '  %s❯%s %s请选择%s %s[0-9]%s %s:%s ' "$PINK_B" "$RST" "$BOLD_W" "$RST" "$TEAL_B" "$RST" "$GRA" "$RST"
    read -r c || return 0
    case "$c" in
      1) ui_prefix; pause ;;
      2) cmd_status; pause ;;
      3) ui_manual; pause ;;
      4) ui_builtin_pick; pause ;;
      5) ui_attach; pause ;;
      6) cmd_fix6; pause ;;
      7) ui_gen; pause ;;
      8) if ask "摘掉所有容器的 $BRIDGE 并删除网桥？"; then echo; cmd_down; fi; pause ;;
      9) ui_help; pause ;;
      0) printf '\n  %s再见 👋%s\n\n' "$TEAL_B" "$RST"; exit 0 ;;
      *) printf '  %s✘ 无效选项%s\n' "$BRED" "$RST"; pause ;;
    esac
  done
}

usage() {
  printf 'fip %s — 假 IPv6 网桥：Incus 里建段假 /64，容器自动拿地址\n\n' "$VERSION"
  cat <<'EOF'
用法：
  fip                     菜单（终端）
  fip up [前缀]           建网桥（默认 2606:54c1:1:c4）
  fip switch <前缀>       换段（先拆再建），如 fip switch 2a14:67c1:a02f
  fip add <容器> <地址>   手动把 IP / 段加到容器的假网卡上
  fip status              网桥 / profile / 每台容器地址
  fip attach [容器]       给一台（不给=全部）挂网卡
  fip detach [容器]       摘网卡
  fip fix6                批量打开容器里的 IPv6（disable_ipv6=1 时用）
  fip presets             列出原有 6 条内置地址
  fip gen6 / gen4         打印一个 /128 或 /32
  fip down                摘网卡 + 删网桥
  fip help / version

原理：
  incus network create kp ipv4.address=175.45.176.1/22 ipv6.address=2606:54c1:1:c4::1/64
  incus profile device add default kp nic network=kp

  Incus 为这个网络起 dnsmasq 发 RA；容器挂上后内核自己 SLAAC 出地址，
  新建容器带 profile 就自动有，重启自动回来，不需要逐台 ip addr add。

环境变量：
  FIP_BRIDGE=kp                网桥（Incus 网络）名
  FIP_PREFIX=2606:54c1:1:c4     默认前缀（不带 :: 和掩码）
  FIP_PREFIXES="..."           内置候选前缀，空格分隔
  FIP_PROFILE=default          自动挂网卡用的 profile
  FIP_COLOR=0                  关颜色（也认 NO_COLOR）
  FIP_MENU=0                   无参数时不进菜单，直接 fip up

内置候选前缀（/48 自动取它第一个 /64 给网桥）：
  2606:54c1:1:c4::/64
  2a14:67c1:a02f::/48   → 2a14:67c1:a02f::/64
  2a12:bec0:160::/48    → 2a12:bec0:160::/64

注意：
  * 只对 Incus 容器有效；虚拟机不走这条。
  * 宿主机上会多一条 2606:54c1:1:c4::/64 dev kp 的直连路由。
  * 探针要只报这张卡的话，白名单填容器里的网卡名（一般为 eth1/eth2）。

安装：
  install -m 755 fip-v2.0.sh /usr/local/bin/fip
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
  attach)               cmd_attach "${2:-}" ;;
  detach|remove|rm)     cmd_detach "${2:-}" ;;
  fix6|fix)             cmd_fix6 ;;
  add|addr)             cmd_add_addr "${2:-}" "${3:-}" ;;
  bridge|br)            cmd_bridge "${2:-list}" "${3:-}" ;;
  down|off|del|delete)  cmd_down ;;
  presets|builtin)      cmd_presets ;;
  gen6|v6)              gen_v6_128 ;;
  gen4|v4)              gen_v4_32 ;;
  help|-h|--help)       usage ;;
  version|-v|--version) printf 'fip %s\n' "$VERSION" ;;
  *) printf '未知命令：%s\n\n' "$1"; usage; exit 1 ;;
esac
