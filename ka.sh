#!/usr/bin/env bash
# =============================================================================
#  ka  ·  Komari Agent 部署器  (colorful UI)
#  版本: 0.1.1        归档文件: ka-v<版本>.sh
#
#  用法:
#    ka                     交互式向导（单实例 / 同机多开）
#    ka status              实例状态面板
#    ka logs 1 [行数]       查看日志（all = 全部）
#    ka uninstall           卸载实例
#    ka version             版本与归档信息
#    ka bump                发布新版本（+0.1，旧版本文件保留）
#    ka self-install        安装到 /opt/ka 并建立 ka 命令
#
#  界面: 自动检测 256 色 / 16 色 / 纯文本；NO_COLOR=1 或 KA_UI=plain 可关闭彩色
#  版本: 默认 KA_BUMP_STYLE=minor : 0.0.1 → 0.1.1 → 0.2.1
#        改 patch               : 0.0.1 → 0.0.2 → 0.0.3
# =============================================================================

set -u

KA_VERSION="0.1.1"
KA_BUMP_STYLE="minor"
KA_INSTALLER="https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh"
KA_CONF="${KA_CONF:-/etc/ka.conf}"

KA_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
KA_DIR="$(dirname "$KA_SELF")"

# =============================================================== 主题引擎 ===
COLOR_DEPTH=0
UTF8=0
B=""; DIM=""; RESET=""
PINK=""; PURP=""; BLUE=""; CYAN=""; GREEN=""; YELL=""; RED=""; GRAY=""; WHITE=""
G_OK="OK"; G_ERR="x"; G_WARN="!"; G_INFO="*"
G_DOT="o"; G_DOT_OFF="."; G_DOT_CUR="O"; G_BAR="|"; G_ARROW=">"; G_RULE="-"

detect_color() {
  COLOR_DEPTH=0
  [ "${KA_UI:-auto}" = "plain" ] && return 0
  [ -n "${NO_COLOR:-}" ] && return 0
  [ -t 1 ] || return 0
  local term="${TERM:-dumb}"
  case "$term" in dumb|'') return 0 ;; esac
  local n=8
  if command -v tput >/dev/null 2>&1; then
    n="$(tput colors 2>/dev/null || printf '8')"
  fi
  case "$n" in ''|*[!0-9]*) n=8 ;; esac
  if [ "$n" -ge 256 ]; then
    COLOR_DEPTH=256
  elif [ "${term#*256color}" != "$term" ]; then
    COLOR_DEPTH=256
  else
    COLOR_DEPTH=16
  fi
}

ui_init() {
  detect_color
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UTF8=1 ;;
    *) UTF8=0 ;;
  esac

  if [ "$COLOR_DEPTH" -eq 0 ]; then
    B=""; DIM=""; RESET=""
    PINK=""; PURP=""; BLUE=""; CYAN=""; GREEN=""; YELL=""; RED=""; GRAY=""; WHITE=""
    G_OK="[OK]"; G_ERR="[!!]"; G_WARN="[!]"; G_INFO="->"
    G_DOT="o"; G_DOT_OFF="."; G_DOT_CUR="O"; G_BAR="|"; G_ARROW=">"; G_RULE="-"
    return 0
  fi

  B=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  if [ "$COLOR_DEPTH" -ge 256 ]; then
    PINK=$'\033[38;5;212m'
    PURP=$'\033[38;5;141m'
    BLUE=$'\033[38;5;111m'
    CYAN=$'\033[38;5;117m'
    GREEN=$'\033[38;5;120m'
    YELL=$'\033[38;5;221m'
    RED=$'\033[38;5;210m'
    GRAY=$'\033[38;5;244m'
    WHITE=$'\033[38;5;255m'
  else
    PINK=$'\033[95m'; PURP=$'\033[35m'; BLUE=$'\033[94m'; CYAN=$'\033[96m'
    GREEN=$'\033[92m'; YELL=$'\033[93m'; RED=$'\033[91m'; GRAY=$'\033[90m'
    WHITE=$'\033[97m'
  fi

  if [ "$UTF8" -eq 1 ]; then
    G_OK="✔"; G_ERR="✘"; G_WARN="▲"; G_INFO="◆"
    G_DOT="●"; G_DOT_OFF="○"; G_DOT_CUR="◉"
    G_BAR="┃"; G_ARROW="▸"; G_RULE="─"
  fi
}
ui_init

# ================================================================ 文本工具 ===
say()  { printf '%s\n' "$*"; }
blank(){ printf '\n'; }

info() { printf '  %s%s%s %s\n' "$CYAN" "$G_INFO" "$RESET" "$*"; }
ok()   { printf '  %s%s%s %s\n' "$GREEN" "$G_OK" "$RESET" "$*"; }
warn() { printf '  %s%s%s %s\n' "$YELL" "$G_WARN" "$RESET" "$*"; }
err()  { printf '  %s%s%s %s\n' "$RED" "$G_ERR" "$RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
dim()  { printf '  %s%s%s\n' "$GRAY" "$*" "$RESET"; }

# 显示宽度（中文算 2 格）与右填充
disp_width() {
  local s="$1" w=""
  if command -v wc >/dev/null 2>&1; then
    w="$(printf '%s' "$s" | wc -L 2>/dev/null | tr -d ' ')"
  fi
  case "$w" in ''|*[!0-9]*) w="${#s}" ;; esac
  printf '%s' "$w"
}

padr() {
  local s="$1" w="$2" d
  d="$(disp_width "$s")"
  if [ "$d" -lt "$w" ]; then
    printf '%s%*s' "$s" $((w - d)) ''
  else
    printf '%s' "$s"
  fi
}

repeat() { # repeat <字符> <次数>
  local ch="$1" n="$2" i out=""
  for ((i = 0; i < n; i++)); do out+="$ch"; done
  printf '%s' "$out"
}

rainbow() { # 只处理 ASCII，逐字上色
  local s="$1" i out=""
  if [ "$COLOR_DEPTH" -eq 0 ]; then printf '%s' "$s"; return 0; fi
  local -a pal=("$PINK" "$PURP" "$BLUE" "$CYAN" "$GREEN" "$YELL")
  for ((i = 0; i < ${#s}; i++)); do
    out+="${pal[$((i % 6))]}${s:i:1}"
  done
  printf '%s%s' "$out" "$RESET"
}

rule() { # 四段渐变的横线
  local w="${1:-58}" seg=$(((w + 3) / 4)) j i s
  local -a cols=("$PINK" "$PURP" "$BLUE" "$CYAN")
  if [ "$COLOR_DEPTH" -eq 0 ]; then
    printf '  %s\n' "$(repeat "$G_RULE" "$w")"
    return 0
  fi
  printf '  '
  for ((j = 0; j < 4; j++)); do
    s=""
    for ((i = 0; i < seg && j * seg + i < w; i++)); do s+="$G_RULE"; done
    printf '%s%s' "${cols[$j]}" "$s"
  done
  printf '%s\n' "$RESET"
}

banner() {
  printf '\n'
  printf '  %s\n' "$(rainbow 'K O M A R I   A G E N T')"
  printf '  %s%s%s\n' "$GRAY" "$(repeat "$G_RULE" 40)" "$RESET"
  printf '  %ska%s %s%sv%s  %s· 多实例部署 · NAT 友好%s\n' \
    "$B" "$RESET" "$GRAY" "$WHITE" "$KA_VERSION" "$GRAY" "$RESET"
  printf '\n'
}

step_header() { # 当前 总数 标题
  local cur="$1" total="$2" title="$3" dots="" i
  for ((i = 1; i <= total; i++)); do
    if [ "$i" -lt "$cur" ]; then
      dots+="${GREEN}${G_DOT}${RESET} "
    elif [ "$i" -eq "$cur" ]; then
      dots+="${YELL}${G_DOT_CUR}${RESET} "
    else
      dots+="${GRAY}${G_DOT_OFF}${RESET} "
    fi
  done
  printf '\n  %s %s%s/%s%s\n' "$dots" "$GRAY" "$cur" "$total" "$RESET"
  printf '  %s%s%s %s%s%s\n\n' "$PINK" "$G_BAR" "$RESET" "$B" "$title" "$RESET"
}

panel_row() { # 左竖线面板的一行
  local l="$1" v="$2"
  printf '  %s%s%s %s%s%s  %s%s%s\n' \
    "$PURP" "$G_BAR" "$RESET" "$GRAY" "$(padr "$l" 10)" "$RESET" "$WHITE" "$v" "$RESET"
}

tag_bool() {
  if [ "${1:-0}" -eq 1 ]; then
    printf '%s是%s' "$GREEN" "$RESET"
  else
    printf '%s否%s' "$GRAY" "$RESET"
  fi
}

opt_row() { # 编号 标签 已上色的值
  printf '   %s%s%s%s %s %s\n' "$CYAN" "$B" "$1" "$RESET" "$(padr "$2" 24)" "$3"
}

progress() { # 当前 总数
  local cur="$1" total="$2" width=24 filled i bar=""
  filled=$((cur * width / total))
  for ((i = 0; i < width; i++)); do
    if [ "$i" -lt "$filled" ]; then
      bar+="${GREEN}█${RESET}"
    else
      bar+="${GRAY}░${RESET}"
    fi
  done
  printf '\n  %s  %s%s / %s%s\n\n' "$bar" "$GRAY" "$cur" "$total" "$RESET"
}

# ==================================================================== 配置 ===
ENDPOINT=""
BASE_DIR="/opt/komari"
SVC_PREFIX="komari-agent"
INTERVAL="1.0"
INFO_INTERVAL="5"
DISABLE_WEBSSH=0
DISABLE_AUTOUPDATE=0
MEM_AVAILABLE=0
INSECURE=0
INCLUDE_NICS=""
EXCLUDE_NICS=""
INSTANCE_COUNT=1
MULTI=0
TOKENS=()
ARGS=()

load_conf() {
  [ -f "$KA_CONF" ] || return 0
  # shellcheck disable=SC1090
  . "$KA_CONF" 2>/dev/null || return 0
  ENDPOINT="${KA_ENDPOINT:-$ENDPOINT}"
  BASE_DIR="${KA_BASE_DIR:-$BASE_DIR}"
  SVC_PREFIX="${KA_SVC_PREFIX:-$SVC_PREFIX}"
  INTERVAL="${KA_INTERVAL:-$INTERVAL}"
  INFO_INTERVAL="${KA_INFO_INTERVAL:-$INFO_INTERVAL}"
  DISABLE_WEBSSH="${KA_WEBSSH:-$DISABLE_WEBSSH}"
  DISABLE_AUTOUPDATE="${KA_AUTOUPDATE:-$DISABLE_AUTOUPDATE}"
  MEM_AVAILABLE="${KA_MEMAVAIL:-$MEM_AVAILABLE}"
  INSECURE="${KA_INSECURE:-$INSECURE}"
  INCLUDE_NICS="${KA_INCLUDE_NICS:-$INCLUDE_NICS}"
  EXCLUDE_NICS="${KA_EXCLUDE_NICS:-$EXCLUDE_NICS}"
  INSTANCE_COUNT="${KA_INSTANCE_COUNT:-$INSTANCE_COUNT}"
}

save_conf() {
  [ "$(id -u)" -eq 0 ] || return 0
  mkdir -p "$(dirname "$KA_CONF")" 2>/dev/null || return 0
  (
    umask 077
    cat > "$KA_CONF" <<EOF
# ka 生成的配置（不含 token）
KA_ENDPOINT='$ENDPOINT'
KA_BASE_DIR='$BASE_DIR'
KA_SVC_PREFIX='$SVC_PREFIX'
KA_INTERVAL='$INTERVAL'
KA_INFO_INTERVAL='$INFO_INTERVAL'
KA_WEBSSH='$DISABLE_WEBSSH'
KA_AUTOUPDATE='$DISABLE_AUTOUPDATE'
KA_MEMAVAIL='$MEM_AVAILABLE'
KA_INSECURE='$INSECURE'
KA_INCLUDE_NICS='$INCLUDE_NICS'
KA_EXCLUDE_NICS='$EXCLUDE_NICS'
KA_INSTANCE_COUNT='$INSTANCE_COUNT'
EOF
  ) 2>/dev/null || true
}

# ================================================================ 输入封装 ===
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

ask() { # 提示 默认值 变量名
  local prompt="$1" def="$2" __out="$3" __in
  if [ -n "$def" ]; then
    printf '  %s%s%s %s %s[%s]%s: ' "$PINK" "$G_ARROW" "$RESET" "$prompt" "$GRAY" "$def" "$RESET"
  else
    printf '  %s%s%s %s: ' "$PINK" "$G_ARROW" "$RESET" "$prompt"
  fi
  if ! IFS= read -r __in; then
    printf '\n'
    die "读取输入失败（不是交互式终端？）"
  fi
  __in="$(trim "$__in")"
  [ -z "$__in" ] && __in="$def"
  printf -v "$__out" '%s' "$__in"
}

ask_int() { # 提示 默认值 变量名 最小 最大
  local prompt="$1" def="$2" __out="$3" lo="$4" hi="$5" v
  while :; do
    ask "$prompt" "$def" v
    case "$v" in
      ''|*[!0-9]*) warn "请输入整数"; continue ;;
    esac
    if [ "$v" -lt "$lo" ] || [ "$v" -gt "$hi" ]; then
      warn "取值范围 $lo - $hi"; continue
    fi
    printf -v "$__out" '%s' "$v"
    return 0
  done
}

ask_num() { # 允许小数
  local prompt="$1" def="$2" __out="$3" v
  while :; do
    ask "$prompt" "$def" v
    case "$v" in
      ''|*[!0-9.]*|*.*.*) warn "请输入数字，例如 1 或 0.5"; continue ;;
    esac
    printf -v "$__out" '%s' "$v"
    return 0
  done
}

mask() {
  local s="$1"
  if [ "${#s}" -le 10 ]; then
    printf '****'
  else
    printf '%s…%s' "${s:0:4}" "${s: -4}"
  fi
}

# ================================================================ 环境检查 ===
need_root()    { [ "$(id -u)" -eq 0 ] || die "需要 root 权限，请用 sudo ka"; }
need_systemd() { command -v systemctl >/dev/null 2>&1 || die "没有 systemctl，本脚本仅支持 systemd 发行版"; }
need_curl()    { command -v curl >/dev/null 2>&1 || die "没有 curl，请先安装"; }

list_units() {
  systemctl list-unit-files 'komari-agent*.service' --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}'
}

inst_dir() {
  if [ "$INSTANCE_COUNT" -eq 1 ]; then printf '%s' "$BASE_DIR"; else printf '%s/nat%s' "$BASE_DIR" "$1"; fi
}
inst_svc() {
  if [ "$INSTANCE_COUNT" -eq 1 ]; then printf '%s' "$SVC_PREFIX"; else printf '%s-%s' "$SVC_PREFIX" "$1"; fi
}

build_args() {
  ARGS=(-e "$ENDPOINT" -i "$INTERVAL" --info-report-interval "$INFO_INTERVAL")
  [ "$DISABLE_WEBSSH" -eq 1 ]     && ARGS+=(--disable-web-ssh)
  [ "$DISABLE_AUTOUPDATE" -eq 1 ] && ARGS+=(--disable-auto-update)
  [ "$MEM_AVAILABLE" -eq 1 ]      && ARGS+=(--memory-mode-available)
  [ "$INSECURE" -eq 1 ]           && ARGS+=(-u)
  [ -n "$INCLUDE_NICS" ]          && ARGS+=(--include-nics "$INCLUDE_NICS")
  [ -n "$EXCLUDE_NICS" ]          && ARGS+=(--exclude-nics "$EXCLUDE_NICS")
  return 0
}

# ==================================================================== 向导 ===
step_endpoint() {
  step_header 1 5 "面板地址"
  dim "填 Komari 面板地址，脚本会顺手探一下连通性"
  local v code
  while :; do
    ask "面板地址" "$ENDPOINT" v
    v="${v%/}"
    case "$v" in
      http://*|https://*) ENDPOINT="$v"; break ;;
      '') warn "面板地址不能为空" ;;
      *)  warn "必须以 http:// 或 https:// 开头" ;;
    esac
  done
  code="$(curl -o /dev/null -sS -k -w '%{http_code}' --max-time 8 "$ENDPOINT" 2>/dev/null || printf '000')"
  if [ "$code" = "000" ]; then
    warn "连不上 $ENDPOINT（网络 / 证书 / 地址有误），仍可继续尝试安装"
  else
    ok "面板可达（HTTP $code）"
  fi
}

step_mode() {
  step_header 2 5 "部署模式"
  printf '   %s%s1%s  %s单实例%s   本机只监控一个节点\n' "$CYAN" "$B" "$RESET" "$B" "$RESET"
  printf '   %s%s2%s  %s多实例%s   同一台 NAT 机器开多个节点，各自独立 token\n' "$CYAN" "$B" "$RESET" "$B" "$RESET"
  blank
  local m
  ask_int "选择" "1" m 1 2
  if [ "$m" -eq 2 ]; then MULTI=1; else MULTI=0; fi
}

step_tokens() {
  step_header 3 5 "节点 Token"
  dim "一个 token 对应面板里一个节点；多实例必须互不相同"
  blank
  if [ "$MULTI" -eq 1 ]; then
    ask_int "实例数量" "$INSTANCE_COUNT" INSTANCE_COUNT 1 20
  else
    INSTANCE_COUNT=1
  fi
  TOKENS=()
  local i t
  for ((i = 1; i <= INSTANCE_COUNT; i++)); do
    while :; do
      if [ "$INSTANCE_COUNT" -eq 1 ]; then
        ask "节点 token" "" t
      else
        ask "节点 $i 的 token" "" t
      fi
      [ -n "$t" ] && break
      warn "token 不能为空"
    done
    TOKENS+=("$t")
    ok "节点 $i 已录入 ${GRAY}$(mask "$t")${RESET}"
  done
}

step_advanced() {
  step_header 4 5 "高级参数"
  dim "输入编号修改，直接回车进入下一步"
  blank
  opt_row 1 "上报间隔"         "${YELL}${INTERVAL}${RESET} 秒"
  opt_row 2 "基础信息间隔"     "${YELL}${INFO_INTERVAL}${RESET} 分钟"
  opt_row 3 "禁用远程控制"     "$(tag_bool "$DISABLE_WEBSSH")"
  opt_row 4 "禁用自动更新"     "$(tag_bool "$DISABLE_AUTOUPDATE")"
  opt_row 5 "内存按可用计算"   "$(tag_bool "$MEM_AVAILABLE")"
  opt_row 6 "忽略不安全证书"   "$(tag_bool "$INSECURE")"
  opt_row 7 "网卡过滤"         "包含 ${WHITE}${INCLUDE_NICS:-不限}${RESET} / 排除 ${WHITE}${EXCLUDE_NICS:-无}${RESET}"
  opt_row 8 "安装根目录"       "${WHITE}${BASE_DIR}${RESET}"
  opt_row 9 "服务名前缀"       "${WHITE}${SVC_PREFIX}${RESET}"
  blank

  local ch
  while :; do
    ask "编号" "" ch
    case "$ch" in
      '') return 0 ;;
      1) ask_num "上报间隔（秒）" "$INTERVAL" INTERVAL
         ok "上报间隔 → ${INTERVAL} 秒" ;;
      2) ask_int "基础信息间隔（分钟）" "$INFO_INTERVAL" INFO_INTERVAL 1 60
         ok "基础信息间隔 → ${INFO_INTERVAL} 分钟" ;;
      3) [ "$DISABLE_WEBSSH" -eq 1 ] && DISABLE_WEBSSH=0 || DISABLE_WEBSSH=1
         ok "禁用远程控制 → $(tag_bool "$DISABLE_WEBSSH")" ;;
      4) [ "$DISABLE_AUTOUPDATE" -eq 1 ] && DISABLE_AUTOUPDATE=0 || DISABLE_AUTOUPDATE=1
         ok "禁用自动更新 → $(tag_bool "$DISABLE_AUTOUPDATE")" ;;
      5) [ "$MEM_AVAILABLE" -eq 1 ] && MEM_AVAILABLE=0 || MEM_AVAILABLE=1
         ok "内存按可用计算 → $(tag_bool "$MEM_AVAILABLE")" ;;
      6) [ "$INSECURE" -eq 1 ] && INSECURE=0 || INSECURE=1
         ok "忽略不安全证书 → $(tag_bool "$INSECURE")" ;;
      7) ask "包含网卡（逗号分隔，留空=全部）" "$INCLUDE_NICS" INCLUDE_NICS
         ask "排除网卡（逗号分隔，留空=不排除）" "$EXCLUDE_NICS" EXCLUDE_NICS
         ok "网卡过滤 → 包含[${INCLUDE_NICS:-不限}] 排除[${EXCLUDE_NICS:-无}]" ;;
      8) ask "安装根目录" "$BASE_DIR" BASE_DIR
         ok "安装根目录 → ${BASE_DIR}" ;;
      9) ask "服务名前缀" "$SVC_PREFIX" SVC_PREFIX
         ok "服务名前缀 → ${SVC_PREFIX}" ;;
      *) warn "没有 $ch 这个编号" ;;
    esac
  done
}

step_confirm() {
  build_args
  step_header 5 5 "确认部署"
  panel_row "面板地址" "$ENDPOINT"
  panel_row "实例数量" "${INSTANCE_COUNT} 个"
  panel_row "上报间隔" "${INTERVAL} 秒 / 信息 ${INFO_INTERVAL} 分钟"
  panel_row "远程控制" "$([ "$DISABLE_WEBSSH" -eq 1 ] && printf '已禁用' || printf '开启')"
  panel_row "自动更新" "$([ "$DISABLE_AUTOUPDATE" -eq 1 ] && printf '已禁用' || printf '开启')"
  panel_row "网卡"     "包含[${INCLUDE_NICS:-不限}] 排除[${EXCLUDE_NICS:-无}]"
  panel_row "根目录"   "$BASE_DIR"
  blank
  local i
  for ((i = 1; i <= INSTANCE_COUNT; i++)); do
    printf '  %s%s%s %s#%s%s %s%-14s%s %s→ %s%s\n' \
      "$PURP" "$G_BAR" "$RESET" "$GRAY" "$i" "$RESET" \
      "$GRAY" "$(mask "${TOKENS[$((i - 1))]}")" "$RESET" \
      "$GRAY" "$(inst_dir "$i")" "$RESET"
  done
  blank
  dim "参数: ${ARGS[*]}"
  blank
  local go
  ask "开始安装? (Y/n)" "Y" go
  case "$go" in
    [Nn]*) warn "已取消"; exit 0 ;;
  esac
}

do_install() {
  need_root; need_systemd; need_curl
  save_conf
  build_args
  local tmp i token dir svc fails=0
  tmp="$(mktemp /tmp/ka-install.XXXXXX)" || die "无法创建临时文件"
  info "下载安装脚本…"
  if ! curl -fsSL --max-time 120 "$KA_INSTALLER" -o "$tmp" || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "下载安装脚本失败，检查网络或换用 GitHub 代理"
  fi
  ok "安装脚本已就绪（$(wc -c < "$tmp" | tr -d ' ') 字节）"

  for ((i = 1; i <= INSTANCE_COUNT; i++)); do
    token="${TOKENS[$((i - 1))]}"
    dir="$(inst_dir "$i")"
    svc="$(inst_svc "$i")"
    progress "$i" "$INSTANCE_COUNT"
    printf '  %s%s%s %s%s%s  %stoken %s%s\n' \
      "$PINK" "$G_BAR" "$RESET" "$B" "$svc" "$RESET" "$GRAY" "$(mask "$token")" "$RESET"
    systemctl stop "$svc" >/dev/null 2>&1 || true
    if bash "$tmp" "${ARGS[@]}" \
         -t "$token" --install-dir "$dir" --install-service-name "$svc" </dev/null; then
      systemctl enable --now "$svc" >/dev/null 2>&1 || true
      ok "$svc 已安装并启动"
    else
      err "$svc 安装失败"
      fails=$((fails + 1))
    fi
    sleep 2
  done
  rm -f "$tmp"

  rule
  blank
  printf '  %s%s 部署结果 %s\n\n' "$B" "▍" "$RESET"
  for ((i = 1; i <= INSTANCE_COUNT; i++)); do
    svc="$(inst_svc "$i")"
    local act; act="$(systemctl is-active "$svc" 2>/dev/null)"
    if [ "$act" = "active" ]; then
      printf '  %s%s%s %-24s %s运行中%s\n' "$GREEN" "$G_DOT" "$RESET" "$svc" "$GREEN" "$RESET"
    else
      printf '  %s%s%s %-24s %s%s%s\n' "$RED" "$G_DOT_OFF" "$RESET" "$svc" "$RED" "$act" "$RESET"
    fi
  done
  blank
  if [ "$fails" -eq 0 ]; then
    ok "全部完成，面板里应能看到 ${INSTANCE_COUNT} 个在线节点"
  else
    warn "$fails 个实例失败，用 ka status / ka logs <n> 排查"
  fi
  dim "常用： ka status    ka logs 1    ka uninstall"
}

cmd_wizard() {
  [ -t 0 ] || die "向导需要交互式终端，请直接登录服务器后运行 ka"
  load_conf
  banner
  step_endpoint
  step_mode
  step_tokens
  step_advanced
  step_confirm
  do_install
}

# ================================================================== 子命令 ===
cmd_status() {
  need_systemd
  local units u n=0 act en col dot tag bar
  units="$(list_units)"
  if [ -z "$units" ]; then warn "没有发现 komari-agent 服务"; return 0; fi

  printf '\n  %s%s%s %s实例状态%s\n' "$PURP" "$G_BAR" "$RESET" "$B" "$RESET"
  rule 52
  for u in $units; do
    act="$(systemctl is-active "$u" 2>/dev/null)"
    en="$(systemctl is-enabled "$u" 2>/dev/null)"
    case "$act" in
      active)   col="$GREEN"; dot="$G_DOT";     tag="运行中" ;;
      failed)   col="$RED";   dot="$G_ERR";     tag="失败" ;;
      inactive) col="$GRAY";  dot="$G_DOT_OFF"; tag="已停止" ;;
      *)        col="$YELL";  dot="$G_DOT_OFF"; tag="$act" ;;
    esac
    printf '  %s%s%s %-24s %s%-9s%s %s%s%s\n' \
      "$col" "$dot" "$RESET" "${u%.service}" \
      "$col" "$(padr "$tag" 7)" "$RESET" \
      "$GRAY" "$en" "$RESET"
    n=$((n + 1))
  done
  rule 52
  local conns="未知"
  if command -v ss >/dev/null 2>&1; then
    conns="$(ss -tnp 2>/dev/null | grep -c 'komari-agent')"
  fi
  printf '  %s共 %s 个实例 · 面板连接 %s 条%s\n\n' "$GRAY" "$n" "$conns" "$RESET"
}

cmd_logs() {
  need_systemd
  load_conf
  local id="${1:-1}" lines="${2:-80}" u args=()
  case "$id" in
    ''|*[!0-9a-zA-Z]*) die "用法: ka logs <编号|all> [行数]" ;;
  esac
  if [ "$id" = "all" ]; then
    for u in $(list_units); do args+=(-u "$u"); done
    [ "${#args[@]}" -eq 0 ] && die "没有安装任何实例"
  elif systemctl list-unit-files "$SVC_PREFIX-$id.service" --no-legend 2>/dev/null | grep -q .; then
    args+=(-u "$SVC_PREFIX-$id")
  elif [ "$id" = "1" ] && systemctl list-unit-files "$SVC_PREFIX.service" --no-legend 2>/dev/null | grep -q .; then
    args+=(-u "$SVC_PREFIX")
  else
    die "找不到实例 $id（先用 ka status 看看）"
  fi
  journalctl "${args[@]}" -n "$lines" --no-pager 2>/dev/null || die "读取日志失败"
}

cmd_uninstall() {
  need_root; need_systemd
  load_conf
  local units=() u i=1 choice svc exe dir ok_dir
  while IFS= read -r u; do [ -n "$u" ] && units+=("$u"); done <<< "$(list_units)"
  if [ "${#units[@]}" -eq 0 ]; then warn "没有可卸载的实例"; return 0; fi

  printf '\n  %s%s%s %s已安装实例%s\n' "$PURP" "$G_BAR" "$RESET" "$B" "$RESET"
  rule 52
  for u in "${units[@]}"; do
    printf '   %s%s%s%s %s\n' "$CYAN" "$B" "$i" "$RESET" "${u%.service}"
    i=$((i + 1))
  done
  rule 52
  ask "卸载哪个？（编号 / all）" "all" choice

  local targets=()
  if [ "$choice" = "all" ]; then
    targets=("${units[@]}")
  else
    case "$choice" in
      ''|*[!0-9]*) die "无效编号" ;;
    esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "${#units[@]}" ] || die "编号超出范围"
    targets=("${units[$((choice - 1))]}")
  fi

  blank
  for svc in "${targets[@]}"; do
    warn "将删除 ${svc%.service}"
  done
  local go
  ask "确认卸载以上 ${#targets[@]} 个实例? (y/N)" "N" go
  case "$go" in
    [Yy]*) ;;
    *) warn "已取消"; return 0 ;;
  esac

  for svc in "${targets[@]}"; do
    exe="$(systemctl cat "$svc" 2>/dev/null | sed -n 's/^ExecStart=//p' | head -n1 | awk '{print $1}')"
    exe="${exe#-}"; exe="${exe%\"}"; exe="${exe#\"}"
    dir="$(dirname "${exe:-/nonexistent}")"
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${svc%.service}.service"
    systemctl daemon-reload
    ok_dir=0
    case "$dir" in
      /opt/komari*|/opt/ka*) ok_dir=1 ;;
    esac
    if [ "$ok_dir" -eq 0 ] && [ -n "${BASE_DIR:-}" ] && [ "$BASE_DIR" != "/" ]; then
      case "$dir" in
        "$BASE_DIR"|"${BASE_DIR%/}"/*) ok_dir=1 ;;
      esac
    fi
    if [ "$ok_dir" -eq 1 ]; then
      rm -rf "$dir"
      ok "${svc%.service} 已卸载，目录 $dir 已删除"
    else
      warn "${svc%.service} 已卸载；目录 $dir 不在白名单，保留未删"
    fi
  done
}

ka_find_latest() {
  local files latest
  files="$(ls -1 "$KA_DIR"/ka-v[0-9]*.sh 2>/dev/null || true)"
  [ -z "$files" ] && return 0
  latest="$(printf '%s\n' "$files" | sort -V 2>/dev/null | tail -n 1)"
  [ -z "$latest" ] && latest="$(printf '%s\n' "$files" | sort | tail -n 1)"
  printf '%s' "$latest" | sed 's#.*/ka-v##; s#\.sh$##'
}

ka_next_version() {
  local v="${1:-$KA_VERSION}" a b c
  IFS=. read -r a b c <<< "$v"
  a="${a:-0}"; b="${b:-0}"; c="${c:-1}"
  if [ "$KA_BUMP_STYLE" = "patch" ]; then
    c=$((c + 1))
  else
    b=$((b + 1))
  fi
  printf '%s.%s.%s' "$a" "$b" "$c"
}

cmd_bump() {
  local src="$KA_DIR/ka.sh" latest next dst
  [ -f "$src" ] || src="$KA_SELF"
  latest="$(ka_find_latest)"
  next="$(ka_next_version "${latest:-$KA_VERSION}")"
  dst="$KA_DIR/ka-v$next.sh"
  [ -e "$dst" ] && die "已存在 $(basename "$dst")，未做任何修改"

  local expr1 expr2
  expr1="s/^KA_VERSION=.*/KA_VERSION=\"$next\"/"
  expr2="s/^#  版本: [0-9.]+/#  版本: $next/"
  sed -E -e "$expr1" -e "$expr2" "$src" > "$dst" || die "写入失败"
  chmod +x "$dst" 2>/dev/null || true
  if [ "$(readlink -f "$src")" != "$(readlink -f "$dst")" ]; then
    sed -i -E -e "$expr1" -e "$expr2" "$src" 2>/dev/null || true
  fi
  ok "已发布 ka-v$next.sh（旧版本全部保留）"
  blank
  for dst in "$KA_DIR"/ka-v*.sh; do
    [ -e "$dst" ] || continue
    printf '   %s%s%s %s\n' "$GRAY" "$G_ARROW" "$RESET" "$(basename "$dst")"
  done
  blank
  dim "直接运行 ka 即可使用新版本"
}

cmd_self_install() {
  need_root
  local target="${1:-/opt/ka}"
  if [ "$(readlink -f "$KA_DIR")" = "$(readlink -f "$target")" ] && [ -d "$target" ]; then
    ln -sf "$target/ka" /usr/local/bin/ka
    ok "已在 $target，已重建软链 /usr/local/bin/ka"
    return 0
  fi
  mkdir -p "$target"
  cp -f "$KA_DIR"/ka.sh "$target"/ 2>/dev/null || true
  cp -f "$KA_DIR"/ka-v*.sh "$target"/ 2>/dev/null || true
  cp -f "$KA_DIR"/ka "$target"/ 2>/dev/null || true
  chmod +x "$target"/ka "$target"/ka.sh "$target"/ka-v*.sh 2>/dev/null || true
  ln -sf "$target/ka" /usr/local/bin/ka
  ok "已安装到 $target"
  dim "软链 /usr/local/bin/ka -> $target/ka"
  dim "直接运行： ka"
}

cmd_version() {
  banner
  panel_row "版本"     "v$KA_VERSION"
  panel_row "运行文件" "$KA_SELF"
  panel_row "发布目录" "$KA_DIR"
  panel_row "配置文件" "$KA_CONF"
  panel_row "版本规则" "$KA_BUMP_STYLE（minor: +0.1）"
  blank
  printf '  %s%s%s %s归档版本%s\n' "$PURP" "$G_BAR" "$RESET" "$B" "$RESET"
  rule 52
  local f found=0
  for f in "$KA_DIR"/ka-v*.sh; do
    [ -e "$f" ] || continue
    printf '   %s%s%s %s\n' "$GRAY" "$G_ARROW" "$RESET" "$(basename "$f")"
    found=1
  done
  [ "$found" -eq 0 ] && dim "（无）"
  blank
}

cmd_help() {
  banner
  cat <<EOF
  ${B}安装${RESET}
    ka                    交互式向导（输入面板地址 / token / 参数）

  ${B}管理${RESET}
    ka status             实例状态面板
    ka logs <n|all> [行]  查看日志，默认 80 行
    ka uninstall          卸载实例（单个或全部）

  ${B}版本${RESET}
    ka version            版本与归档信息
    ka bump               发布新版本，旧文件保留
    ka self-install       安装到 /opt/ka 并建立全局 ka 命令

  ${B}环境变量${RESET}
    KA_CONF               配置文件路径，默认 /etc/ka.conf
    KA_UI=plain           关闭彩色（也可用 NO_COLOR=1）

EOF
}

# ==================================================================== 入口 ===
main() {
  local cmd="${1:-wizard}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    wizard|install|'')   cmd_wizard ;;
    status)              cmd_status ;;
    logs)                cmd_logs "$@" ;;
    uninstall|remove)    cmd_uninstall ;;
    version|-v|--version) cmd_version ;;
    bump)                cmd_bump ;;
    self-install)        cmd_self_install "$@" ;;
    help|-h|--help)      cmd_help ;;
    *) err "未知命令: $cmd"; cmd_help; exit 1 ;;
  esac
}

main "$@"
