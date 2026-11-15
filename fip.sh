#!/bin/sh
# fip-v4.3.sh — 宿主机假网卡 + 按国家加地址（Cloudflare CSV）
#
# 一个「加地址」入口，三种来源：
#   1. 内置（朝鲜：2606:54c1:1:c4::/64、175.45.176.0/22、4 个 /32）
#   2. 按国家（Cloudflare local-ip-ranges.csv，v4/v6）
#   3. 手动
#
# 所有地址都走同一条：
#   ip addr add <地址> dev <设备> noprefixroute
#
# noprefixroute 的作用：地址照样显示，但不生成「这个网段在这张卡上」的直连路由，
# 避免把去往真实 IP（比如 Cloudflare 的段）的流量带进黑洞。
#
# 版本规则：每次改动 +0.1，新建文件，旧版本保留（fip-v4.3.sh → fip-v4.4.sh）。
#
# 用法：
#   fip                    菜单
#   fip v6 [前缀]          建 IPv6 网桥（默认 2606:54c1:1:c4）
#   fip v4 [段]            建 IPv4 网桥（默认 175.45.176.0/22）
#   fip add <地址/段>      手动加
#   fip add --builtin --one|--seg      内置取一个
#   fip add --country US --one|--seg   国家取一个
#   fip country list       列出 CSV 里的国家 + 段数
#   fip status             看设备和地址
#   fip down               删网桥
#   fip gen6 / gen4        生成 /128 或 /32
#   fip help / version
#
# 环境变量：
#   FIP_DEV=fip0                 默认设备
#   FIP_TYPE=dummy|bridge        设备类型（默认 dummy）
#   FIP_PREFIX=2606:54c1:1:c4    IPv6 默认前缀
#   FIP_V4=175.45.176.0/22       IPv4 默认段
#   FIP_CSV_URL=...              Cloudflare CSV 地址
#   FIP_CSV_CACHE=/var/tmp/fip-country.csv
#   FIP_CONF=/etc/fip.conf       保存“自动更新”设置
#   FIP_COLOR=0                  关颜色
set -u

VERSION="4.3"

DEV="${FIP_DEV:-fip0}"
DEV_TYPE="${FIP_TYPE:-dummy}"
PREFIX="${FIP_PREFIX:-2606:54c1:1:c4}"
V4_NET="${FIP_V4:-175.45.176.0/22}"
CSV_URL="${FIP_CSV_URL:-https://api.cloudflare.com/local-ip-ranges.csv}"
CSV_CACHE="${FIP_CSV_CACHE:-/var/tmp/fip-country.csv}"
CONF="${FIP_CONF:-/etc/fip.conf}"
CSV_TTL="${CSV_TTL:-0}"

[ -r "$CONF" ] && . "$CONF" 2>/dev/null
case "${CSV_TTL:-0}" in ''|*[!0-9]*) CSV_TTL=0 ;; esac

BUILTIN_V6="2606:54c1:1:c4::/64"
BUILTIN_V4="175.45.176.0/22"
BUILTIN_32="104.29.195.20/32 104.29.195.21/32 104.29.195.22/32 104.29.195.23/32"

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
  GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m'); MAG=$(printf '\033[35m'); CYN=$(printf '\033[36m')
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
  RST=""; BOLD=""; GRN=""; YEL=""; MAG=""; CYN=""; GRY=""; GRA=""
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
dim()  { printf '  %s%s%s\n' "$GRA" "$*" "$RST"; }
ok()   { printf '  %s%s%s\n' "$BGRN" "$*" "$RST"; }
warn() { printf '  %s%s%s\n' "$BYEL" "$*" "$RST"; }
err()  { printf '  %s%s%s\n' "$BRED" "$*" "$RST"; }
item() { printf '   %s▸%s  %s%s%s%s   %s%s%s\n' "$PINK_B" "$RST" "$BOLD_W" "$1" "$RST" "$RST" "$GRY" "$2" "$RST"; }
kvp()  { printf '  %s%-14s%s %s\n' "$GRA" "$1" "$RST" "$2"; }
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

# 从 stdin 随机取一行
rand_line() {
  awk -v seed="$(rand16)" 'BEGIN{srand(seed)} {a[NR]=$0} END{if(NR>0) print a[int(rand()*NR)+1]}'
}

# 段内随机取一个 IPv4 /32
random_v4_in() {
  _c="$1"; _p="${_c%%/*}"; _l="${_c##*/}"
  case "$_l" in ''|*[!0-9]*) _l=24 ;; esac
  if [ "$_l" -ge 31 ]; then printf '%s/32\n' "$_p"; return 0; fi
  _size=$(( 1 << (32 - _l) ))
  [ "$_size" -gt 65536 ] && _size=65536
  _r="$(rand16)"; _n=$(( _r % _size ))
  [ "$_n" -eq 0 ] && _n=1
  _b="$(ip2int "$_p")"
  printf '%s/32\n' "$(int2ip "$(( _b + _n ))")"
}

# 段内随机取一个 IPv6 /128（前缀 <= /64 时补 0 再拼 4 段随机）
random_v6_in() {
  _c="$1"; _p="${_c%%/*}"; _l="${_c##*/}"
  case "$_l" in ''|*[!0-9]*) _l=64 ;; esac
  if [ "$_l" -gt 64 ]; then printf '%s/128\n' "$_p"; return 0; fi
  while [ "${_p%:}" != "$_p" ]; do _p="${_p%:}"; done
  _g1=0; _g2=0; _g3=0; _g4=0; _n=0; _s="$_p"
  while [ -n "$_s" ]; do
    case "$_s" in
      *:*) _x="${_s%%:*}"; _s="${_s#*:}" ;;
      *)   _x="$_s"; _s="" ;;
    esac
    _n=$(( _n + 1 ))
    case "$_n" in
      1) [ -n "$_x" ] && _g1="$_x" ;;
      2) [ -n "$_x" ] && _g2="$_x" ;;
      3) [ -n "$_x" ] && _g3="$_x" ;;
      4) [ -n "$_x" ] && _g4="$_x" ;;
    esac
  done
  printf '%s:%s:%s:%s:%x:%x:%x:%x/128\n' \
    "$_g1" "$_g2" "$_g3" "$_g4" "$(rand16)" "$(rand16)" "$(rand16)" "$(rand16)"
}

gen_v6_128() {
  _p="$(norm_prefix "$PREFIX")"
  _n=1; _s="$_p"
  while :; do
    case "$_s" in *:*) _s="${_s#*:}"; _n=$(( _n + 1 )) ;; *) break ;; esac
  done
  while [ "$_n" -lt 4 ]; do _p="$_p:0"; _n=$(( _n + 1 )); done
  printf '%s:0:%x:%x:%x/128\n' "$_p" "$(rand16 1)" "$(rand16 2)" "$(rand16 3)"
}

gen_v4_32() {
  _r="$(rand16 v4)"; _n=$(( _r % 1024 ))
  _b="$(ip2int "175.45.176.0")"
  printf '%s/32\n' "$(int2ip "$(( _b + _n ))")"
}

# ── 设备 / 地址 ──────────────────────────────────────────
dev_exists() { ip link show "${1:-$DEV}" >/dev/null 2>&1; }

ensure_dev() {
  _n="${1:-$DEV}"
  if dev_exists "$_n"; then
    ip link set "$_n" up 2>/dev/null
    return 0
  fi
  if ip link add "$_n" type "$DEV_TYPE" 2>/dev/null; then
    ip link set "$_n" up 2>/dev/null
    ok "已建 $_n（$DEV_TYPE）"
    return 0
  fi
  err "建 $_n 失败：ip link add $_n type $DEV_TYPE"
  return 1
}

has_addr() {
  ip -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | grep -qxF "$2"
}

add_addr() {
  _d="${1:-$DEV}"; _a="$2"
  if has_addr "$_d" "$_a"; then
    dim "已存在：$_a"
    return 0
  fi
  if ip addr add "$_a" dev "$_d" noprefixroute 2>/dev/null; then
    ok "$_d  $_a"
    return 0
  fi
  dim "失败：$_a"
  return 1
}

cmd_v6() {
  _p="$(norm_prefix "${1:-$PREFIX}")"
  valid_prefix "$_p" || { err "前缀不对：$_p"; return 1; }
  hr "IPv6 网桥"
  ensure_dev "$DEV" || return 1
  kvp "设备" "$DEV（$DEV_TYPE）"
  kvp "地址" "${_p}::1/64"
  echo
  add_addr "$DEV" "${_p}::1/64"
  return 0
}

cmd_v4() {
  _net="${1:-$V4_NET}"
  valid_cidr "$_net" || { err "段不对：$_net"; return 1; }
  case "$_net" in *:*) err "这是 IPv6，用 fip v6"; return 1 ;; esac
  _base="${_net%%/*}"; _len="${_net##*/}"
  case "$_len" in ''|*[!0-9]*) _len=24 ;; esac
  _gw="$(int2ip "$(( $(ip2int "$_base") + 1 ))")"
  hr "IPv4 网桥"
  ensure_dev "$DEV" || return 1
  kvp "设备" "$DEV（$DEV_TYPE）"
  kvp "地址" "${_gw}/${_len}"
  echo
  add_addr "$DEV" "${_gw}/${_len}"
  return 0
}

cmd_status() {
  hr "状态"
  _d="${1:-$DEV}"
  if dev_exists "$_d"; then
    kvp "设备" "$_d"
    _a="$(ip -o addr show dev "$_d" scope global 2>/dev/null | awk '{print $3 " " $4}')"
    if [ -n "$_a" ]; then
      printf '%s\n' "$_a" | sed 's/^/   /'
    else
      dim "没有地址"
    fi
  else
    dim "设备 $_d 不存在（fip v6 / fip v4）"
  fi
  return 0
}

cmd_down() {
  hr "删除设备"
  if ! dev_exists "$DEV"; then
    dim "设备 $DEV 不存在"
    return 0
  fi
  if ip link del "$DEV" 2>/dev/null; then
    ok "已删除 $DEV"
  else
    err "删除失败：ip link del $DEV"
    return 1
  fi
  return 0
}

# ── Cloudflare CSV ───────────────────────────────────────
have_net() { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }

csv_age() {
  [ -s "$CSV_CACHE" ] || return 1
  _mt="$(stat -c %Y "$CSV_CACHE" 2>/dev/null || date -r "$CSV_CACHE" +%s 2>/dev/null)"
  [ -n "$_mt" ] || return 0
  _now="$(date +%s)"
  [ "$_now" -ge "$_mt" ] && echo $(( _now - _mt )) || echo 0
}

human_age() {
  _s="${1:-0}"
  case "$_s" in ''|*[!0-9]*) _s=0 ;; esac
  if [ "$_s" -lt 60 ]; then printf '%s 秒' "$_s"
  elif [ "$_s" -lt 3600 ]; then printf '%s 分钟' "$(( _s / 60 ))"
  elif [ "$_s" -lt 86400 ]; then printf '%s 小时' "$(( _s / 3600 ))"
  else printf '%s 天' "$(( _s / 86400 ))"; fi
}

ttl_text() {
  case "${CSV_TTL:-0}" in
    0) printf '关闭（只用缓存，手动更新）' ;;
    86400) printf '每天' ;;
    604800) printf '每周' ;;
    2592000) printf '每月' ;;
    *) printf '%s 秒' "$CSV_TTL" ;;
  esac
}

save_conf() {
  mkdir -p "$(dirname "$CONF")" 2>/dev/null || true
  if printf 'CSV_TTL=%s\n' "$1" > "$CONF" 2>/dev/null; then
    ok "已保存：$CONF（CSV_TTL=$1）"
  else
    err "写 $CONF 失败"
    return 1
  fi
}

_download_csv() {
  have_net || { err "没有 curl / wget"; return 1; }
  _tmp="$CSV_CACHE.$$"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 60 "$CSV_URL" -o "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  else
    wget -qO "$_tmp" "$CSV_URL" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  fi
  [ -s "$_tmp" ] || { rm -f "$_tmp"; return 1; }
  mv "$_tmp" "$CSV_CACHE"
  return 0
}

fetch_csv() {
  if [ -s "$CSV_CACHE" ]; then
    case "${CSV_TTL:-0}" in ''|*[!0-9]*) CSV_TTL=0 ;; esac
    [ "$CSV_TTL" -le 0 ] && return 0
    _age="$(csv_age)"
    [ -n "$_age" ] && [ "$_age" -lt "$CSV_TTL" ] && return 0
  fi
  _download_csv
}

cmd_csv_status() {
  hr "CSV 缓存"
  if [ -s "$CSV_CACHE" ]; then
    kvp "文件" "$CSV_CACHE"
    kvp "行数" "$(wc -l < "$CSV_CACHE" | tr -d ' ')"
    _age="$(csv_age)"
    [ -n "$_age" ] && kvp "更新于" "$(human_age "$_age") 前"
  else
    dim "还没有缓存（第一次用会自动下载）"
  fi
  kvp "自动更新" "$(ttl_text)"
  return 0
}

cmd_csv_refresh() {
  hr "更新 CSV"
  rm -f "$CSV_CACHE" 2>/dev/null
  if _download_csv; then
    ok "已更新：$CSV_CACHE（$(wc -l < "$CSV_CACHE" | tr -d ' ') 行）"
  else
    err "下载失败：$CSV_URL"
    return 1
  fi
  return 0
}

cmd_csv_ttl() {
  case "${1:-}" in
    off|0|none) _t=0 ;;
    daily|day) _t=86400 ;;
    weekly|week) _t=604800 ;;
    monthly|month) _t=2592000 ;;
    '') err "用法：fip data auto off|daily|weekly|monthly"; return 1 ;;
    *[!0-9]*) err "用法：fip data auto off|daily|weekly|monthly"; return 1 ;;
    *) _t="$1" ;;
  esac
  save_conf "$_t" || return 1
  CSV_TTL="$_t"
  return 0
}

ui_data() {
  hr "数据更新（Cloudflare CSV）"
  cmd_csv_status
  echo
  item "1" "立即更新"
  item "2" "自动更新：关闭"
  item "3" "自动更新：每天"
  item "4" "自动更新：每周"
  item "5" "自动更新：每月"
  item "0" "返回"
  echo
  readline "选择 [0-5]：" ""
  case "$UI_IN" in
    1) echo; cmd_csv_refresh ;;
    2) cmd_csv_ttl off ;;
    3) cmd_csv_ttl daily ;;
    4) cmd_csv_ttl weekly ;;
    5) cmd_csv_ttl monthly ;;
    *) dim "已取消" ;;
  esac
}

# 有没有表头：第一行是 "CIDR,CC," 这种数据行 → 无表头
csv_has_hdr() {
  _f="$(head -1 "$CSV_CACHE" 2>/dev/null | tr -d '\r')"
  case "$_f" in
    */*,*) return 1 ;;
  esac
  return 0
}

csv_skip() { if csv_has_hdr; then echo 1; else echo 0; fi; }

csv_col() {
  # 无表头：固定 1=CIDR，2=国家
  if ! csv_has_hdr; then
    case "$1" in
      country) echo 2 ;;
      ip)      echo 1 ;;
    esac
    return 0
  fi
  head -1 "$CSV_CACHE" 2>/dev/null | tr -d '\r' | awk -F, -v want="$1" '
    {
      for (i=1;i<=NF;i++) {
        h=tolower($i); gsub(/"/,"",h); gsub(/^[ \t]+|[ \t]+$/,"",h)
        if (want=="country" && (h=="country"||h=="country_code"||h=="iso"||h=="cc")) { print i; exit }
        if (want=="ip" && (h=="ip"||h=="network"||h=="cidr"||h=="prefix")) { print i; exit }
      }
    }'
}

csv_ok() {
  [ -s "$CSV_CACHE" ] && [ -n "$(csv_col country)" ] && [ -n "$(csv_col ip)" ]
}

csv_countries() {
  awk -F, -v c="$(csv_col country)" -v skip="$(csv_skip)" '
    NR>skip {
      gsub(/\r/,""); v=toupper($c); gsub(/"/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v)
      if (v != "") n[v]++
    }
    END { for (k in n) printf "%s %d\n", k, n[k] }
  ' "$CSV_CACHE" | sort -k2 -nr
}

country_segs() {  # $1=CC $2=v4|v6|both
  _cc="$(printf '%s' "$1" | tr 'a-z' 'A-Z')"
  _fam="${2:-both}"
  awk -F, -v c="$(csv_col country)" -v i="$(csv_col ip)" -v cc="$_cc" -v fam="$_fam" -v skip="$(csv_skip)" '
    NR>skip {
      gsub(/\r/,"")
      v=toupper($c); gsub(/"/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v)
      if (v != cc) next
      a=$i; gsub(/"/,"",a); gsub(/^[ \t]+|[ \t]+$/,"",a)
      if (a !~ /\//) next
      if (fam=="v4" && a ~ /:/) next
      if (fam=="v6" && a !~ /:/) next
      print a
    }' "$CSV_CACHE" | sort -u
}

cmd_country_list() {
  hr "Cloudflare 国家"
  fetch_csv || { err "下载失败：$CSV_URL"; dim "手动：curl -fsSL $CSV_URL -o $CSV_CACHE"; return 1; }
  csv_ok || { err "CSV 里没找到 country / ip 列"; dim "表头：$(head -1 "$CSV_CACHE" | tr -d '\r')"; return 1; }
  _list="$(csv_countries)"
  _total=$(printf '%s\n' "$_list" | grep -c .)
  kvp "国家数" "$_total"
  kvp "缓存" "$CSV_CACHE"
  echo
  printf '%s\n' "$_list" | awk '{printf "   %-4s %s\n", $1, $2}'
  return 0
}

# 选设备：fip0 或 fip1
choose_dev() {
  printf '   %s1%s  %s（现有设备）\n' "$BOLD_W" "$RST" "$DEV"
  printf '   %s2%s  新建 %s1（%s）\n' "$BOLD_W" "$RST" "$DEV" "$DEV_TYPE"
  echo
  readline "加到哪 [1/2，回车=1]：" "1"
  case "$UI_IN" in
    2)
      case "$DEV" in
        *0) TG_DEV="${DEV%0}1" ;;
        *)  TG_DEV="${DEV}1" ;;
      esac ;;
    *) TG_DEV="$DEV" ;;
  esac
  ensure_dev "$TG_DEV" || return 1
  return 0
}

# 加“段或单 IP”：$1=段列表（空格） $2=seg|one
apply_list() {
  _list="$1"; _form="${2:-seg}"
  _n=0
  for _c in $_list; do
    if [ "$_form" = "one" ]; then
      case "$_c" in
        *:*) _one="$(random_v6_in "$_c")" ;;
        *)   _one="$(random_v4_in "$_c")" ;;
      esac
      add_addr "$TG_DEV" "$_one" && _n=$(( _n + 1 ))
    else
      add_addr "$TG_DEV" "$_c" && _n=$(( _n + 1 ))
    fi
  done
  [ "$_n" -gt 0 ] && ok "共加 $_n 条" || dim "没有新增"
  return 0
}

# ── 界面流程 ─────────────────────────────────────────────
ui_builtin() {
  hr "内置段（朝鲜）"
  item "1" "$BUILTIN_V6"
  item "2" "$BUILTIN_V4"
  _i=2
  for _a in $BUILTIN_32; do
    _i=$(( _i + 1 ))
    item "$_i" "$_a"
  done
  echo
  readline "选择 [1-$_i]，回车取消：" ""
  case "$UI_IN" in ''|q|Q) dim "已取消"; return 0 ;; esac
  _sel=""; _j=0
  for _a in $BUILTIN_V6 $BUILTIN_V4 $BUILTIN_32; do
    _j=$(( _j + 1 ))
    [ "$_j" = "$UI_IN" ] && _sel="$_a"
  done
  [ -n "$_sel" ] || { err "无效选择"; return 0; }
  echo
  if [ "$_sel" = "$BUILTIN_V6" ] || [ "$_sel" = "$BUILTIN_V4" ]; then
    readline "形式 [1=段 2=单 IP，回车=1]：" "1"
    [ "$UI_IN" = "2" ] && _form=one || _form=seg
  else
    _form=seg
  fi
  echo
  choose_dev || return 1
  apply_list "$_sel" "$_form"
}

ui_country() {
  hr "按国家（Cloudflare）"
  fetch_csv || { err "下载失败：$CSV_URL"; dim "手动：curl -fsSL $CSV_URL -o $CSV_CACHE"; return 1; }
  csv_ok || { err "CSV 里没找到 country / ip 列"; return 1; }
  _top="$(csv_countries | head -20)"
  printf '   %s代码  段数%s\n' "$GRA" "$RST"
  printf '%s\n' "$_top" | awk '{printf "   %-4s %s\n", $1, $2}'
  echo
  readline "国家代码（如 US/SG/JP），回车取消：" ""
  [ -n "$UI_IN" ] || { dim "已取消"; return 0; }
  _cc="$(printf '%s' "$UI_IN" | tr 'a-z' 'A-Z')"
  readline "协议 [1=IPv4 2=IPv6 3=都，回车=3]：" "3"
  case "$UI_IN" in
    1) _fam=v4 ;;
    2) _fam=v6 ;;
    *) _fam=both ;;
  esac
  readline "形式 [1=段 2=单 IP，回车=2]：" "2"
  [ "$UI_IN" = "1" ] && _form=seg || _form=one
  echo
  _v4list=""; _v6list=""
  case "$_fam" in
    v4) _v4list="$(country_segs "$_cc" v4 | rand_line)" ;;
    v6) _v6list="$(country_segs "$_cc" v6 | rand_line)" ;;
    *)  _v4list="$(country_segs "$_cc" v4 | rand_line)"
        _v6list="$(country_segs "$_cc" v6 | rand_line)" ;;
  esac
  if [ -z "$_v4list" ] && [ -z "$_v6list" ]; then
    err "Cloudflare 里没有 $_cc 的段"
    return 1
  fi
  hr "$_cc"
  [ -n "$_v4list" ] && kvp "IPv4 段" "$_v4list"
  [ -n "$_v6list" ] && kvp "IPv6 段" "$_v6list"
  echo
  choose_dev || return 1
  _all="$_v4list $_v6list"
  apply_list "$_all" "$_form"
  return 0
}

ui_manual() {
  hr "手动加地址"
  dim "多个用空格或逗号分隔；支持 CIDR 和 a-b 范围"
  readline "地址（回车取消）：" ""
  [ -n "$UI_IN" ] || { dim "已取消"; return 0; }
  _hadf=0
  case "$-" in *f*) _hadf=1 ;; esac
  [ "$_hadf" = 1 ] || set -f
  _o="$IFS"; IFS=' ,'
  set -- $UI_IN
  IFS="$_o"
  [ "$_hadf" = 1 ] || set +f
  expand_addrs "$@" || return 1
  echo
  choose_dev || return 1
  apply_list "$ADDRS" seg
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
  item "fip add <地址/段>" "手动加"
  item "fip add --builtin --one|--seg" "内置取一个"
  item "fip add --country US --one|--seg" "国家取一个"
  item "fip country list" "列出国家"
  item "fip data refresh" "立即更新 CSV"
  item "fip data auto daily" "自动更新（off/daily/weekly/monthly）"
  item "fip status"    "看设备和地址"
  item "fip down"      "删除设备"
  echo
  dim "所有地址：ip addr add <地址> dev <设备> noprefixroute"
  dim "noprefixroute = 不生成网段路由，不影响真实流量"
  dim "环境变量：FIP_DEV=$DEV  FIP_TYPE=$DEV_TYPE"
}

cmd_menu() {
  while :; do
    ui_clear
    printf '\n'
    printf '  %s╭──────────────────────────────────────╮%s\n' "$BORD" "$RST"
    printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$BOLD_W" "fip $VERSION   ·   HOST BRIDGE" "$RST" "$BORD" "$RST"
    printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$GRA" "IPv6 / IPv4 / country IP" "$RST" "$BORD" "$RST"
    printf '  %s╰──────────────────────────────────────╯%s\n' "$BORD" "$RST"
    printf '   %s◆%s %sfip%s %s%s%s   %s·%s   %s宿主机网桥 · 加地址%s\n' \
      "$ORNG_B" "$RST" "$GRA" "$RST" "$BOLD_W" "$VERSION" "$RST" "$GRA" "$RST" "$TEAL_B" "$RST"
    echo
    printf '   %s┃%s ' "$BORD" "$RST"
    if dev_exists "$DEV"; then
      printf '%s◈%s 设备 %s%s%s %s\n' "$SKY_B" "$RST" "$BOLD_W" "$DEV" "$RST" "$(st_badge "$BGRN" "已建")"
    else
      printf '%s◈%s 设备 %s%s%s %s\n' "$SKY_B" "$RST" "$GRA" "$DEV" "$RST" "$(st_badge "$GRA" "未建")"
    fi
    if dev_exists "$DEV"; then
      _v6="$(ip -6 -o addr show dev "$DEV" scope global 2>/dev/null | awk '{print $4}' | head -1)"
      _v4="$(ip -4 -o addr show dev "$DEV" scope global 2>/dev/null | awk '{print $4}' | head -1)"
      printf '   %s┃%s %s◈%s IPv6 %s\n' "$BORD" "$RST" "$VIO_B" "$RST" "${_v6:-无}"
      printf '   %s┃%s %s◈%s IPv4 %s\n' "$BORD" "$RST" "$LIME_B" "$RST" "${_v4:-无}"
    fi
    echo
    item "1" "建网桥（$DEV）"
    item "2" "加地址（内置 / 国家 / 手动）"
    echo
    item "3" "查看状态"
    item "4" "生成地址（/128 或 /32）"
    item "5" "删除网桥"
    item "6" "数据更新（CSV 缓存）"
    item "7" "帮助"
    item "0" "退出"
    echo
    printf '  %s❯%s %s请选择%s %s[0-7]%s %s:%s ' "$PINK_B" "$RST" "$BOLD_W" "$RST" "$TEAL_B" "$RST" "$GRA" "$RST"
    read -r c || return 0
    case "$c" in
      1) ui_v6or4; pause ;;
      2) ui_add; pause ;;
      3) cmd_status; pause ;;
      4) ui_gen; pause ;;
      5) if ask "删除设备 $DEV？"; then echo; cmd_down; fi; pause ;;
      6) ui_data; pause ;;
      7) ui_help; pause ;;
      0) printf '\n  %s再见 👋%s\n\n' "$TEAL_B" "$RST"; exit 0 ;;
      *) printf '  %s✘ 无效选项%s\n' "$BRED" "$RST"; pause ;;
    esac
  done
}

ui_v6or4() {
  hr "建网桥"
  item "1" "IPv6（${PREFIX}::/64）"
  item "2" "IPv4（${V4_NET}）"
  echo
  readline "选择 [1-2]，回车取消：" ""
  case "$UI_IN" in
    1) echo; cmd_v6 ;;
    2) echo; cmd_v4 ;;
    *) dim "已取消" ;;
  esac
}

ui_add() {
  hr "加地址"
  item "1" "内置段（朝鲜）"
  item "2" "按国家（Cloudflare）"
  item "3" "手动输入"
  echo
  readline "选择 [1-3]，回车取消：" ""
  case "$UI_IN" in
    1) echo; ui_builtin ;;
    2) echo; ui_country ;;
    3) echo; ui_manual ;;
    *) dim "已取消" ;;
  esac
}

# ── 命令行 ───────────────────────────────────────────────
cmd_add() {
  _mode=manual; _cc=""; _form=seg; _fam=both; _dev="$DEV"; _addrs=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --builtin) _mode=builtin ;;
      --country) _mode=country; shift; _cc="${1:-}" ;;
      --one) _form=one ;;
      --seg) _form=seg ;;
      --v4) _fam=v4 ;;
      --v6) _fam=v6 ;;
      --both) _fam=both ;;
      --dev) shift; _dev="${1:-$DEV}" ;;
      *) _addrs="$_addrs $1" ;;
    esac
    shift
  done

  case "$_mode" in
    manual)
      [ -n "$_addrs" ] || { err "用法：fip add <地址/段>"; return 1; }
      if ! expand_addrs $_addrs; then return 1; fi
      ensure_dev "$_dev" || return 1
      TG_DEV="$_dev"
      apply_list "$ADDRS" seg
      ;;
    builtin)
      ensure_dev "$_dev" || return 1
      TG_DEV="$_dev"
      if [ "$_form" = "one" ]; then
        _pick="$(printf '%s\n' "$BUILTIN_V6" "$BUILTIN_V4" $BUILTIN_32 | rand_line)"
        apply_list "$_pick" one
      else
        apply_list "$BUILTIN_V6 $BUILTIN_V4" seg
      fi
      ;;
    country)
      [ -n "$_cc" ] || { err "用法：fip add --country US [--one|--seg] [--v4|--v6|--both]"; return 1; }
      fetch_csv || { err "下载失败：$CSV_URL"; return 1; }
      csv_ok || { err "CSV 里没找到 country / ip 列"; return 1; }
      _l=""
      case "$_fam" in
        v4) _l="$(country_segs "$_cc" v4 | rand_line)" ;;
        v6) _l="$(country_segs "$_cc" v6 | rand_line)" ;;
        *)  _l="$( (country_segs "$_cc" v4 | rand_line; country_segs "$_cc" v6 | rand_line) )" ;;
      esac
      [ -n "$_l" ] || { err "Cloudflare 里没有 $_cc 的段"; return 1; }
      ensure_dev "$_dev" || return 1
      TG_DEV="$_dev"
      for _x in $_l; do kvp "段" "$_x"; done
      apply_list "$_l" "$_form"
      ;;
  esac
  return 0
}

usage() {
  printf 'fip %s — 宿主机假网卡 + 按国家加地址（Cloudflare CSV）\n\n' "$VERSION"
  cat <<'EOF'
用法：
  fip                     菜单
  fip v6 [前缀]           建 IPv6 网桥，加 <前缀>::1/64
  fip v4 [段]             建 IPv4 网桥，加段的 .1
  fip add <地址/段>       手动加（CIDR / a-b 范围 / 多条）
  fip add --builtin --one|--seg        内置取一个
  fip add --country US --one|--seg     国家取一个
  fip add --country US --v4|--v6|--both
  fip country list        列出 CSV 里的国家 + 段数
  fip data status         看 CSV 缓存（文件、行数、更新时间、自动更新设置）
  fip data refresh        立即更新
  fip data auto off|daily|weekly|monthly   设置自动更新（默认 off）
  fip status              看设备和地址
  fip down                删除设备
  fip gen6 / gen4         生成 /128 或 /32
  fip help / version

规则：
  所有地址都是：ip addr add <地址> dev <设备> noprefixroute
  noprefixroute = 地址照常显示，但不生成网段直连路由，
  避免把去往真实 IP 的流量带进黑洞。

  段模式：原样加这条 CIDR
  单 IP ：从段里随机取一个（v4 /32、v6 /128）
  国家  ：从 Cloudflare CSV 里筛该国的段，随机挑一条

  CSV 默认不自动更新（只用缓存），可以在菜单 6 / fip data auto 里改成
  每天、每周、每月，或者 fip data refresh 手动更新。

环境变量：
  FIP_DEV=fip0                 默认设备
  FIP_TYPE=dummy|bridge        设备类型（默认 dummy）
  FIP_PREFIX=2606:54c1:1:c4    IPv6 默认前缀
  FIP_V4=175.45.176.0/22       IPv4 默认段
  FIP_CSV_URL=...              Cloudflare CSV 地址
  FIP_CSV_CACHE=/var/tmp/fip-country.csv
  FIP_COLOR=0                  关颜色
  FIP_MENU=0                   无参数不进菜单

安装：
  install -m 755 fip-v4.3.sh /usr/local/bin/fip
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
  add)               shift; cmd_add "$@" ;;
  country|cc)
      case "${2:-list}" in
        list|ls|'') cmd_country_list ;;
        *)
          _cc="$2"; shift 2
          cmd_add --country "$_cc" "$@" ;;
      esac ;;
  data|csv)
      case "${2:-status}" in
        status|''|show) cmd_csv_status ;;
        refresh|update|now) cmd_csv_refresh ;;
        auto|ttl) cmd_csv_ttl "${3:-}" ;;
        *) err "用法：fip data [status|refresh|auto off|daily|weekly|monthly]" ;;
      esac ;;
  status|show|stat)  cmd_status ;;
  down|off|del|delete) cmd_down ;;
  gen6)              gen_v6_128 ;;
  gen4)              gen_v4_32 ;;
  help|-h|--help)    usage ;;
  version|-v|--version) printf 'fip %s\n' "$VERSION" ;;
  *) printf '未知命令：%s\n\n' "$1"; usage; exit 1 ;;
esac
