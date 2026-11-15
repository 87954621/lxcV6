#!/usr/bin/env bash
# =============================================================================
#  ka  ·  Komari Agent 部署器
#  版本: 0.2.1        归档文件: ka-v<版本>.sh
#
#  用法:
#    ka                     主菜单（↑↓ 选择，回车确认）
#    ka install             直接进安装向导
#    ka status              实例状态
#    ka logs <n|unit|all>   查看日志
#    ka uninstall           卸载实例
#    ka version             版本与归档信息
#    ka bump                发布新版本（+0.1，旧版本文件保留）
#    ka self-install        安装到 /opt/ka 并建立 ka 命令
#
#  安装流程: 面板地址 → 粘贴 token（一行一个，空行结束）→ 参数 → 确认
#            节点数量 = token 数量，不再单独问“几个实例”
#  已有实例: 自动扫描 systemd 里所有跑 komari-agent 的服务，纳入状态/日志/卸载管理
#  界面: 256 色 / 16 色自动适配；非交互终端退回编号菜单
#        KA_TUI=0 或 KA_UI=plain 强制纯文本
# =============================================================================

set -u

KA_VERSION="0.2.1"
KA_BUMP_STYLE="minor"
KA_INSTALLER="https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh"
KA_CONF="${KA_CONF:-/etc/ka.conf}"

KA_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
KA_DIR="$(dirname "$KA_SELF")"

# ================================================================ 主题引擎 ===
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

repeat() {
  local ch="$1" n="$2" i out=""
  for ((i = 0; i < n; i++)); do out+="$ch"; done
  printf '%s' "$out"
}

rainbow() {
  local s="$1" i out=""
  if [ "$COLOR_DEPTH" -eq 0 ]; then printf '%s' "$s"; return 0; fi
  local -a pal=("$PINK" "$PURP" "$BLUE" "$CYAN" "$GREEN" "$YELL")
  for ((i = 0; i < ${#s}; i++)); do
    out+="${pal[$((i % 6))]}${s:i:1}"
  done
  printf '%s%s' "$out" "$RESET"
}

rule() {
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

step_header() {
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

panel_row() {
  local l="$1" v="$2"
  printf '  %s%s%s %s%s%s  %s%s%s\n' \
    "$PURP" "$G_BAR" "$RESET" "$GRAY" "$(padr "$l" 10)" "$RESET" "$WHITE" "$v" "$RESET"
}

toggle_render() {
  if [ "${1:-0}" -eq 1 ]; then
    printf '%s[✔]%s 已开启' "$GREEN" "$RESET"
  else
    printf '%s[ ]%s 已关闭' "$GRAY" "$RESET"
  fi
}

progress() {
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

# ================================================================ 交互引擎 ===
UI_TUI=0
PICK_RESULT=0
KEY=""

tui_init() {
  UI_TUI=0
  [ "${KA_TUI:-1}" = "0" ] && return 0
  [ -t 0 ] || return 0
  [ -t 1 ] || return 0
  [ "$COLOR_DEPTH" -gt 0 ] || return 0
  case "${TERM:-dumb}" in dumb) return 0 ;; esac
  UI_TUI=1
}

tui_restore() {
  if [ "${UI_TUI:-0}" -eq 1 ]; then printf '%s' $'\033[?25h'; fi
}
trap 'tui_restore' EXIT
trap 'tui_restore; exit 130' INT TERM

screen_home() { printf '\033[H\033[J'; }
hide_cursor() { if [ "$UI_TUI" -eq 1 ]; then printf '%s' $'\033[?25l'; fi; return 0; }
show_cursor() { if [ "$UI_TUI" -eq 1 ]; then printf '%s' $'\033[?25h'; fi; return 0; }

read_key() {
  KEY=""
  local c c2 c3
  if ! IFS= read -rsn1 c; then KEY="EOF"; return 1; fi
  case "$c" in
    $'\x1b')
      if ! IFS= read -rsn1 -t 0.05 c2; then KEY="ESC"; return 0; fi
      case "$c2" in
        '['|'O')
          if ! IFS= read -rsn1 -t 0.05 c3; then KEY="ESC"; return 0; fi
          case "$c3" in
            A) KEY="UP" ;;
            B) KEY="DOWN" ;;
            C) KEY="RIGHT" ;;
            D) KEY="LEFT" ;;
            *) KEY="ESC" ;;
          esac ;;
        *) KEY="ESC" ;;
      esac ;;
    '') KEY="ENTER" ;;
    $'\n'|$'\r') KEY="ENTER" ;;
    ' ') KEY="SPACE" ;;
    q|Q) KEY="QUIT" ;;
    j) KEY="DOWN" ;;
    k) KEY="UP" ;;
    *) KEY="$c" ;;
  esac
}

draw_header() {
  local title="$1" sub="${2:-}"
  printf '  %s\n' "$(rainbow 'K O M A R I   A G E N T')"
  printf '  %s%s%s\n' "$GRAY" "$(repeat "$G_RULE" 40)" "$RESET"
  printf '  %s%s%s  %s%s%s\n' "$PINK" "$G_BAR" "$RESET" "$B" "$title" "$RESET"
  if [ -n "$sub" ]; then printf '\n  %s%s%s\n' "$GRAY" "$sub" "$RESET"; fi
  printf '\n'
}

pick() { # 标题 副标题 选项... → PICK_RESULT
  local title="$1" sub="$2"
  shift 2
  local -a items=("$@")
  local n="${#items[@]}" sel=0 i v
  if [ "$n" -eq 0 ]; then return 1; fi

  if [ "$UI_TUI" -eq 0 ]; then
    printf '\n  %s%s%s  %s\n\n' "$PINK" "$G_BAR" "$RESET" "$title"
    if [ -n "$sub" ]; then printf '  %s%s%s\n\n' "$GRAY" "$sub" "$RESET"; fi
    for ((i = 0; i < n; i++)); do
      printf '   %s%s%d%s  %s\n' "$CYAN" "$B" "$((i + 1))" "$RESET" "${items[$i]}"
    done
    printf '\n'
    ask_int "选择" "1" v 1 "$n"
    PICK_RESULT=$((v - 1))
    return 0
  fi

  hide_cursor
  while :; do
    screen_home
    draw_header "$title" "$sub"
    for ((i = 0; i < n; i++)); do
      if [ "$i" -eq "$sel" ]; then
        printf '   %s❯%s %s%s%s\n' "$PINK" "$RESET" "$B" "${items[$i]}" "$RESET"
      else
        printf '     %s\n' "${items[$i]}"
      fi
    done
    printf '\n   %s↑↓ 移动 · Enter 选择 · q 退出%s\n' "$GRAY" "$RESET"
    if ! read_key; then show_cursor; return 1; fi
    case "$KEY" in
      UP)   sel=$(((sel + n - 1) % n)) ;;
      DOWN) sel=$(((sel + 1) % n)) ;;
      ENTER|SPACE) break ;;
      QUIT|ESC) show_cursor; return 2 ;;
      [0-9])
        v=$((KEY - 1))
        if [ "$v" -ge 0 ] && [ "$v" -lt "$n" ]; then sel="$v"; fi ;;
    esac
  done
  show_cursor
  PICK_RESULT=$sel
  return 0
}

pause_any() {
  [ "$UI_TUI" -eq 1 ] || return 0
  printf '\n   %s按任意键返回…%s' "$GRAY" "$RESET"
  read_key >/dev/null 2>&1 || true
  printf '\n'
}

cfg_row() {
  local idx="$1" sel="$2" label="$3" value="$4"
  if [ "$idx" -eq "$sel" ]; then
    printf '   %s❯%s %s%s%s  %s\n' "$PINK" "$RESET" "$B" "$(padr "$label" 16)" "$RESET" "$value"
  else
    printf '     %s  %s\n' "$(padr "$label" 16)" "$value"
  fi
}

edit_num() {
  local label="$1" var="$2"
  show_cursor
  screen_home
  draw_header "高级参数" "修改后回车确认"
  ask_num "$label" "${!var}" "$var"
  hide_cursor
}

edit_int() {
  local label="$1" var="$2" lo="$3" hi="$4"
  show_cursor
  screen_home
  draw_header "高级参数" "修改后回车确认"
  ask_int "$label" "${!var}" "$var" "$lo" "$hi"
  hide_cursor
}

edit_str() {
  local label="$1" var="$2"
  show_cursor
  screen_home
  draw_header "高级参数" "修改后回车确认（留空 = 清空）"
  ask "$label" "${!var}" "$var"
  hide_cursor
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
CANCELED=0
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

ask() {
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

ask_int() {
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

ask_num() {
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

unit_exists() {
  systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q .
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

# ============================================================ 已有实例扫描 ===
D_COUNT=0
D_UNIT=(); D_EXE=(); D_DIR=(); D_EP=(); D_TK=(); D_TAG=()

discover_instances() {
  D_COUNT=0
  D_UNIT=(); D_EXE=(); D_DIR=(); D_EP=(); D_TK=(); D_TAG=()
  command -v systemctl >/dev/null 2>&1 || return 0

  local -a units=()
  local f u line unit exe dir ep tk tag hit

  # 1) 文件名里带 komari-agent 的 unit（一次 grep，避免逐个文件扫）
  while IFS= read -r hit; do
    [ -n "$hit" ] && units+=("$(basename "$hit")")
  done <<< "$(grep -lis 'komari-agent' \
      /etc/systemd/system/*.service \
      /usr/lib/systemd/system/*.service \
      /lib/systemd/system/*.service 2>/dev/null)"
  # 2) 名字匹配但文件没写全路径的兜底
  while IFS= read -r u; do
    [ -n "$u" ] && units+=("$u")
  done <<< "$(systemctl list-unit-files 'komari-agent*.service' --no-legend --no-pager 2>/dev/null | awk '{print $1}')"

  [ "${#units[@]}" -eq 0 ] && return 0

  local sorted
  sorted="$(printf '%s\n' "${units[@]}" | sort -u)"

  local -a w=()
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    line="$(systemctl cat "$unit" 2>/dev/null | sed -n 's/^ExecStart=//p' | head -n1)"
    [ -n "$line" ] || continue
    w=($line)
    exe="${w[0]#-}"; exe="${exe%\"}"; exe="${exe#\"}"
    case "$exe" in *komari-agent*) ;; *) continue ;; esac
    ep=""; tk=""
    local i
    for ((i = 1; i < ${#w[@]}; i++)); do
      case "${w[$i]}" in
        -e|--endpoint) ep="${w[$((i + 1))]:-}" ;;
        -t|--token)    tk="${w[$((i + 1))]:-}" ;;
      esac
    done
    dir="$(dirname "$exe")"
    tag="外部"
    case "$unit" in
      "$SVC_PREFIX.service"|"$SVC_PREFIX"-*.service) tag="受管" ;;
    esac
    D_UNIT+=("$unit"); D_EXE+=("$exe"); D_DIR+=("$dir")
    D_EP+=("$ep"); D_TK+=("$tk"); D_TAG+=("$tag")
    D_COUNT=$((D_COUNT + 1))
  done <<< "$sorted"
}

remove_unit() { # remove_unit unit [force]
  local svc="$1" force="${2:-0}" go exe dir ok_dir
  exe="$(systemctl cat "$svc" 2>/dev/null | sed -n 's/^ExecStart=//p' | head -n1 | awk '{print $1}')"
  exe="${exe#-}"; exe="${exe%\"}"; exe="${exe#\"}"
  dir="$(dirname "${exe:-/nonexistent}")"
  if [ "$force" -eq 0 ]; then
    warn "将停止并删除 ${svc%.service}，目录 $dir"
    ask "确认? (y/N)" "N" go
    case "$go" in
      [Yy]*) ;;
      *) warn "已跳过"; return 0 ;;
    esac
  fi
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
}

# ==================================================================== 向导 ===
step_endpoint() {
  step_header 1 4 "面板地址"
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

token_exists() {
  if [ "${#TOKENS[@]}" -eq 0 ]; then return 1; fi
  local x
  for x in "${TOKENS[@]}"; do
    if [ "$x" = "$1" ]; then return 0; fi
  done
  return 1
}

step_tokens() {
  step_header 2 4 "节点 Token"
  dim "从面板「添加节点」复制 token，一行一个；直接回车结束"
  dim "支持一次粘贴多行，会自动拆分；节点数量 = token 数量"
  blank
  TOKENS=()
  local t prompt
  while :; do
    if [ "${#TOKENS[@]}" -eq 0 ]; then
      prompt="节点 1 的 token"
    else
      prompt="节点 $(( ${#TOKENS[@]} + 1 )) 的 token（回车结束）"
    fi
    ask "$prompt" "" t
    [ -z "$t" ] && break
    if token_exists "$t"; then
      warn "这个 token 已经填过了，跳过"
      continue
    fi
    TOKENS+=("$t")
    ok "已添加 #${#TOKENS[@]}  ${GRAY}$(mask "$t")${RESET}"
  done

  if [ "${#TOKENS[@]}" -eq 0 ]; then
    warn "至少要填一个 token"
    return 1
  fi
  INSTANCE_COUNT="${#TOKENS[@]}"
  MULTI=0
  if [ "$INSTANCE_COUNT" -gt 1 ]; then MULTI=1; fi

  blank
  if [ "$MULTI" -eq 1 ]; then
    ok "共 ${INSTANCE_COUNT} 个节点 → ${SVC_PREFIX}-1 … ${SVC_PREFIX}-${INSTANCE_COUNT}"
  else
    ok "共 1 个节点 → 单实例 ${SVC_PREFIX}"
  fi
}

step_advanced() {
  step_header 3 4 "高级参数"
  if [ "$UI_TUI" -eq 0 ]; then
    step_advanced_plain
    return 0
  fi
  local sel=0 n=11
  hide_cursor
  while :; do
    screen_home
    draw_header "高级参数" "↑↓ 移动 · Enter 修改 · Esc 完成"
    cfg_row 0 "$sel" "上报间隔"       "${YELL}${INTERVAL}${RESET} 秒"
    cfg_row 1 "$sel" "基础信息间隔"   "${YELL}${INFO_INTERVAL}${RESET} 分钟"
    cfg_row 2 "$sel" "禁用远程控制"   "$(toggle_render "$DISABLE_WEBSSH")"
    cfg_row 3 "$sel" "禁用自动更新"   "$(toggle_render "$DISABLE_AUTOUPDATE")"
    cfg_row 4 "$sel" "内存按可用计算" "$(toggle_render "$MEM_AVAILABLE")"
    cfg_row 5 "$sel" "忽略不安全证书" "$(toggle_render "$INSECURE")"
    cfg_row 6 "$sel" "包含网卡"       "${WHITE}${INCLUDE_NICS:-全部}${RESET}"
    cfg_row 7 "$sel" "排除网卡"       "${WHITE}${EXCLUDE_NICS:-无}${RESET}"
    cfg_row 8 "$sel" "安装根目录"     "${WHITE}${BASE_DIR}${RESET}"
    cfg_row 9 "$sel" "服务名前缀"     "${WHITE}${SVC_PREFIX}${RESET}"
    cfg_row 10 "$sel" "完成并继续"    "${GREEN}→${RESET}"
    printf '\n   %s↑↓ 移动 · Enter 修改 · Esc 完成%s\n' "$GRAY" "$RESET"
    if ! read_key; then break; fi
    case "$KEY" in
      UP)   sel=$(((sel + n - 1) % n)) ;;
      DOWN) sel=$(((sel + 1) % n)) ;;
      ESC|QUIT) break ;;
      ENTER|SPACE)
        case "$sel" in
          0) edit_num "上报间隔（秒）" INTERVAL ;;
          1) edit_int "基础信息间隔（分钟）" INFO_INTERVAL 1 60 ;;
          2) [ "$DISABLE_WEBSSH" -eq 1 ] && DISABLE_WEBSSH=0 || DISABLE_WEBSSH=1 ;;
          3) [ "$DISABLE_AUTOUPDATE" -eq 1 ] && DISABLE_AUTOUPDATE=0 || DISABLE_AUTOUPDATE=1 ;;
          4) [ "$MEM_AVAILABLE" -eq 1 ] && MEM_AVAILABLE=0 || MEM_AVAILABLE=1 ;;
          5) [ "$INSECURE" -eq 1 ] && INSECURE=0 || INSECURE=1 ;;
          6) edit_str "包含网卡（逗号分隔，空=全部）" INCLUDE_NICS ;;
          7) edit_str "排除网卡（逗号分隔，空=不排除）" EXCLUDE_NICS ;;
          8) edit_str "安装根目录" BASE_DIR ;;
          9) edit_str "服务名前缀" SVC_PREFIX ;;
          10) break ;;
        esac ;;
    esac
  done
  show_cursor
  blank
}

step_advanced_plain() {
  local ch
  dim "输入编号修改，直接回车进入下一步"
  blank
  printf '   %s1%s  上报间隔        %s 秒\n' "$CYAN" "$RESET" "$INTERVAL"
  printf '   %s2%s  基础信息间隔    %s 分钟\n' "$CYAN" "$RESET" "$INFO_INTERVAL"
  printf '   %s3%s  禁用远程控制    %s\n' "$CYAN" "$RESET" "$(toggle_render "$DISABLE_WEBSSH")"
  printf '   %s4%s  禁用自动更新    %s\n' "$CYAN" "$RESET" "$(toggle_render "$DISABLE_AUTOUPDATE")"
  printf '   %s5%s  内存按可用计算  %s\n' "$CYAN" "$RESET" "$(toggle_render "$MEM_AVAILABLE")"
  printf '   %s6%s  忽略不安全证书  %s\n' "$CYAN" "$RESET" "$(toggle_render "$INSECURE")"
  printf '   %s7%s  包含网卡        %s\n' "$CYAN" "$RESET" "${INCLUDE_NICS:-全部}"
  printf '   %s8%s  排除网卡        %s\n' "$CYAN" "$RESET" "${EXCLUDE_NICS:-无}"
  printf '   %s9%s  安装根目录      %s\n' "$CYAN" "$RESET" "$BASE_DIR"
  printf '   %s10%s 服务名前缀      %s\n' "$CYAN" "$RESET" "$SVC_PREFIX"
  blank
  while :; do
    ask "编号（回车继续）" "" ch
    case "$ch" in
      '') return 0 ;;
      1) ask_num "上报间隔（秒）" "$INTERVAL" INTERVAL ;;
      2) ask_int "基础信息间隔（分钟）" "$INFO_INTERVAL" INFO_INTERVAL 1 60 ;;
      3) [ "$DISABLE_WEBSSH" -eq 1 ] && DISABLE_WEBSSH=0 || DISABLE_WEBSSH=1 ;;
      4) [ "$DISABLE_AUTOUPDATE" -eq 1 ] && DISABLE_AUTOUPDATE=0 || DISABLE_AUTOUPDATE=1 ;;
      5) [ "$MEM_AVAILABLE" -eq 1 ] && MEM_AVAILABLE=0 || MEM_AVAILABLE=1 ;;
      6) [ "$INSECURE" -eq 1 ] && INSECURE=0 || INSECURE=1 ;;
      7) ask "包含网卡（逗号分隔，空=全部）" "$INCLUDE_NICS" INCLUDE_NICS ;;
      8) ask "排除网卡（逗号分隔，空=不排除）" "$EXCLUDE_NICS" EXCLUDE_NICS ;;
      9) ask "安装根目录" "$BASE_DIR" BASE_DIR ;;
      10) ask "服务名前缀" "$SVC_PREFIX" SVC_PREFIX ;;
      *) warn "没有 $ch 这个编号" ;;
    esac
    ok "已更新"
  done
}

step_confirm() {
  build_args
  step_header 4 4 "确认部署"

  local clash="" i svc
  for ((i = 1; i <= INSTANCE_COUNT; i++)); do
    svc="$(inst_svc "$i")"
    if unit_exists "$svc.service"; then clash+=" $svc"; fi
  done

  panel_row "面板地址" "$ENDPOINT"
  if [ "$MULTI" -eq 1 ]; then
    panel_row "实例数量" "${INSTANCE_COUNT} 个（多实例）"
  else
    panel_row "实例数量" "1 个（单实例）"
  fi
  panel_row "上报间隔" "${INTERVAL} 秒 / 信息 ${INFO_INTERVAL} 分钟"
  panel_row "远程控制" "$([ "$DISABLE_WEBSSH" -eq 1 ] && printf '已禁用' || printf '开启')"
  panel_row "自动更新" "$([ "$DISABLE_AUTOUPDATE" -eq 1 ] && printf '已禁用' || printf '开启')"
  panel_row "根目录"   "$BASE_DIR"
  blank
  for ((i = 1; i <= INSTANCE_COUNT; i++)); do
    printf '  %s%s%s %s#%s%s %s%-14s%s %s→ %s%s\n' \
      "$PURP" "$G_BAR" "$RESET" "$GRAY" "$i" "$RESET" \
      "$GRAY" "$(mask "${TOKENS[$((i - 1))]}")" "$RESET" \
      "$GRAY" "$(inst_dir "$i")" "$RESET"
  done
  blank
  dim "参数: ${ARGS[*]}"
  blank

  local go="Y"
  if [ -n "$clash" ]; then
    warn "以下服务已存在，安装会覆盖其配置：$clash"
    go="N"
  fi
  ask "开始安装? (Y/n)" "$go" go
  case "$go" in
    [Nn]*) warn "已取消"; CANCELED=1; return 0 ;;
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
    warn "$fails 个实例失败，去「实例管理 → 查看日志」排查"
  fi
}

cmd_wizard() {
  [ -t 0 ] || die "向导需要交互式终端，请直接登录服务器后运行 ka"
  tui_init
  load_conf
  CANCELED=0
  discover_instances

  if [ "$UI_TUI" -eq 1 ]; then screen_home; fi
  banner

  if [ "$D_COUNT" -gt 0 ]; then
    panel_row "已有实例" "${D_COUNT} 个"
    local j
    for ((j = 0; j < D_COUNT; j++)); do
      printf '  %s%s%s %s%-22s%s %s%s%s\n' \
        "$PURP" "$G_BAR" "$RESET" "$GRAY" "${D_UNIT[$j]%.service}" "$RESET" \
        "$GRAY" "${D_DIR[$j]}" "$RESET"
    done
    blank
    warn "新增实例不会改动它们；但若服务名相同会被覆盖"
    local go
    ask "继续新增实例? (y/N)" "N" go
    case "$go" in
      [Yy]*) ;;
      *) warn "已取消"; return 0 ;;
    esac
  fi

  step_endpoint
  step_tokens || return 0
  step_advanced
  step_confirm
  if [ "${CANCELED:-0}" -eq 1 ]; then return 0; fi
  do_install
}

# ================================================================== 子命令 ===
cmd_status() {
  need_systemd
  load_conf
  discover_instances

  if [ "$D_COUNT" -eq 0 ]; then
    warn "没有发现已安装的 komari-agent"
    return 0
  fi

  printf '\n  %s%s%s %s实例状态%s %s(%s 个)%s\n' \
    "$PURP" "$G_BAR" "$RESET" "$B" "$RESET" "$GRAY" "$D_COUNT" "$RESET"
  rule 64
  local i act en col dot tag
  for ((i = 0; i < D_COUNT; i++)); do
    act="$(systemctl is-active "${D_UNIT[$i]}" 2>/dev/null)"
    en="$(systemctl is-enabled "${D_UNIT[$i]}" 2>/dev/null)"
    case "$act" in
      active)   col="$GREEN"; dot="$G_DOT";     tag="运行中" ;;
      failed)   col="$RED";   dot="$G_ERR";     tag="失败" ;;
      inactive) col="$GRAY";  dot="$G_DOT_OFF"; tag="已停止" ;;
      *)        col="$YELL";  dot="$G_DOT_OFF"; tag="$act" ;;
    esac
    printf '  %s%s%s %s%-22s%s %s%s%s %s%-7s%s %s%s%s\n' \
      "$col" "$dot" "$RESET" \
      "$GRAY" "${D_UNIT[$i]%.service}" "$RESET" \
      "$CYAN" "${D_TAG[$i]}" "$RESET" \
      "$col" "$(padr "$tag" 7)" "$RESET" \
      "$GRAY" "${D_EP[$i]:-—}" "$RESET"
  done
  rule 64
  local conns="未知"
  if command -v ss >/dev/null 2>&1; then
    conns="$(ss -tnp 2>/dev/null | grep -c 'komari-agent')"
  fi
  printf '  %s共 %s 个 · 面板连接 %s 条 · 受管 %s 个%s\n\n' \
    "$GRAY" "$D_COUNT" "$conns" "$(count_managed)" "$RESET"
}

count_managed() {
  local i n=0
  for ((i = 0; i < D_COUNT; i++)); do
    if [ "${D_TAG[$i]}" = "受管" ]; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

cmd_instances() {
  load_conf
  discover_instances
  if [ "$D_COUNT" -eq 0 ]; then
    warn "没有发现已安装的 komari-agent"
    return 0
  fi
  local -a items=()
  local i st
  for ((i = 0; i < D_COUNT; i++)); do
    st="$(systemctl is-active "${D_UNIT[$i]}" 2>/dev/null)"
    items+=("$(padr "${D_UNIT[$i]%.service}" 22)  ${D_TAG[$i]}  ${st}")
  done
  pick "实例管理" "共 ${D_COUNT} 个 · 选择后查看详情" "${items[@]}" || return 0
  cmd_instance_actions "$PICK_RESULT"
}

cmd_instance_actions() {
  local idx="$1"
  local unit="${D_UNIT[$idx]}"
  local name="${unit%.service}"
  local st
  while :; do
    st="$(systemctl is-active "$unit" 2>/dev/null)"
    local -a items=("查看日志" "重启" "停止" "启动" "卸载")
    pick "$name" "状态 $st · ${D_DIR[$idx]} · ${D_EP[$idx]:-—}" "${items[@]}" || return 0
    case "$PICK_RESULT" in
      0)
        printf '\n'
        journalctl -u "$unit" -n 100 --no-pager 2>/dev/null || warn "读取日志失败"
        pause_any ;;
      1) systemctl restart "$unit" >/dev/null 2>&1 && ok "已重启 $name" || warn "重启失败"
         pause_any ;;
      2) systemctl stop "$unit" >/dev/null 2>&1 && ok "已停止 $name" || warn "停止失败"
         pause_any ;;
      3) systemctl start "$unit" >/dev/null 2>&1 && ok "已启动 $name" || warn "启动失败"
         pause_any ;;
      4) remove_unit "$unit"; return 0 ;;
    esac
  done
}

cmd_logs() {
  need_systemd
  load_conf
  local id="${1:-1}" lines="${2:-80}" args=() u
  case "$id" in
    all)
      discover_instances
      [ "$D_COUNT" -eq 0 ] && die "没有安装任何实例"
      local i
      for ((i = 0; i < D_COUNT; i++)); do args+=(-u "${D_UNIT[$i]}"); done ;;
    *[!0-9]*)
      if unit_exists "$id"; then
        args+=(-u "$id")
      elif unit_exists "$id.service"; then
        args+=(-u "$id.service")
      else
        die "找不到实例 $id"
      fi ;;
    *)
      discover_instances
      local idx=$((id - 1))
      if [ "$idx" -lt 0 ] || [ "$idx" -ge "$D_COUNT" ]; then die "编号超出范围"; fi
      args+=(-u "${D_UNIT[$idx]}") ;;
  esac
  journalctl "${args[@]}" -n "$lines" --no-pager 2>/dev/null || die "读取日志失败"
}

cmd_uninstall() {
  need_root; need_systemd
  load_conf
  discover_instances
  if [ "$D_COUNT" -eq 0 ]; then warn "没有可卸载的实例"; return 0; fi

  local -a items=()
  local i
  for ((i = 0; i < D_COUNT; i++)); do
    items+=("$(padr "${D_UNIT[$i]%.service}" 22)  ${D_TAG[$i]}")
  done
  items+=("全部卸载")
  pick "卸载实例" "选择要删除的实例" "${items[@]}" || return 0

  if [ "$PICK_RESULT" -eq "$D_COUNT" ]; then
    local go
    warn "将删除全部 ${D_COUNT} 个实例（服务 + 安装目录）"
    ask "确认? (y/N)" "N" go
    case "$go" in
      [Yy]*) ;;
      *) warn "已取消"; return 0 ;;
    esac
    for ((i = 0; i < D_COUNT; i++)); do
      remove_unit "${D_UNIT[$i]}" 1
    done
  else
    remove_unit "${D_UNIT[$PICK_RESULT]}"
  fi
}

# ================================================================ 版本维护 ===
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
    ka                    主菜单（↑↓ 选择）
    ka install            直接进入安装向导

  ${B}管理${RESET}
    ka status             实例状态（含已存在的实例）
    ka logs <n|unit|all>  查看日志，默认 80 行
    ka uninstall          卸载实例

  ${B}版本${RESET}
    ka version            版本与归档信息
    ka bump               发布新版本，旧文件保留
    ka self-install       安装到 /opt/ka 并建立全局 ka 命令

  ${B}环境变量${RESET}
    KA_CONF               配置文件路径，默认 /etc/ka.conf
    KA_TUI=0              关闭方向键菜单（用编号菜单）
    KA_UI=plain           关闭彩色（也可用 NO_COLOR=1）

EOF
}

# ==================================================================== 菜单 ===
cmd_menu() {
  [ -t 0 ] || die "菜单需要交互式终端；可用 ka install / ka status 等子命令"
  tui_init
  load_conf
  local -a items=()
  local sub
  while :; do
    discover_instances
    case "$D_COUNT" in
      0) sub="未发现已安装实例" ;;
      1) sub="已发现 1 个已安装实例" ;;
      *) sub="已发现 ${D_COUNT} 个已安装实例" ;;
    esac
    items=("安装 / 新增实例" "实例管理" "版本信息" "退出")
    pick "主菜单" "$sub" "${items[@]}" || return 0
    case "$PICK_RESULT" in
      0) cmd_wizard; pause_any ;;
      1) cmd_instances; pause_any ;;
      2) cmd_version; pause_any ;;
      3) return 0 ;;
    esac
  done
}

# ==================================================================== 入口 ===
main() {
  local cmd="${1:-menu}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    menu|'')              cmd_menu ;;
    wizard|install)       cmd_wizard ;;
    status)               cmd_status ;;
    logs)                 cmd_logs "$@" ;;
    uninstall|remove)     cmd_uninstall ;;
    version|-v|--version) cmd_version ;;
    bump)                 cmd_bump ;;
    self-install)         cmd_self_install "$@" ;;
    help|-h|--help)       cmd_help ;;
    *) err "未知命令: $cmd"; cmd_help; exit 1 ;;
  esac
}

main "$@"
