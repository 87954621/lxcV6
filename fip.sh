#!/bin/sh
# fip-v0.4.sh — 只做一件事：建一张网卡，把 IP / IP 段绑上去
#
# 不认探针、不改探针配置、不开机自启、不记账本、不写任何文件。
# 绑地址用 noprefixroute：只让地址出现在网卡上，不往路由表里加东西。
#
# 版本规则：每次改动 +0.1，新建一个文件，旧版本保留不删（fip-v0.4.sh → fip-v0.5.sh）。
#
# 用法：
#   fip                     终端里进菜单；非 TTY 时只列候选
#   fip up                  选一条内置朝鲜 IP（6 选 1）
#   fip up <地址...>        建网卡并绑地址 / 段
#   fip up --all            6 条内置地址全部绑上
#   fip add <地址...>       往已有网卡补地址（等同 fip up）
#   fip gen6 / gen4         只生成一个段内地址并打印（/128、/32）
#   fip status              看网卡和地址
#   fip down                删网卡（连同上面的地址）
#   fip help / fip version
#
# 菜单 1「内置朝鲜 IP」是 6 选 1，另有「从 /64 生成 /128」「从 /22 生成 /32」
#
# 地址写法：
#   单个 IP     104.29.195.20              → 104.29.195.20/32
#   带掩码      175.45.176.0/22
#   IPv6        2606:54c1:1:c4::/64
#   范围        175.45.176.0-175.45.179.255   （自动换算成 CIDR）
#   多个        空格或逗号分隔
#
# 环境变量：
#   FIP_DEV=fip0                网卡名
#   FIP_DEFAULT_ADDRS="..."     内置地址组，空格分隔
#   FIP_GEN6_PREFIX=2606:54c1:1:c4   /128 生成用的 /64 前缀
#   FIP_GEN4_CIDR=175.45.176.0/22    /32 生成用的 IPv4 段
#   FIP_NOPREFIXROUTE=0         关掉 noprefixroute（会生成直连路由）
#   FIP_COLOR=0                 关掉颜色（也认 NO_COLOR）
set -u

VERSION="0.4"

DEV="${FIP_DEV:-fip0}"
NOPREFIX="${FIP_NOPREFIXROUTE:-1}"

# 内置朝鲜地址组：
#   104.29.195.20~.23    Cloudflare geofeed 标 KP 的 4 个 /32
#   2606:54c1:1:c4::/64  Cloudflare geofeed 整段标 KP
#   175.45.176.0/22      KP 的整段（175.45.176.0~175.45.179.255）
DEFAULT_ADDRS="${FIP_DEFAULT_ADDRS:-104.29.195.20/32 104.29.195.21/32 104.29.195.22/32 104.29.195.23/32 2606:54c1:1:c4::/64 175.45.176.0/22}"

# ── 颜色 ────────────────────────────────────────────────
# 优先用 256 色（更细腻），终端不支持则回落基本 16 色。
ESC="$(printf '\033')"
USE256=0
if [ -t 1 ] && [ "${FIP_COLOR:-auto}" != "0" ] && [ "${NO_COLOR:-}" = "" ]; then
  case "${COLORTERM:-}:${TERM:-}" in
    *truecolor*|*24bit*|*256color*) USE256=1 ;;
  esac
fi

if [ -t 1 ] && [ "${FIP_COLOR:-auto}" != "0" ] && [ "${NO_COLOR:-}" = "" ]; then
  RST=$(printf '\033[0m'); BOLD=$(printf '\033[1m'); HDIM=$(printf '\033[2m')
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m')
  BLU=$(printf '\033[34m'); MAG=$(printf '\033[35m'); CYN=$(printf '\033[36m')
  GRY=$(printf '\033[37m'); GRA=$(printf '\033[90m')
  BRED=$(printf '\033[91m'); BGRN=$(printf '\033[92m'); BYEL=$(printf '\033[93m')
  BOLD_W=$(printf '\033[1;37m')
  BOLD_MAG=$(printf '\033[1;35m'); BOLD_CYN=$(printf '\033[1;36m')
  if [ "$USE256" = "1" ]; then
    ORNG=$(printf '\033[38;5;208m')
    ORNG_B=$(printf '\033[1;38;5;214m')
    VIO_B=$(printf '\033[1;38;5;141m')
    TEAL_B=$(printf '\033[1;38;5;45m')
    PINK_B=$(printf '\033[1;38;5;213m')
    LIME_B=$(printf '\033[1;38;5;119m')
    SKY_B=$(printf '\033[1;38;5;117m')
    BORD=$(printf '\033[38;5;99m')
    BORD2=$(printf '\033[38;5;63m')
  else
    ORNG="$YEL"; ORNG_B="$BOLD_MAG"; VIO_B="$BOLD_MAG"
    TEAL_B="$BOLD_CYN"; PINK_B="$BOLD_MAG"; LIME_B="$BOLD"
    SKY_B="$BOLD_CYN"; BORD="$MAG"; BORD2="$BLU"
  fi
else
  RST=""; BOLD=""; HDIM=""
  RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; GRY=""; GRA=""
  BRED=""; BGRN=""; BYEL=""; BOLD_W=""; BOLD_MAG=""; BOLD_CYN=""
  ORNG=""; ORNG_B=""; VIO_B=""; TEAL_B=""; PINK_B=""; LIME_B=""; SKY_B=""
  BORD=""; BORD2=""
fi

# ── 输出小工具 ──────────────────────────────────────────
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

note()  { printf '  %s\n' "$*"; }
dim()   { printf '  %s%s%s\n' "$GRA" "$*" "$RST"; }
ok()    { printf '  %s%s%s\n' "$BGRN" "$*" "$RST"; }
warn()  { printf '  %s%s%s\n' "$BYEL" "$*" "$RST"; }
err()   { printf '  %s%s%s\n' "$BRED" "$*" "$RST"; }

item()  { printf '   %s▸%s  %s%s%s%s   %s%s%s\n' \
            "$PINK_B" "$RST" "$BOLD_W" "$1" "$RST" "$RST" "$GRY" "$2" "$RST"; }

res()   { printf '%s%s%s\n' "$2" "$1" "$RST"; }
kv()    { printf '  %s%-18s%s %s\n' "$GRA" "$1" "$RST" "$2"; }
kvp()   { printf '  %s%-18s%s %s\n' "$GRA" "$1" "$RST" "$2"; }
kvn()   { printf '  %s%-18s%s '     "$GRA" "$1" "$RST"; }
sec()   { printf '\n   %s◆%s %s%s%s\n' "$ORNG_B" "$RST" "$BOLD" "$*" "$RST"; }
st_badge() { printf '%s▐ %s ▐%s' "$1" "$2" "$RST"; }

# ── 交互提示 ────────────────────────────────────────────
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
readline() {   # $1=提示 $2=默认值 → UI_IN
  prompt "$1"
  UI_IN=""
  read -r UI_IN || return 1
  [ -n "$UI_IN" ] || UI_IN="${2:-}"
  return 0
}

ui_clear() {
  if [ -t 1 ]; then
    clear 2>/dev/null || printf '%s[H%s[2J' "$ESC" "$ESC"
  fi
  return 0
}

# ── 地址校验 ──────────────────────────────────────────────
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

# 单条地址：IP 或 IP/len
valid_cidr() {
  _a="$1"; _l=""
  case "$_a" in
    */*) _l="${_a##*/}"; _a="${_a%%/*}" ;;
  esac
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

# ── 段内生成地址 ─────────────────────────────────────────
# 内置段：/64 里生成 /128，/22 里生成 /32
GEN6_PREFIX="${FIP_GEN6_PREFIX:-2606:54c1:1:c4}"
GEN4_CIDR="${FIP_GEN4_CIDR:-175.45.176.0/22}"

# 0..65535 的随机数（/dev/urandom 优先，没有就用时间+PID 哈希）
hash16() {
  if command -v cksum >/dev/null 2>&1; then
    set -- $(printf '%s' "$1" | cksum 2>/dev/null)
    _v="${1:-1}"
    case "$_v" in ''|*[!0-9]*) _v=1 ;; esac
    printf '%s' "$(( _v % 65536 ))"
    return 0
  fi
  printf '1'
}

rand16() {
  if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    _r="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')"
    case "$_r" in
      ''|*[!0-9]*) ;;
      *) printf '%s' "$_r"; return 0 ;;
    esac
  fi
  hash16 "$(date +%s 2>/dev/null)-$$-${RANDOM:-0}-${1:-fip}"
}

# 2606:54c1:1:c4:0:xxxx:xxxx:xxxx/128（完整 8 段，不用 ::）
gen_v6_128() {
  printf '%s:0:%x:%x:%x/128\n' "$GEN6_PREFIX" \
    "$(rand16 1)" "$(rand16 2)" "$(rand16 3)"
}

# 175.45.176.0/22 里随机取一个 /32
gen_v4_32() {
  _cidr="$GEN4_CIDR"
  _base="${_cidr%%/*}"
  _len="${_cidr##*/}"
  case "$_len" in ''|*[!0-9]*) _len=22 ;; esac
  _size=$(( 1 << (32 - _len) ))
  _r="$(rand16 v4)"
  _n=$(( _r % _size ))
  _b="$(ip2int "$_base")"
  printf '%s/32\n' "$(int2ip "$(( _b + _n ))")"
}

# 175.45.176.0-175.45.179.255 → 175.45.176.0/22（必要时拆成多条）
range_to_cidr() {
  _r="$1"
  case "$_r" in *-*) ;; *) return 1 ;; esac
  _s="${_r%%-*}"; _e="${_r#*-}"
  case "$_s$_e" in *:*) return 1 ;; esac          # IPv6 不支持范围写法
  valid_ipv4 "$_s" && valid_ipv4 "$_e" || return 1
  _si="$(ip2int "$_s")"; _ei="$(ip2int "$_e")"
  [ "$_si" -le "$_ei" ] || return 1
  _rem=$(( _ei - _si + 1 ))
  while [ "$_rem" -gt 0 ]; do
    # _si 的对齐块
    _align=1
    while [ "$_align" -lt 2147483648 ] && [ $(( _si % (_align * 2) )) -eq 0 ]; do
      _align=$(( _align * 2 ))
    done
    # 剩余部分能覆盖的最大块
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

# 一条输入 → 一条或多条 CIDR
expand_one() {
  case "$1" in
    *-*) range_to_cidr "$1" ;;
    *)   valid_cidr "$1" || return 1
         case "$1" in
           */*) printf '%s\n' "$1" ;;
           *:*) printf '%s/128\n' "$1" ;;
           *)   printf '%s/32\n' "$1" ;;
         esac ;;
  esac
}

# 展开所有输入 → ADDRS（空格分隔）
collect_addrs() {
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
    dim "支持 1.2.3.4、1.2.3.4/24、2606:54c1:1:c4::/64、175.45.176.0-175.45.179.255"
    return 1
  fi
  [ -n "$ADDRS" ] || { err "没有可用地址"; return 1; }
  return 0
}

need_root() {
  _u="$(id -u 2>/dev/null || printf '0')"
  [ "$_u" = "0" ] || warn "当前不是 root（uid=$_u）：建网卡 / 绑地址会失败，建议 sudo 运行"
}

# ── 网卡 ──────────────────────────────────────────────────
DEV_TYPE=""
ensure_dev() {
  if ip link show "$DEV" >/dev/null 2>&1; then
    DEV_TYPE="已存在"
    ip link set "$DEV" up 2>/dev/null
    return 0
  fi
  if ip link add "$DEV" type dummy 2>/dev/null; then
    DEV_TYPE="dummy"
  elif ip link add "$DEV" type veth peer name "${DEV}p" 2>/dev/null; then
    DEV_TYPE="veth"
  else
    err "建不了网卡 $DEV"
    dim "需要 root / CAP_NET_ADMIN；dummy 模块缺失时先 modprobe dummy"
    return 1
  fi
  ip link set "$DEV" up 2>/dev/null
  return 0
}

add_addr() {
  _a="$1"
  if ip -o addr show dev "$DEV" 2>/dev/null | grep -qiF " $_a "; then
    dim "已存在：$_a"
    return 0
  fi
  if [ "$NOPREFIX" = "1" ] && \
     ip addr add "$_a" dev "$DEV" scope global noprefixroute 2>/dev/null; then
    ok "$_a"
    return 0
  fi
  if ip addr add "$_a" dev "$DEV" scope global 2>/dev/null; then
    ok "$_a"
    return 0
  fi
  if ip -o addr show dev "$DEV" 2>/dev/null | grep -qiF " $_a "; then
    dim "已存在：$_a"
    return 0
  fi
  err "添加失败：$_a"
  return 1
}

# ── 命令 ──────────────────────────────────────────────────
cmd_up() {
  if [ "$#" -gt 0 ]; then
    collect_addrs "$@" || return 1
  else
    collect_addrs $DEFAULT_ADDRS || return 1
  fi

  hrt "创建网卡"
  need_root
  ensure_dev || return 1
  kvp "网卡" "$DEV（$DEV_TYPE）"
  kvp "地址数" "$(printf '%s' "$ADDRS" | wc -w | tr -d ' ')"
  if [ "$NOPREFIX" = "1" ]; then
    kvp "路由" "不加（noprefixroute）"
  else
    kvp "路由" "会生成直连路由（FIP_NOPREFIXROUTE=0）"
  fi
  echo

  _fail=0
  for _a in $ADDRS; do
    add_addr "$_a" || _fail=$(( _fail + 1 ))
  done
  echo
  hr "结果"
  ip -o addr show dev "$DEV" 2>/dev/null | awk '{print "   " $3 "  " $4}'
  echo
  if [ "$_fail" -eq 0 ]; then
    ok "完成。删卡：fip down"
  else
    warn "$_fail 条没绑上，其余已生效"
  fi
  return 0
}

# 6 条全绑（脚本用：fip up --all）
cmd_up_all() {
  cmd_up $DEFAULT_ADDRS
}

cmd_status() {
  hrt "FIP 状态"
  if ip link show "$DEV" >/dev/null 2>&1; then
    _v4=$(ip -o -4 addr show dev "$DEV" scope global 2>/dev/null | wc -l | tr -d ' ')
    _v6=$(ip -o -6 addr show dev "$DEV" scope global 2>/dev/null | wc -l | tr -d ' ')
    kvp "网卡" "$DEV"
    kvn "地址"; res "$_v4 个 IPv4 / $_v6 个 IPv6" "$BOLD_W"
    if [ "$NOPREFIX" = "1" ]; then
      kvp "路由" "不加（noprefixroute）"
    else
      kvp "路由" "会生成直连路由"
    fi
    echo
    ip -o addr show dev "$DEV" 2>/dev/null | awk '{print "   " $3 "  " $4}'
  else
    kvp "网卡" "$DEV 未创建"
    echo
    dim "创建：fip up（内置 6 选 1）或 fip up <IP/段>"
  fi
  return 0
}

cmd_down() {
  hrt "删除网卡"
  if ! ip link show "$DEV" >/dev/null 2>&1; then
    dim "网卡 $DEV 不存在"
    return 0
  fi
  kvn "网卡"; res "$DEV" "$BOLD_W"
  _v4=$(ip -o -4 addr show dev "$DEV" scope global 2>/dev/null | wc -l | tr -d ' ')
  _v6=$(ip -o -6 addr show dev "$DEV" scope global 2>/dev/null | wc -l | tr -d ' ')
  kvn "将删除"; res "$_v4 个 IPv4 / $_v6 个 IPv6 地址" "$BYEL"
  echo
  if ip link del "$DEV" 2>/dev/null; then
    ok "已删除 $DEV"
  else
    err "删除失败（需要 root）"
    return 1
  fi
  return 0
}

# ── 菜单：状态条 ──────────────────────────────────────────
menu_status() {
  dot_on()  { printf '%s◉%s' "$LIME_B" "$RST"; }
  dot_na()  { printf '%s◌%s' "$GRA"    "$RST"; }
  bar()     { printf '   %s┃%s ' "$BORD" "$RST"; }

  bar
  printf '%s%s%s %s网卡%s ' "$SKY_B" "◈" "$RST" "$GRA" "$RST"
  if ip link show "$DEV" >/dev/null 2>&1; then
    printf '%s ' "$(dot_on)"; printf '%s%s%s' "$BOLD_W" "$DEV" "$RST"
    printf ' %s' "$(st_badge "$BGRN" "已创建")"
  else
    printf '%s ' "$(dot_na)"; printf '%s%s%s' "$GRA" "$DEV" "$RST"
    printf ' %s' "$(st_badge "$GRA" "未创建")"
  fi
  echo

  bar
  printf '%s%s%s %s地址%s ' "$VIO_B" "◈" "$RST" "$GRA" "$RST"
  if ip link show "$DEV" >/dev/null 2>&1; then
    _v4=$(ip -o -4 addr show dev "$DEV" scope global 2>/dev/null | wc -l | tr -d ' ')
    _v6=$(ip -o -6 addr show dev "$DEV" scope global 2>/dev/null | wc -l | tr -d ' ')
    printf '%s ' "$(dot_on)"
    printf '%s%s%s' "$BOLD_W" "$_v4 IPv4 / $_v6 IPv6" "$RST"
    printf ' %s' "$(st_badge "$SKY_B" "已绑定")"
  else
    printf '%s ' "$(dot_na)"
    printf '%s0%s' "$GRA" "$RST"
    printf ' %s' "$(st_badge "$GRA" "空")"
  fi
  echo

  bar
  printf '%s%s%s %s方式%s ' "$LIME_B" "◈" "$RST" "$GRA" "$RST"
  if [ "$NOPREFIX" = "1" ]; then
    printf '%s只加地址 · 不加路由%s' "$BOLD_W" "$RST"
    printf ' %s' "$(st_badge "$BGRN" "noprefixroute")"
  else
    printf '%s只加地址 · 会加路由%s' "$BOLD_W" "$RST"
    printf ' %s' "$(st_badge "$ORNG_B" "有直连路由")"
  fi
  echo
}

# ── 菜单：标题 ────────────────────────────────────────────
banner() {
  printf '\n'
  printf '  %s╭──────────────────────────────────────╮%s\n' "$BORD" "$RST"
  printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$BOLD_W" "fip $VERSION   ·   FAKE IP" "$RST" "$BORD" "$RST"
  printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$GRA" "just addresses on a NIC" "$RST" "$BORD" "$RST"
  printf '  %s╰──────────────────────────────────────╯%s\n' "$BORD" "$RST"
  printf '   %s◆%s %sfip%s %s%s%s   %s·%s   %s只建网卡 · 只绑地址%s\n' \
    "$ORNG_B" "$RST" "$GRA" "$RST" "$BOLD_W" "$VERSION" "$RST" "$GRA" "$RST" "$TEAL_B" "$RST"
}

# ── 菜单动作 ──────────────────────────────────────────────
# 取列表里第 N 个：pick_nth <序号> <列表...>
pick_nth() {
  _i="$1"; shift
  while [ "$_i" -gt 1 ] && [ "$#" -gt 1 ]; do
    shift
    _i=$(( _i - 1 ))
  done
  [ "$#" -ge 1 ] || return 1
  printf '%s' "$1"
}

ui_bind_one() {
  _a="$1"
  hr "绑定 — 内置朝鲜 IP"
  kvp "将绑定" "$_a"
  if ip link show "$DEV" >/dev/null 2>&1; then
    dim "网卡 $DEV 已存在，只补这一条"
  fi
  echo
  if ask "只绑这一条？"; then
    echo
    cmd_up "$_a"
  else
    printf '  %s已取消%s\n' "$GRA" "$RST"
  fi
}

ui_up_custom() {
  hr "创建 — 自己输入"
  dim "多个用空格或逗号分隔；段用 CIDR 或 a-b 范围"
  dim "例：175.45.176.0/22  或  2606:54c1:1:c4::/64  或  1.2.3.4,5.6.7.8"
  readline "地址：" ""
  [ -n "$UI_IN" ] || { printf '  %s已取消%s\n' "$GRA" "$RST"; return 0; }
  # 逗号/空白都当分隔符；临时关掉通配符展开，避免 * 之类被当成文件名
  _hadf=0
  case "$-" in *f*) _hadf=1 ;; esac
  [ "$_hadf" = 1 ] || set -f
  _o="$IFS"; IFS=' ,'
  set -- $UI_IN
  IFS="$_o"
  [ "$_hadf" = 1 ] || set +f
  [ "$#" -gt 0 ] || { printf '  %s已取消%s\n' "$GRA" "$RST"; return 0; }
  echo
  cmd_up "$@"
}

ui_up_gen6() {
  hr "生成 — /64 里的一个 /128"
  kvp "来源段" "$GEN6_PREFIX::/64"
  _a="$(gen_v6_128)"
  echo
  kvp "生成" "$_a"
  dim "完整 8 段、不带 ::；每次生成都不一样"
  echo
  if ask "绑这一个地址？"; then
    echo
    cmd_up "$_a"
  else
    printf '  %s已取消%s\n' "$GRA" "$RST"
  fi
}

ui_up_gen4() {
  hr "生成 — /22 里的一个 /32"
  kvp "来源段" "$GEN4_CIDR"
  _a="$(gen_v4_32)"
  echo
  kvp "生成" "$_a"
  dim "每次生成都不一样；这一整段都是 KP"
  echo
  if ask "绑这一个地址？"; then
    echo
    cmd_up "$_a"
  else
    printf '  %s已取消%s\n' "$GRA" "$RST"
  fi
}

ui_status() {
  cmd_status
}

ui_down() {
  hr "删除网卡"
  if ! ip link show "$DEV" >/dev/null 2>&1; then
    dim "网卡 $DEV 不存在"
    return 0
  fi
  _v4=$(ip -o -4 addr show dev "$DEV" scope global 2>/dev/null | wc -l | tr -d ' ')
  _v6=$(ip -o -6 addr show dev "$DEV" scope global 2>/dev/null | wc -l | tr -d ' ')
  kvp "将删除" "$DEV（$_v4 个 IPv4 / $_v6 个 IPv6）"
  echo
  if ask "确认删除这张网卡和上面的地址？"; then
    echo
    cmd_down
  else
    printf '  %s已取消%s\n' "$GRA" "$RST"
  fi
}

ui_help() {
  hr "速查"
  sec "创建"
  note "  fip                    本菜单（无 TTY 时等同按地址提示）"
  note "  fip up                 选一条内置朝鲜 IP（6 选 1）"
  note "  fip up <地址...>       建网卡 + 绑指定地址 / 段"
  note "  fip up --all           6 条内置地址全部绑上"
  note "  fip add <地址...>      往已有网卡补地址"
  note "  fip gen6 / gen4        只生成一个段内地址并打印（不绑）"

  sec "查看 / 删除"
  note "  fip status             看网卡和地址"
  note "  fip down               删网卡（连同地址）"

  sec "地址写法"
  dim "单条   104.29.195.20         → /32"
  dim "带掩码 175.45.176.0/22"
  dim "IPv6   2606:54c1:1:c4::/64"
  dim "范围   175.45.176.0-175.45.179.255  → 自动换算 CIDR"
  dim "多条   空格或逗号分隔"

  sec "内置朝鲜 IP（菜单 1：6 选 1）"
  for _a in $DEFAULT_ADDRS; do dim "  $_a"; done
  echo
  dim "另可从 $GEN6_PREFIX::/64 生成一个 /128，从 $GEN4_CIDR 生成一个 /32"
  dim "不改探针、不写文件、不设自启；重启后地址会消失"
}

# ── 内置朝鲜 IP 子菜单 ────────────────────────────────────
ui_builtin() {
  while :; do
    ui_clear
    hr "内置朝鲜 IP"
    dim "选一条绑到 $DEV 上（不是整段全绑）"
    echo
    _n=0
    for _a in $DEFAULT_ADDRS; do
      _n=$(( _n + 1 ))
      item "$_n" "$_a"
    done
    _g1=$(( _n + 1 ))
    _g2=$(( _n + 2 ))
    echo
    item "$_g1" "从 $GEN6_PREFIX::/64 生成一个 /128"
    item "$_g2" "从 $GEN4_CIDR 生成一个 /32"
    item "0" "返回主菜单"
    echo
    printf '  %s❯%s %s请选择%s %s[0-%s]%s %s:%s ' \
      "$PINK_B" "$RST" "$BOLD_W" "$RST" "$TEAL_B" "$_g2" "$RST" "$GRA" "$RST"
    read -r c || return 0
    case "$c" in
      0|q|Q) return 0 ;;
      "$_g1") ui_up_gen6; pause; continue ;;
      "$_g2") ui_up_gen4; pause; continue ;;
    esac
    case "$c" in
      ''|*[!0-9]*) c=0 ;;
    esac
    if [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "$_n" ] 2>/dev/null; then
      ui_bind_one "$(pick_nth "$c" $DEFAULT_ADDRS)"
    else
      printf '  %s✘ 无效选项%s\n' "$BRED" "$RST"
    fi
    pause
  done
}

# ── 主菜单 ────────────────────────────────────────────────
cmd_menu() {
  while :; do
    ui_clear
    banner
    echo
    menu_status
    echo
    printf '   %s┄┄%s %s%s创建%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$SKY_B" "$RST" "$BORD" "$RST"
    item "1" "创建网卡 · 内置朝鲜 IP（6 选 1 / 段内生成）"
    item "2" "创建网卡 · 自己输入 IP / IP 段"
    echo
    printf '   %s┄┄%s %s%s查看与删除%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$VIO_B" "$RST" "$BORD" "$RST"
    item "3" "查看状态"
    item "4" "删除网卡"
    echo
    printf '   %s┄┄%s %s%s其他%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$ORNG_B" "$RST" "$BORD" "$RST"
    item "5" "帮助 / 速查"
    item "0" "退出"
    echo
    printf '  %s┈┈┈%s %s提示%s %s┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈%s\n' "$BORD2" "$RST" "$PINK_B" "$RST" "$BORD2" "$RST"
    dim "只建网卡、只绑地址：不改探针、不改路由、不写文件"
    dim "地址带 noprefixroute，路由表里不会多出东西"
    dim "删卡会连同上面所有地址一起删掉"
    echo
    printf '  %s❯%s %s请选择%s %s[0-5]%s %s:%s ' "$PINK_B" "$RST" "$BOLD_W" "$RST" "$TEAL_B" "$RST" "$GRA" "$RST"
    read -r c || return 0
    case "$c" in
      1) ui_builtin ;;
      2) ui_up_custom; pause ;;
      3) ui_status; pause ;;
      4) ui_down; pause ;;
      5) ui_help; pause ;;
      0) printf '\n  %s再见 👋%s\n\n' "$TEAL_B" "$RST"; exit 0 ;;
      *) printf '  %s✘ 无效选项%s\n' "$BRED" "$RST"; pause ;;
    esac
  done
}

usage() {
  printf 'fip %s — 只做一件事：建网卡，把 IP / IP 段绑上去\n\n' "$VERSION"
  cat <<'EOF'
用法：
  fip                       终端里进菜单
  fip up                    选一条内置朝鲜 IP（6 选 1）
  fip up <地址...>          建网卡并绑指定地址 / 段
  fip up --all              6 条内置地址全部绑上
  fip add <地址...>         往已有网卡补地址（等同 fip up）
  fip gen6                  打印一个 /128（不绑），可用 fip up $(fip gen6)
  fip gen4                  打印一个 /32（不绑）
  fip status                看网卡和地址
  fip down                  删网卡（连同上面的地址）
  fip help / fip version

菜单 1「内置朝鲜 IP」是 6 选 1，另加两个生成项：
  1) 104.29.195.20/32        4) 104.29.195.23/32
  2) 104.29.195.21/32        5) 2606:54c1:1:c4::/64
  3) 104.29.195.22/32        6) 175.45.176.0/22
  7) 从 2606:54c1:1:c4::/64 生成一个 /128（完整 8 段，每次不同）
  8) 从 175.45.176.0/22 生成一个 /32
  0) 返回主菜单

地址写法：
  104.29.195.20             单个 IPv4        → 加 /32
  175.45.176.0/22           带掩码的段
  2606:54c1:1:c4::/64       IPv6 段
  104.29.195.20-104.29.195.23   范围，自动换算成 CIDR
  "1.2.3.4 5.6.7.8"         多个：空格或逗号分隔

内置朝鲜 IP（菜单 1 的 6 条）：
  104.29.195.20/32  104.29.195.21/32  104.29.195.22/32  104.29.195.23/32
  2606:54c1:1:c4::/64
  175.45.176.0/22

环境变量：
  FIP_DEV=fip0                 网卡名
  FIP_DEFAULT_ADDRS="..."      内置 6 条的列表，空格分隔
  FIP_GEN6_PREFIX=2606:54c1:1:c4   /128 生成用的 /64 前缀
  FIP_GEN4_CIDR=175.45.176.0/22    /32 生成用的 IPv4 段
  FIP_NOPREFIXROUTE=0          关掉 noprefixroute（会向路由表加直连路由）
  FIP_COLOR=0                  关掉颜色（也认 NO_COLOR）

说明：
  * 只创建/删除一张网卡，只加/删地址；不改探针、不写任何文件、不设开机自启。
  * 绑地址用 noprefixroute：地址出现在网卡上，但不会往路由表加直连路由。
  * 重启后地址不会自动回来（本脚本不写自启）。
  * 需要 root / CAP_NET_ADMIN。

安装：
  install -m 755 fip-v0.4.sh /usr/local/bin/fip
EOF
}

# 没给地址时打印 6 条候选
no_addr_hint() {
  err "没给地址"
  dim "内置朝鲜 IP（选一条）："
  _n=0
  for _a in $DEFAULT_ADDRS; do
    _n=$(( _n + 1 ))
    dim "  $_n) $_a"
  done
  echo
  dim "用法：fip up <地址>       生成：fip gen6 / fip gen4"
  dim "     6 条全绑：fip up --all"
}

case "${1:-}" in
  '' )
      if [ -t 0 ] && [ -t 1 ] && [ "${FIP_MENU:-1}" != "0" ]; then
        cmd_menu
      elif [ "${FIP_MENU:-1}" = "0" ]; then
        cmd_up_all
      else
        no_addr_hint
        exit 1
      fi
      ;;
  menu|ui|tui|interactive|-i)      cmd_menu ;;
  gen6|v6|rnd6)                     gen_v6_128 ;;
  gen4|v4|rnd4)                     gen_v4_32 ;;
  up|on|create|new)
      shift
      case "${1:-}" in
        --all|all) cmd_up_all ;;
        '')        if [ -t 0 ] && [ -t 1 ]; then ui_builtin; else no_addr_hint; exit 1; fi ;;
        *)         cmd_up "$@" ;;
      esac
      ;;
  add|append)                       shift; cmd_up "$@" ;;
  down|off|del|delete|rm|remove)    cmd_down ;;
  status|show|stat|ls)              cmd_status ;;
  help|-h|--help)                   usage ;;
  version|-v|--version)             printf 'fip %s\n' "$VERSION" ;;
  *)                                cmd_up "$@" ;;
esac
