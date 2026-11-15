#!/bin/sh
# fip-v4.7.sh — 宿主机假网卡 + 按国家加地址（Cloudflare CSV）
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
# 版本规则：每次改动 +0.1，新建文件，旧版本保留（fip-v4.7.sh → fip-v4.8.sh）。
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
  FIP_LOG=/var/log/fip.log     操作日志路径
  LOG_MAX_KB=512               超过就轮转
  LOG_KEEP=3                   保留旧日志个数
#   FIP_CONF=/etc/fip.conf       保存“自动更新”设置
#   FIP_LOG=/var/log/fip.log     操作日志
#   LOG_MAX_KB=512               日志超过 512KB 自动轮转
#   LOG_KEEP=3                   最多保留 3 个旧日志
#   FIP_COLOR=0                  关颜色
set -u

VERSION="4.7"

DEV="${FIP_DEV:-fip0}"
DEV_TYPE="${FIP_TYPE:-dummy}"
PREFIX="${FIP_PREFIX:-2606:54c1:1:c4}"
V4_NET="${FIP_V4:-175.45.176.0/22}"
CSV_URL="${FIP_CSV_URL:-https://api.cloudflare.com/local-ip-ranges.csv}"
CSV_CACHE="${FIP_CSV_CACHE:-/var/tmp/fip-country.csv}"
CONF="${FIP_CONF:-/etc/fip.conf}"
CSV_TTL="${CSV_TTL:-0}"
STATE="${FIP_STATE:-/etc/fip/state}"
LOG="${FIP_LOG:-/var/log/fip.log}"
LOG_MAX_KB="${LOG_MAX_KB:-512}"
LOG_KEEP="${LOG_KEEP:-3}"

[ -r "$CONF" ] && . "$CONF" 2>/dev/null
case "${CSV_TTL:-0}" in ''|*[!0-9]*) CSV_TTL=0 ;; esac


# 国家代码 -> 中文名（ISO 3166-1，来自 CSV 里出现的代码）
CC_NAMES="
AD 安道尔
AE 阿拉伯联合酋长国
AF 阿富汗
AG 安提瓜和巴布达
AI 安圭拉
AL 阿尔巴尼亚
AM 亚美尼亚
AO 安哥拉
AQ 南极洲
AR 阿根廷
AS 美属萨摩亚
AT 奥地利
AU 澳大利亚
AW 阿鲁巴
AX 奥兰群岛
AZ 阿塞拜疆
BA 波斯尼亚和黑塞哥维那
BB 巴巴多斯
BD 孟加拉国
BE 比利时
BF 布基纳法索
BG 保加利亚
BH 巴林
BI 布隆迪
BJ 贝宁
BL 圣巴泰勒米
BM 百慕大
BN 文莱
BO 玻利维亚
BQ 荷属加勒比区
BR 巴西
BS 巴哈马
BT 不丹
BV 布韦岛
BW 博茨瓦纳
BY 白俄罗斯
BZ 伯利兹
CA 加拿大
CC 科科斯（基林）群岛
CD 刚果（金）
CF 中非共和国
CG 刚果（布）
CH 瑞士
CI 科特迪瓦
CK 库克群岛
CL 智利
CM 喀麦隆
CN 中国
CO 哥伦比亚
CR 哥斯达黎加
CU 古巴
CV 佛得角
CW 库拉索
CX 圣诞岛
CY 塞浦路斯
CZ 捷克
DE 德国
DJ 吉布提
DK 丹麦
DM 多米尼克
DO 多米尼加共和国
DZ 阿尔及利亚
EC 厄瓜多尔
EE 爱沙尼亚
EG 埃及
EH 西撒哈拉
ER 厄立特里亚
ES 西班牙
ET 埃塞俄比亚
FI 芬兰
FJ 斐济
FK 福克兰群岛
FM 密克罗尼西亚
FO 法罗群岛
FR 法国
GA 加蓬
GB 英国
GD 格林纳达
GE 格鲁吉亚
GF 法属圭亚那
GG 根西岛
GH 加纳
GI 直布罗陀
GL 格陵兰
GM 冈比亚
GN 几内亚
GP 瓜德罗普
GQ 赤道几内亚
GR 希腊
GS 南乔治亚和南桑威奇群岛
GT 危地马拉
GU 关岛
GW 几内亚比绍
GY 圭亚那
HK 中国香港特别行政区
HM 赫德岛和麦克唐纳群岛
HN 洪都拉斯
HR 克罗地亚
HT 海地
HU 匈牙利
ID 印度尼西亚
IE 爱尔兰
IL 以色列
IM 马恩岛
IN 印度
IO 英属印度洋领地
IQ 伊拉克
IR 伊朗
IS 冰岛
IT 意大利
JE 泽西岛
JM 牙买加
JO 约旦
JP 日本
KE 肯尼亚
KG 吉尔吉斯斯坦
KH 柬埔寨
KI 基里巴斯
KM 科摩罗
KN 圣基茨和尼维斯
KP 朝鲜
KR 韩国
KW 科威特
KY 开曼群岛
KZ 哈萨克斯坦
LA 老挝
LB 黎巴嫩
LC 圣卢西亚
LI 列支敦士登
LK 斯里兰卡
LR 利比里亚
LS 莱索托
LT 立陶宛
LU 卢森堡
LV 拉脱维亚
LY 利比亚
MA 摩洛哥
MC 摩纳哥
MD 摩尔多瓦
ME 黑山
MF 法属圣马丁
MG 马达加斯加
MH 马绍尔群岛
MK 北马其顿
ML 马里
MM 缅甸
MN 蒙古
MO 中国澳门特别行政区
MP 北马里亚纳群岛
MQ 马提尼克
MR 毛里塔尼亚
MS 蒙特塞拉特
MT 马耳他
MU 毛里求斯
MV 马尔代夫
MW 马拉维
MX 墨西哥
MY 马来西亚
MZ 莫桑比克
NA 纳米比亚
NC 新喀里多尼亚
NE 尼日尔
NF 诺福克岛
NG 尼日利亚
NI 尼加拉瓜
NL 荷兰
NO 挪威
NP 尼泊尔
NR 瑙鲁
NU 纽埃
NZ 新西兰
OM 阿曼
PA 巴拿马
PE 秘鲁
PF 法属波利尼西亚
PG 巴布亚新几内亚
PH 菲律宾
PK 巴基斯坦
PL 波兰
PM 圣皮埃尔和密克隆群岛
PN 皮特凯恩群岛
PR 波多黎各
PS 巴勒斯坦领土
PT 葡萄牙
PW 帕劳
PY 巴拉圭
Pa Pa
QA 卡塔尔
RE 留尼汪
RO 罗马尼亚
RS 塞尔维亚
RU 俄罗斯
RW 卢旺达
SA 沙特阿拉伯
SB 所罗门群岛
SC 塞舌尔
SD 苏丹
SE 瑞典
SG 新加坡
SH 圣赫勒拿
SI 斯洛文尼亚
SJ 斯瓦尔巴和扬马延
SK 斯洛伐克
SL 塞拉利昂
SM 圣马力诺
SN 塞内加尔
SO 索马里
SR 苏里南
SS 南苏丹
ST 圣多美和普林西比
SV 萨尔瓦多
SX 荷属圣马丁
SY 叙利亚
SZ 斯威士兰
TC 特克斯和凯科斯群岛
TD 乍得
TF 法属南部领地
TG 多哥
TH 泰国
TJ 塔吉克斯坦
TK 托克劳
TL 东帝汶
TM 土库曼斯坦
TN 突尼斯
TO 汤加
TR 土耳其
TT 特立尼达和多巴哥
TV 图瓦卢
TW 台湾
TZ 坦桑尼亚
UA 乌克兰
UG 乌干达
UM 美国本土外小岛屿
US 美国
UY 乌拉圭
UZ 乌兹别克斯坦
VA 梵蒂冈
VC 圣文森特和格林纳丁斯
VE 委内瑞拉
VG 英属维尔京群岛
VI 美属维尔京群岛
VN 越南
VU 瓦努阿图
WF 瓦利斯和富图纳
WS 萨摩亚
XK 科索沃
YE 也门
YT 马约特
ZA 南非
ZM 赞比亚
ZW 津巴布韦
"
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
  while [ "${_p%:}" != "$_p" ]; do _p="${_p%:}"; done
  _g1=0; _g2=0; _g3=0; _g4=0; _g5=0; _g6=0; _g7=0; _g8=0
  _n=0; _s="$_p"
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
      5) [ -n "$_x" ] && _g5="$_x" ;;
      6) [ -n "$_x" ] && _g6="$_x" ;;
      7) [ -n "$_x" ] && _g7="$_x" ;;
      8) [ -n "$_x" ] && _g8="$_x" ;;
    esac
  done
  if [ "$_l" -le 64 ]; then
    printf '%s:%s:%s:%s:%x:%x:%x:%x/128\n' \
      "$_g1" "$_g2" "$_g3" "$_g4" "$(rand16)" "$(rand16)" "$(rand16)" "$(rand16)"
  else
    printf '%s:%s:%s:%s:%s:%s:%s:%s/128\n' \
      "$_g1" "$_g2" "$_g3" "$_g4" "$_g5" "$_g6" "$_g7" "$_g8"
  fi
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
  _base="${V4_NET%%/*}"; _len="${V4_NET##*/}"
  case "$_len" in ''|*[!0-9]*) _len=22 ;; esac
  _size=$(( 1 << (32 - _len) ))
  [ "$_size" -gt 65536 ] && _size=65536
  _r="$(rand16 v4)"; _n=$(( _r % _size ))
  _b="$(ip2int "$_base")"
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
    log_write skip "$_d $_a"
    return 2
  fi
  if ip addr add "$_a" dev "$_d" noprefixroute 2>/dev/null; then
    ok "$_d  $_a"
    log_write add "$_d $_a"
    return 0
  fi
  dim "失败：$_a"
  log_write fail "$_d $_a"
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

# 所有 fip* 设备（含 DEV）
fip_devs() {
  { printf '%s\n' "$DEV"
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}'
  } | awk -v d="$DEV" '$0==d || $0 ~ /^fip/' | sort -u | while IFS= read -r _d; do
    dev_exists "$_d" && printf '%s\n' "$_d"
  done
}

# 每行：设备|family|地址/掩码
addr_rows() {
  for _d in $(fip_devs); do
    ip -o addr show dev "$_d" scope global 2>/dev/null | awk -v d="$_d" '{print d "|" $3 "|" $4}'
  done
}

cmd_status() {
  hr "状态"
  _rows="$(addr_rows)"
  _found=0
  for _d in $(fip_devs); do
    _found=1
    kvp "设备" "$_d"
    _a="$(printf '%s\n' "$_rows" | awk -F'|' -v d="$_d" '$1==d{print "   " $2 " " $3}')"
    if [ -n "$_a" ]; then printf '%s\n' "$_a"; else dim "   没有地址"; fi
  done
  [ "$_found" -eq 0 ] && dim "没有 fip* 设备（fip v6 / fip v4）"
  return 0
}

# 删除一个地址（带序号选择）
cmd_del_addr() {
  _rows="$(addr_rows)"
  if [ -z "$_rows" ]; then dim "没有可删的地址"; return 0; fi
  hr "选择要删除的地址"
  printf '%s\n' "$_rows" | awk -F'|' '{printf "   %2d  %-6s %s\n", NR, $1, $3}'
  echo
  readline "序号（回车取消）：" ""
  case "$UI_IN" in ''|*[!0-9]*) dim "已取消"; return 0 ;; esac
  _line="$(printf '%s\n' "$_rows" | awk -F'|' -v n="$UI_IN" 'NR==n{print $1 "|" $3}')"
  [ -n "$_line" ] || { err "序号不对"; return 0; }
  _dd="${_line%%|*}"; _aa="${_line#*|}"
  if ip addr del "$_aa" dev "$_dd" 2>/dev/null; then
    ok "已删除 $_dd  $_aa"
    log_write del "$_dd $_aa"
  else
    err "删除失败：$_dd $_aa"
  fi
  return 0
}

# 删除整个设备（带序号选择）
cmd_del_dev() {
  _devs="$(fip_devs)"
  if [ -z "$_devs" ]; then dim "没有 fip* 设备"; return 0; fi
  hr "选择要删除的设备"
  printf '%s\n' "$_devs" | awk '{printf "   %2d  %s\n", NR, $0}'
  echo
  readline "序号（回车取消）：" ""
  case "$UI_IN" in ''|*[!0-9]*) dim "已取消"; return 0 ;; esac
  _dd="$(printf '%s\n' "$_devs" | awk -v n="$UI_IN" 'NR==n{print}')"
  [ -n "$_dd" ] || { err "序号不对"; return 0; }
  if ip link del "$_dd" 2>/dev/null; then
    ok "已删除设备 $_dd"
    log_write deldev "$_dd"
  else
    err "删除失败：$_dd"
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
  _first="$(head -1 "$_tmp" 2>/dev/null | tr -d '\r')"
  case "$_first" in
    */*,*) ;;
    *) rm -f "$_tmp"; err "下载内容不像 CSV：$_first"; return 1 ;;
  esac
  mv "$_tmp" "$CSV_CACHE"
  return 0
}

fetch_csv() {
  if [ -s "$CSV_CACHE" ]; then
    case "${CSV_TTL:-0}" in ''|*[!0-9]*) CSV_TTL=0 ;; esac
    [ "$CSV_TTL" -le 0 ] && return 0
    _age="$(csv_age)"
    [ -n "$_age" ] && [ "$_age" -lt "$CSV_TTL" ] && return 0
    if _download_csv; then return 0; fi
    warn "更新失败，继续使用旧缓存"
    return 0
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
  if _download_csv; then
    ok "已更新：$CSV_CACHE（$(wc -l < "$CSV_CACHE" | tr -d ' ') 行）"
    log_write csv "refresh ok"
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
  printf '%s\n' "$_list" | awk -v names="$CC_NAMES" '
    BEGIN { n=split(names,a,"\n"); for(i=1;i<=n;i++){ split(a[i],p," "); m[p[1]]=substr(a[i], length(p[1])+2) } }
    { printf "   %-4s %-18s %s\n", $1, (($1 in m)?m[$1]:""), $2 }'
  return 0
}

# 选设备：fip0 或 fip1
choose_dev() {
  case "$DEV" in
    *0) _new="${DEV%0}1" ;;
    *)  _new="${DEV}1" ;;
  esac
  printf '   %s1%s  %s（现有设备）\n' "$BOLD_W" "$RST" "$DEV"
  if dev_exists "$_new"; then
    printf '   %s2%s  %s（已存在，复用）\n' "$BOLD_W" "$RST" "$_new"
  else
    printf '   %s2%s  新建 %s（%s）\n' "$BOLD_W" "$RST" "$_new" "$DEV_TYPE"
  fi
  echo
  readline "加到哪 [1/2，回车=1]：" "1"
  case "$UI_IN" in
    2) TG_DEV="$_new" ;;
    *) TG_DEV="$DEV" ;;
  esac
  ensure_dev "$TG_DEV" || return 1
  return 0
}

# 加“段或单 IP”：$1=段列表（空格） $2=seg|one
apply_list() {
  _list="$1"; _form="${2:-seg}"
  _new=0; _skip=0; _fail=0
  for _c in $_list; do
    if [ "$_form" = "one" ]; then
      case "$_c" in
        *:*) _a="$(random_v6_in "$_c")" ;;
        *)   _a="$(random_v4_in "$_c")" ;;
      esac
    else
      _a="$_c"
    fi
    add_addr "$TG_DEV" "$_a"; _r=$?
    case "$_r" in
      0) _new=$(( _new + 1 )) ;;
      2) _skip=$(( _skip + 1 )) ;;
      *) _fail=$(( _fail + 1 )) ;;
    esac
  done
  [ "$_new" -gt 0 ] && ok "新增 $_new 条"
  [ "$_skip" -gt 0 ] && dim "已存在 $_skip 条"
  [ "$_fail" -gt 0 ] && warn "失败 $_fail 条"
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
  _rows="$(csv_countries)"
  _total=$(printf '%s\n' "$_rows" | grep -c .)
  if [ "$_total" -eq 0 ]; then
    err "CSV 里没有国家数据（缓存可能损坏，试 fip data refresh）"
    return 1
  fi
  _per=20
  _pages=$(( (_total + _per - 1) / _per ))
  [ "$_pages" -lt 1 ] && _pages=1
  _pg=1
  _cc=""
  while [ -z "$_cc" ]; do
    _s=$(( (_pg - 1) * _per + 1 ))
    _e=$(( _pg * _per ))
    printf '   %s第 %d/%d 页 · 共 %d 个国家%s\n\n' "$GRA" "$_pg" "$_pages" "$_total" "$RST"
    printf '   %s 序号 代码 名称             段数%s\n' "$GRA" "$RST"
    printf '%s\n' "$_rows" | awk -v s="$_s" -v e="$_e" -v names="$CC_NAMES" '
      BEGIN { n=split(names,a,"\n"); for(i=1;i<=n;i++){ split(a[i],p," "); m[p[1]]=substr(a[i], length(p[1])+2) } }
      NR>=s && NR<=e { printf "   %3d  %-4s %-16s %s\n", NR, $1, (($1 in m)?m[$1]:""), $2 }
    '
    echo
    readline "序号 / n下一页 / p上一页 / 代码 / 回车取消：" ""
    case "$UI_IN" in
      ''|q|Q) return 0 ;;
      n|N) [ "$_pg" -lt "$_pages" ] && _pg=$(( _pg + 1 )) ;;
      p|P) [ "$_pg" -gt 1 ] && _pg=$(( _pg - 1 )) ;;
      *[!0-9]*) _cc="$(printf '%s' "$UI_IN" | tr 'a-z' 'A-Z')" ;;
      *)
        _pick="$(printf '%s\n' "$_rows" | awk -v n="$UI_IN" 'NR==n{print $1}')"
        if [ -n "$_pick" ]; then _cc="$_pick"; else err "序号不对"; fi ;;
    esac
  done
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
  item "fip status"    "看所有设备和地址"
  item "fip del-addr"  "按序号删地址"
  item "fip del-dev"   "按序号删设备"
  item "fip save"      "保存当前状态（可选开机恢复）"
  item "fip restore"   "立即恢复"
  item "fip log"       "操作日志（status/tail/clear）"
  echo
  dim "所有地址：ip addr add <地址> dev <设备> noprefixroute"
  dim "noprefixroute = 不生成网段路由，不影响真实流量"
  dim "环境变量：FIP_DEV=$DEV  FIP_TYPE=$DEV_TYPE"
}

# ── 操作日志 ─────────────────────────────────────────────
log_size() {
  [ -f "$LOG" ] || { printf '0'; return 0; }
  wc -c < "$LOG" 2>/dev/null | tr -d ' '
}

rotate_log() {
  [ -f "$LOG" ] || return 0
  _max=$(( ${LOG_MAX_KB:-512} * 1024 ))
  [ "$(log_size)" -lt "$_max" ] && return 0
  _i="${LOG_KEEP:-3}"
  while [ "$_i" -gt 1 ]; do
    [ -f "$LOG.$((_i-1))" ] && mv -f "$LOG.$((_i-1))" "$LOG.$_i" 2>/dev/null
    _i=$(( _i - 1 ))
  done
  mv -f "$LOG" "$LOG.1" 2>/dev/null
  return 0
}

log_write() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  rotate_log
  printf '%s  %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "${1:-info}" "${2:-}" >> "$LOG" 2>/dev/null
  return 0
}

cmd_log() {
  _act="${1:-status}"
  case "$_act" in
    status|'')
      hr "操作日志"
      kvp "文件" "$LOG"
      if [ -f "$LOG" ]; then
        kvp "大小" "$(log_size) 字节"
        kvp "行数" "$(wc -l < "$LOG" | tr -d ' ')"
        kvp "轮转" "超过 ${LOG_MAX_KB}KB，保留 ${LOG_KEEP} 个"
        echo
        tail -10 "$LOG" 2>/dev/null | sed 's/^/   /'
      else
        dim "还没有日志"
      fi ;;
    tail|show)
      [ -f "$LOG" ] || { dim "还没有日志"; return 0; }
      tail -n "${2:-30}" "$LOG" 2>/dev/null | sed 's/^/   /' ;;
    clear|clean)
      rm -f "$LOG" "$LOG".* 2>/dev/null
      ok "日志已清空" ;;
    *) err "用法：fip log [status|tail [n]|clear]" ;;
  esac
  return 0
}

ui_log() {
  hr "操作日志"
  cmd_log status
  echo
  item "1" "查看最近 30 条"
  item "2" "清空日志"
  item "0" "返回"
  echo
  readline "选择 [0-2]：" ""
  case "$UI_IN" in
    1) echo; cmd_log tail 30 ;;
    2) if ask "清空 $LOG 和旧日志？"; then echo; cmd_log clear; fi ;;
    *) dim "已取消" ;;
  esac
}

# ── 保存 / 恢复 ──────────────────────────────────────────
dev_type_of() {
  if ip -d link show dev "$1" 2>/dev/null | grep -qw dummy; then
    printf 'dummy'
  else
    printf 'bridge'
  fi
}

save_state() {
  _devs="$(fip_devs)"
  [ -n "$_devs" ] || { err "没有 fip* 设备可保存"; return 1; }
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
  {
    printf '# fip state v1\n'
    for _d in $_devs; do
      printf 'dev %s %s\n' "$_d" "$(dev_type_of "$_d")"
      ip -o addr show dev "$_d" scope global 2>/dev/null | awk -v d="$_d" '{print "addr", d, $4}'
    done
  } > "$STATE" 2>/dev/null || { err "写 $STATE 失败"; return 1; }
  ok "已保存：$STATE"
  log_write save "$STATE"
  dim "设备 $(printf '%s\n' "$_devs" | grep -c .) 个，地址 $(grep -c '^addr ' "$STATE" 2>/dev/null) 条"
  return 0
}

restore_state() {
  [ -s "$STATE" ] || { dim "没有保存（先 fip save）"; return 1; }
  hr "恢复"
  while IFS=' ' read -r _k _a _b; do
    case "$_k" in
      dev)
        if ! ip link show "$_a" >/dev/null 2>&1; then
          ip link add "$_a" type "$_b" 2>/dev/null && ok "建 $_a（$_b）"
        fi
        ip link set "$_a" up 2>/dev/null ;;
      addr)
        ip addr add "$_b" dev "$_a" noprefixroute 2>/dev/null && ok "$_a  $_b" ;;
    esac
  done < "$STATE"
  log_write restore "$STATE"
  return 0
}

unsave_state() {
  rm -f "$STATE" 2>/dev/null
  ok "已删除 $STATE"
  return 0
}

install_boot() {
  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/fip-restore.service <<'EOF'
[Unit]
Description=fip restore fake addresses
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fip restore

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null
    systemctl enable fip-restore.service >/dev/null 2>&1 && ok "已启用 fip-restore.service"
  elif [ -d /etc/local.d ]; then
    printf '#!/bin/sh\n/usr/local/bin/fip restore\n' > /etc/local.d/fip-restore.start
    chmod +x /etc/local.d/fip-restore.start
    rc-update add local default >/dev/null 2>&1 && ok "已写入 /etc/local.d/fip-restore.start"
  else
    err "不认识的 init（没有 systemctl / /etc/local.d）"
    return 1
  fi
  return 0
}

uninstall_boot() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable fip-restore.service >/dev/null 2>&1
    rm -f /etc/systemd/system/fip-restore.service
    systemctl daemon-reload 2>/dev/null
    ok "已移除 fip-restore.service"
  fi
  rm -f /etc/local.d/fip-restore.start 2>/dev/null
  return 0
}

ui_save() {
  hr "保存 / 开机恢复"
  if [ -s "$STATE" ]; then
    kvp "已保存" "$STATE（$(grep -c '^addr ' "$STATE" 2>/dev/null) 条地址）"
  else
    kvp "已保存" "还没有"
  fi
  echo
  item "1" "保存当前状态"
  item "2" "立即恢复"
  item "3" "删除保存"
  item "4" "安装开机自动恢复"
  item "5" "卸载开机自动恢复"
  item "0" "返回"
  echo
  readline "选择 [0-5]：" ""
  case "$UI_IN" in
    1) echo; save_state; if ask "同时设置开机自动恢复？"; then install_boot; fi ;;
    2) echo; restore_state ;;
    3) echo; unsave_state ;;
    4) echo; install_boot ;;
    5) echo; uninstall_boot ;;
    *) dim "已取消" ;;
  esac
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
    _devs="$(fip_devs)"
    if [ -n "$_devs" ]; then
      for _d in $_devs; do
        _n="$(ip -o addr show dev "$_d" scope global 2>/dev/null | grep -c .)"
        _v6="$(ip -6 -o addr show dev "$_d" scope global 2>/dev/null | awk '{print $4}' | head -1)"
        _v4="$(ip -4 -o addr show dev "$_d" scope global 2>/dev/null | awk '{print $4}' | head -1)"
        printf '   %s┃%s %s◈%s %s%s%s  %s 条  %s\n' \
          "$BORD" "$RST" "$SKY_B" "$RST" "$BOLD_W" "$_d" "$RST" "$_n" \
          "${_v6:-}${_v4:+ / $_v4}"
      done
    else
      printf '   %s┃%s %s◈%s 设备 %s（未建）\n' "$BORD" "$RST" "$SKY_B" "$RST" "$DEV"
    fi
    echo
    item "1" "建网桥（$DEV）"
    item "2" "加地址（内置 / 国家 / 手动）"
    echo
    item "3" "查看状态"
    item "4" "生成地址（/128 或 /32）"
    item "5" "删除（地址 / 设备）"
    item "6" "保存 / 开机恢复"
    item "7" "操作日志"
    item "8" "数据更新（CSV 缓存）"
    item "9" "帮助"
    item "0" "退出"
    echo
    printf '  %s❯%s %s请选择%s %s[0-9]%s %s:%s ' "$PINK_B" "$RST" "$BOLD_W" "$RST" "$TEAL_B" "$RST" "$GRA" "$RST"
    read -r c || return 0
    case "$c" in
      1) ui_v6or4; pause ;;
      2) ui_add; pause ;;
      3) cmd_status; pause ;;
      4) ui_gen; pause ;;
      5) ui_del; pause ;;
      6) ui_save; pause ;;
      7) ui_log; pause ;;
      8) ui_data; pause ;;
      9) ui_help; pause ;;
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

ui_del() {
  hr "删除"
  item "1" "删除一个地址（列出所有设备上的）"
  item "2" "删除整个设备"
  echo
  readline "选择 [1-2]，回车取消：" ""
  case "$UI_IN" in
    1) echo; cmd_del_addr ;;
    2) echo; cmd_del_dev ;;
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
  fip status              看所有 fip* 设备和地址（带序号）
  fip del-addr            列出所有地址，选序号删除
  fip del-dev             列出所有设备，选序号删除
  fip down                删除默认设备
  fip save                保存当前设备+地址到 /etc/fip/state
  fip restore             立即恢复
  fip unsave              删除保存
  fip boot-install        安装开机自动恢复
  fip boot-remove         卸载开机自动恢复
  fip log [status|tail [n]|clear]   操作日志
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
  FIP_LOG=/var/log/fip.log     操作日志路径
  LOG_MAX_KB=512               超过就轮转
  LOG_KEEP=3                   保留旧日志个数
  FIP_COLOR=0                  关颜色
  FIP_MENU=0                   无参数不进菜单

安装：
  install -m 755 fip-v4.7.sh /usr/local/bin/fip
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
  log|logs)           cmd_log "${2:-status}" "${3:-30}" ;;
  save)               save_state ;;
  restore)            restore_state ;;
  unsave)             unsave_state ;;
  boot-install)       install_boot ;;
  boot-remove)        uninstall_boot ;;
  data|csv)
      case "${2:-status}" in
        status|''|show) cmd_csv_status ;;
        refresh|update|now) cmd_csv_refresh ;;
        auto|ttl) cmd_csv_ttl "${3:-}" ;;
        *) err "用法：fip data [status|refresh|auto off|daily|weekly|monthly]" ;;
      esac ;;
  del-addr|rmaddr)   cmd_del_addr ;;
  del-dev|rmdev)     cmd_del_dev ;;
  status|show|stat)  cmd_status ;;
  down|off|del|delete) cmd_down ;;
  gen6)              gen_v6_128 ;;
  gen4)              gen_v4_32 ;;
  help|-h|--help)    usage ;;
  version|-v|--version) printf 'fip %s\n' "$VERSION" ;;
  *) printf '未知命令：%s\n\n' "$1"; usage; exit 1 ;;
esac
