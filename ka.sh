#!/usr/bin/env bash
# =============================================================================
#  ka  ·  Komari Agent 部署器
#  版本: 0.0.10        归档文件: ka-v<版本>.sh
#  版本规则: 每次修改 +0.0.1（0.0.1 → 0.0.2 → 0.0.3），旧文件全部保留
#
#  用法:
#    ka                     主菜单（↑↓ 选择，回车确认）
#    ka install             直接进安装向导
#    ka status              实例状态
#    ka logs <n|name|all>   查看日志
#    ka uninstall           卸载实例
#    ka version             版本与归档信息
#    ka bump                发布新版本（+0.1，旧版本文件保留）
#    ka self-install        安装到 /opt/ka 并建立 ka 命令
#
#  安装流程: 面板地址 → 粘贴 token（一行一个，空行结束）→ 参数 → 确认
#            节点数量 = token 数量，不再单独问“几个实例”
#  已有实例: 同时识别 systemd 与 OpenRC(Alpine) 服务，外加正在跑的进程兜底
#  界面: 256/16 色自适应；非交互终端退回编号菜单（KA_TUI=0 强制）
# =============================================================================

set -u

KA_VERSION="0.0.10"
KA_BUMP_STYLE="patch"
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
  local w="${1:-58}"
  local seg=$(((w + 3) / 4))
  local -a cols=("$PINK" "$PURP" "$BLUE" "$CYAN")
  local j i s
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
  printf '  %s%s%s %s%s:%s %s%s%s\n' \
    "$PURP" "$G_BAR" "$RESET" "$GRAY" "$1" "$RESET" "$WHITE" "$2" "$RESET"
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
PICK_START=0
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
  if [ -n "${KA_TMP:-}" ] && [ -f "$KA_TMP" ]; then rm -f "$KA_TMP"; fi
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
  local title="$1" sub="${2:-}" line
  printf '  %s\n' "$(rainbow 'K O M A R I   A G E N T')"
  printf '  %s%s%s\n' "$GRAY" "$(repeat "$G_RULE" 40)" "$RESET"
  printf '  %s%s%s  %s%s%s\n' "$PINK" "$G_BAR" "$RESET" "$B" "$title" "$RESET"
  if [ -n "$sub" ]; then
    printf '\n'
    while IFS= read -r line; do
      printf '  %s%s%s\n' "$GRAY" "$line" "$RESET"
    done <<< "$sub"
  fi
  printf '\n'
}

is_sep() { [ "${1:-}" = "──" ]; }

detect_nics() {
  local p
  if [ -d /sys/class/net ]; then
    for p in /sys/class/net/*; do
      [ -e "$p" ] && basename "$p"
    done
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    ip -o link 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig -a 2>/dev/null | awk '/^[a-zA-Z0-9]/ {print $1}' | tr -d ':'
  fi
}

detect_mounts() {
  [ -r /proc/mounts ] || return 0
  awk '$2 !~ /^\/(proc|sys|dev|run)(\/|$)/ {print $2}' /proc/mounts 2>/dev/null \
    | awk '!seen[$0]++' | sort
}

pick_multi() { # 标题 副标题 分隔符 变量名 候选项...
  local title="$1" sub="$2" sep="$3" var="$4"
  shift 4
  local -a opts=("$@")
  local cur="${!var}" x c i found

  # 当前值拆开（用 read -a，避免路径被 glob 展开）
  local IFS_OLD="$IFS"
  local -a sel=()
  IFS="$sep" read -r -a sel <<< "$cur"
  IFS="$IFS_OLD"

  # 已配置但不在候选里的值也补进来
  for x in ${sel[@]+"${sel[@]}"}; do
    [ -n "$x" ] || continue
    found=0
    for c in ${opts[@]+"${opts[@]}"}; do
      if [ "$c" = "$x" ]; then found=1; break; fi
    done
    if [ "$found" -eq 0 ]; then opts+=("$x"); fi
  done

  local -a checked=()
  for ((i = 0; i < ${#opts[@]}; i++)); do
    checked+=(0)
    for x in ${sel[@]+"${sel[@]}"}; do
      if [ "$x" = "${opts[$i]}" ]; then checked[$i]=1; fi
    done
  done

  local n="${#opts[@]}" total=$((n + 2)) sel_i=0
  hide_cursor
  while :; do
    screen_home
    draw_header "$title" "$sub"
    for ((i = 0; i < n; i++)); do
      local mark
      if [ "${checked[$i]}" -eq 1 ]; then mark="${GREEN}[x]${RESET}"; else mark="${GRAY}[ ]${RESET}"; fi
      if [ "$i" -eq "$sel_i" ]; then
        printf '   %s❯%s %s %s\n' "$PINK" "$RESET" "$mark" "${opts[$i]}"
      else
        printf '     %s %s\n' "$mark" "${opts[$i]}"
      fi
    done
    printf '     %s──────%s\n' "$DIM" "$RESET"
    if [ "$sel_i" -eq "$n" ]; then
      printf '   %s❯%s %s\n' "$PINK" "$RESET" "手动输入…"
    else
      printf '     %s\n' "手动输入…"
    fi
    if [ "$sel_i" -eq $((n + 1)) ]; then
      printf '   %s❯%s %s\n' "$PINK" "$RESET" "${GREEN}完成${RESET}"
    else
      printf '     %s\n' "完成"
    fi
    printf '\n   %s空格/回车 勾选 · q 取消%s\n' "$GRAY" "$RESET"
    if ! read_key; then break; fi
    case "$KEY" in
      UP)   sel_i=$(((sel_i + total - 1) % total)) ;;
      DOWN) sel_i=$(((sel_i + 1) % total)) ;;
      QUIT|ESC) show_cursor; return 1 ;;
      ENTER|SPACE)
        if [ "$sel_i" -lt "$n" ]; then
          if [ "${checked[$sel_i]}" -eq 1 ]; then checked[$sel_i]=0; else checked[$sel_i]=1; fi
        elif [ "$sel_i" -eq "$n" ]; then
          show_cursor
          screen_home
          draw_header "$title" "手动追加（多个用 $sep 分隔，回车返回）"
          local add
          ask "追加" "" add
          if [ -n "$add" ]; then
            local -a adds=()
            IFS="$sep" read -r -a adds <<< "$add"
            IFS="$IFS_OLD"
            for x in ${adds[@]+"${adds[@]}"}; do
              [ -n "$x" ] || continue
              opts+=("$x"); checked+=("1")
            done
            n="${#opts[@]}"; total=$((n + 2))
            sel_i=$((n + 1))
          fi
          hide_cursor
        else
          break
        fi ;;
    esac
  done
  show_cursor

  local out=""
  for ((i = 0; i < n; i++)); do
    if [ "${checked[$i]}" -eq 1 ]; then
      if [ -n "$out" ]; then out+="$sep"; fi
      out+="${opts[$i]}"
    fi
  done
  printf -v "$var" '%s' "$out"
  return 0
}

pick() {
  local title="$1" sub="$2"
  shift 2
  local -a items=("$@")
  local n="${#items[@]}" i v
  if [ "$n" -eq 0 ]; then return 1; fi

  local -a av=()
  for ((i = 0; i < n; i++)); do
    if ! is_sep "${items[$i]}"; then av+=("$i"); fi
  done
  local m="${#av[@]}"
  if [ "$m" -eq 0 ]; then return 1; fi

  local sel="${av[0]}" pos=0
  if [ "${PICK_START:-0}" -ge 0 ] && [ "${PICK_START:-0}" -lt "$n" ] \
     && ! is_sep "${items[${PICK_START:-0}]}"; then
    sel="${PICK_START:-0}"
  fi
  PICK_START=0
  for ((i = 0; i < m; i++)); do
    if [ "${av[$i]}" -eq "$sel" ]; then pos="$i"; fi
  done

  if [ "$UI_TUI" -eq 0 ]; then
    printf '\n  %s%s%s  %s\n\n' "$PINK" "$G_BAR" "$RESET" "$title"
    if [ -n "$sub" ]; then printf '  %s%s%s\n\n' "$GRAY" "$sub" "$RESET"; fi
    local idx=0
    for ((i = 0; i < n; i++)); do
      if is_sep "${items[$i]}"; then
        printf '   %s──────%s\n' "$DIM" "$RESET"
      else
        idx=$((idx + 1))
        printf '   %s%s%d%s  %s\n' "$CYAN" "$B" "$idx" "$RESET" "${items[$i]}"
      fi
    done
    printf '\n'
    ask_int "选择" "$((pos + 1))" v 1 "$m"
    PICK_RESULT="${av[$((v - 1))]}"
    return 0
  fi

  hide_cursor
  while :; do
    screen_home
    draw_header "$title" "$sub"
    for ((i = 0; i < n; i++)); do
      if is_sep "${items[$i]}"; then
        printf '   %s──────%s\n' "$DIM" "$RESET"
      elif [ "$i" -eq "$sel" ]; then
        printf '   %s❯%s %s%s%s\n' "$PINK" "$RESET" "$B" "${items[$i]}" "$RESET"
      else
        printf '     %s\n' "${items[$i]}"
      fi
    done
    printf '\n   %s↑↓ 移动 · Enter 选择 · q 返回%s\n' "$GRAY" "$RESET"
    if ! read_key; then show_cursor; return 1; fi
    case "$KEY" in
      UP)   pos=$(((pos + m - 1) % m)); sel="${av[$pos]}" ;;
      DOWN) pos=$(((pos + 1) % m)); sel="${av[$pos]}" ;;
      ENTER|SPACE) break ;;
      QUIT|ESC) show_cursor; return 2 ;;
      [0-9])
        v=$((KEY - 1))
        if [ "$v" -ge 0 ] && [ "$v" -lt "$m" ]; then pos="$v"; sel="${av[$pos]}"; fi ;;
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
    printf '   %s❯%s %s%s:%s %s\n' "$PINK" "$RESET" "$B" "$label" "$RESET" "$value"
  else
    printf '     %s:%s %s\n' "$label" "$RESET" "$value"
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
  local label="$1" var="$2" v
  show_cursor
  screen_home
  draw_header "修改" "回车保留，输入 - 清空"
  ask "$label" "${!var}" v
  if [ "$v" = "-" ]; then v=""; fi
  printf -v "$var" '%s' "$v"
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
MEM_CACHE=0
GET_IP_NIC=0
INSECURE=0
INCLUDE_NICS=""
EXCLUDE_NICS=""
MOUNT_POINTS=""
MONTH_ROTATE="0"
GPU_MONITOR=0
EXTRA_AGENT=""
INSTALL_VERSION=""
GH_PROXY=""
INSTANCE_COUNT=1
MULTI=0
FORCE_SUFFIX=0
NAME_START=1
CANCELED=0
TOKENS=()
ARGS=()
IARGS=()

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
  MEM_CACHE="${KA_MEMCACHE:-$MEM_CACHE}"
  GET_IP_NIC="${KA_GETIP:-$GET_IP_NIC}"
  INSECURE="${KA_INSECURE:-$INSECURE}"
  INCLUDE_NICS="${KA_INCLUDE_NICS:-$INCLUDE_NICS}"
  EXCLUDE_NICS="${KA_EXCLUDE_NICS:-$EXCLUDE_NICS}"
  MOUNT_POINTS="${KA_MOUNT_POINTS:-$MOUNT_POINTS}"
  MONTH_ROTATE="${KA_MONTH_ROTATE:-$MONTH_ROTATE}"
  GPU_MONITOR="${KA_GPU:-$GPU_MONITOR}"
  EXTRA_AGENT="${KA_EXTRA:-$EXTRA_AGENT}"
  INSTALL_VERSION="${KA_INSTALL_VERSION:-$INSTALL_VERSION}"
  GH_PROXY="${KA_GH_PROXY:-$GH_PROXY}"
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
KA_MEMCACHE='$MEM_CACHE'
KA_GETIP='$GET_IP_NIC'
KA_INSECURE='$INSECURE'
KA_INCLUDE_NICS='$INCLUDE_NICS'
KA_EXCLUDE_NICS='$EXCLUDE_NICS'
KA_MOUNT_POINTS='$MOUNT_POINTS'
KA_MONTH_ROTATE='$MONTH_ROTATE'
KA_GPU='$GPU_MONITOR'
KA_EXTRA='$EXTRA_AGENT'
KA_INSTALL_VERSION='$INSTALL_VERSION'
KA_GH_PROXY='$GH_PROXY'
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

# ================================================================ 环境/服务 ===
need_root()    { [ "$(id -u)" -eq 0 ] || die "需要 root 权限，请用 sudo ka"; }
need_curl()    { command -v curl >/dev/null 2>&1 || die "没有 curl，请先安装"; }

INIT_SYS=""
detect_init() {
  INIT_SYS="none"
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT_SYS="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
  elif [ -d /etc/init.d ] && [ -n "$(ls -A /etc/init.d 2>/dev/null)" ]; then
    INIT_SYS="openrc"
  fi
  printf '%s' "$INIT_SYS"
}

init_label() {
  case "$1" in
    systemd) printf 'systemd' ;;
    openrc)  printf 'OpenRC' ;;
    *)       printf '未知' ;;
  esac
}

inst_dir() {
  if [ "$FORCE_SUFFIX" -eq 1 ]; then
    printf '%s/nat%s' "$BASE_DIR" "$((NAME_START + $1 - 1))"
  elif [ "$INSTANCE_COUNT" -eq 1 ]; then
    printf '%s' "$BASE_DIR"
  else
    printf '%s/nat%s' "$BASE_DIR" "$1"
  fi
}
inst_svc() {
  if [ "$FORCE_SUFFIX" -eq 1 ]; then
    printf '%s-%s' "$SVC_PREFIX" "$((NAME_START + $1 - 1))"
  elif [ "$INSTANCE_COUNT" -eq 1 ]; then
    printf '%s' "$SVC_PREFIX"
  else
    printf '%s-%s' "$SVC_PREFIX" "$1"
  fi
}

build_args() {
  ARGS=(-e "$ENDPOINT" -i "$INTERVAL" --info-report-interval "$INFO_INTERVAL")
  [ "$DISABLE_WEBSSH" -eq 1 ]     && ARGS+=(--disable-web-ssh)
  [ "$DISABLE_AUTOUPDATE" -eq 1 ] && ARGS+=(--disable-auto-update)
  [ "$MEM_CACHE" -eq 1 ]          && ARGS+=(--memory-include-cache)
  [ "$GET_IP_NIC" -eq 1 ]         && ARGS+=(--get-ip-addr-from-nic)
  [ "$INSECURE" -eq 1 ]           && ARGS+=(-u)
  [ "$GPU_MONITOR" -eq 1 ]        && ARGS+=(--gpu)
  [ -n "$INCLUDE_NICS" ]          && ARGS+=(--include-nics "$INCLUDE_NICS")
  [ -n "$EXCLUDE_NICS" ]          && ARGS+=(--exclude-nics "$EXCLUDE_NICS")
  [ -n "$MOUNT_POINTS" ]          && ARGS+=(--include-mountpoint "$MOUNT_POINTS")
  [ "$MONTH_ROTATE" != "0" ]      && ARGS+=(--month-rotate "$MONTH_ROTATE")
  if [ -n "$EXTRA_AGENT" ]; then
    # shellcheck disable=SC2206
    ARGS+=($EXTRA_AGENT)
  fi
  return 0
}

install_args() {
  IARGS=()
  [ -n "$INSTALL_VERSION" ] && IARGS+=(--install-version "$INSTALL_VERSION")
  [ -n "$GH_PROXY" ]        && IARGS+=(--install-ghproxy "$GH_PROXY")
  return 0
}

# 从参数串里解析 -e / -t
EP=""
TK=""
parse_args() {
  local -a av=($1)
  local i
  EP=""; TK=""
  for ((i = 0; i < ${#av[@]}; i++)); do
    case "${av[$i]}" in
      -e|--endpoint) EP="${av[$((i + 1))]:-}" ;;
      -t|--token)    TK="${av[$((i + 1))]:-}" ;;
    esac
  done
}

svc_state() { # 名字 类型
  local n="$1" k="$2"
  case "$k" in
    systemd) systemctl is-active "$n" 2>/dev/null ;;
    openrc)
      if rc-service "$n" status >/dev/null 2>&1; then printf 'active'; else printf 'inactive'; fi ;;
    proc)
      if [ -d "/proc/${n#pid-}" ]; then printf 'active'; else printf 'inactive'; fi ;;
  esac
}

svc_ctl() { # 动作 名字 类型
  local act="$1" n="$2" k="$3"
  case "$k" in
    systemd) systemctl "$act" "$n" >/dev/null 2>&1 ;;
    openrc)  rc-service "$n" "$act" >/dev/null 2>&1 ;;
    proc)
      case "$act" in
        stop) kill "${n#pid-}" >/dev/null 2>&1 ;;
        *) return 1 ;;
      esac ;;
  esac
}

svc_logs() { # 名字 类型 行数
  local n="$1" k="$2" lines="${3:-100}"
  case "$k" in
    systemd)
      journalctl -u "$n" -n "$lines" --no-pager 2>/dev/null ;;
    openrc)
      if [ -f "/var/log/$n.log" ]; then
        tail -n "$lines" "/var/log/$n.log"
      elif [ -f /var/log/komari-agent.log ]; then
        tail -n "$lines" /var/log/komari-agent.log
      elif command -v logread >/dev/null 2>&1; then
        logread 2>/dev/null | grep -i "$n" | tail -n "$lines"
      elif [ -f /var/log/messages ]; then
        grep -i "$n" /var/log/messages | tail -n "$lines"
      else
        return 1
      fi ;;
    *) return 1 ;;
  esac
}

svc_enabled() { # 名字 类型
  local n="$1" k="$2"
  case "$k" in
    systemd) systemctl is-enabled "$n" 2>/dev/null || true ;;
    openrc)
      if rc-update show default 2>/dev/null | awk '{print $1}' | grep -qx "$n"; then
        printf 'enabled'
      else
        printf 'disabled'
      fi ;;
    *) printf '—' ;;
  esac
}

# ============================================================ 已有实例扫描 ===
D_COUNT=0
D_NAME=(); D_KIND=(); D_EXE=(); D_DIR=(); D_EP=(); D_TK=(); D_TAG=(); D_ARGS=()

add_instance() { # 名字 类型 可执行文件 面板 token 原始参数
  local name="$1" kind="$2" exe="$3" ep="$4" tk="$5" raw="${6:-}"
  local dir tag
  dir="$(dirname "$exe")"
  tag="外部"
  case "$name" in
    "$SVC_PREFIX"|"$SVC_PREFIX"-*) tag="受管" ;;
  esac
  case "$dir" in
    "$BASE_DIR"|"${BASE_DIR%/}"/*|/opt/komari|/opt/komari/*) tag="受管" ;;
  esac
  D_NAME+=("$name"); D_KIND+=("$kind"); D_EXE+=("$exe"); D_DIR+=("$dir")
  D_EP+=("$ep"); D_TK+=("$tk"); D_TAG+=("$tag"); D_ARGS+=("$raw")
  D_COUNT=$((D_COUNT + 1))
}

discover_systemd() {
  local -a units=()
  local hit unit line exe raw
  while IFS= read -r hit; do
    [ -n "$hit" ] && units+=("$(basename "$hit" .service)")
  done <<< "$(grep -lis 'komari-agent' \
      /etc/systemd/system/*.service \
      /usr/lib/systemd/system/*.service \
      /lib/systemd/system/*.service 2>/dev/null)"
  while IFS= read -r unit; do
    [ -n "$unit" ] && units+=("${unit%.service}")
  done <<< "$(systemctl list-unit-files 'komari-agent*.service' --no-legend --no-pager 2>/dev/null | awk '{print $1}')"
  [ "${#units[@]}" -eq 0 ] && return 0

  local sorted
  sorted="$(printf '%s\n' "${units[@]}" | sort -u)"
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    line="$(systemctl cat "$unit.service" 2>/dev/null | sed -n 's/^ExecStart=//p' | head -n1)"
    [ -n "$line" ] || continue
    exe="${line%% *}"
    exe="${exe#-}"; exe="${exe%\"}"; exe="${exe#\"}"
    case "$exe" in *komari*) ;; *) continue ;; esac
    parse_args "$line"
    raw="${line#* }"
    [ "$raw" = "$line" ] && raw=""
    add_instance "$unit" systemd "$exe" "$EP" "$TK" "$raw"
  done <<< "$sorted"
}

discover_openrc() {
  local f name exe args conf
  for f in /etc/init.d/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    if ! printf '%s' "$name" | grep -qi 'komari'; then
      grep -qi 'komari' "$f" 2>/dev/null || continue
    fi
    exe="$(sed -n 's/^[[:space:]]*command=//p' "$f" 2>/dev/null | head -n1 | tr -d '"')"
    args="$(sed -n 's/^[[:space:]]*command_args=//p' "$f" 2>/dev/null | head -n1 | tr -d '"')"
    conf="/etc/conf.d/$name"
    if [ -z "$exe" ] && [ -f "$conf" ]; then
      exe="$(sed -n 's/^[[:space:]]*command=//p' "$conf" 2>/dev/null | head -n1 | tr -d '"')"
      args="$(sed -n 's/^[[:space:]]*command_args=//p' "$conf" 2>/dev/null | head -n1 | tr -d '"')"
    fi
    if [ -z "$exe" ]; then continue; fi
    parse_args "$args"
    add_instance "$name" openrc "$exe" "$EP" "$TK" "$args"
  done
}

init_for_exe() { # 用可执行文件路径反查是哪个 init 脚本
  local exe="$1" f
  for f in /etc/init.d/*; do
    [ -f "$f" ] || continue
    if grep -qF "$exe" "$f" 2>/dev/null; then
      basename "$f"
      return 0
    fi
  done
  return 1
}

discover_procs() {
  local p cmd exe pid i covered
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    cmd="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)"
    [ -n "$cmd" ] || continue
    exe="${cmd%% *}"
    case "$exe" in *komari*) ;; *) continue ;; esac
    pid="${p#/proc/}"
    [ "$pid" = "$$" ] && continue
    parse_args "$cmd"
    covered=0
    for ((i = 0; i < D_COUNT; i++)); do
      if [ "${D_EXE[$i]}" = "$exe" ]; then covered=$((i + 1)); break; fi
    done
    if [ "$covered" -gt 0 ]; then
      # 服务已登记，用真实命令行补全缺失的面板地址 / token / 参数
      local j=$((covered - 1))
      if [ -z "${D_EP[$j]}" ] && [ -n "$EP" ]; then D_EP[$j]="$EP"; fi
      if [ -z "${D_TK[$j]}" ] && [ -n "$TK" ]; then D_TK[$j]="$TK"; fi
      if [ -z "${D_ARGS[$j]}" ] && [ -n "$cmd" ]; then D_ARGS[$j]="${cmd#* }"; fi
      continue
    fi
    local svc
    if svc="$(init_for_exe "$exe")"; then
      add_instance "$svc" openrc "$exe" "$EP" "$TK" "${cmd#* }"
    else
      add_instance "pid-$pid" proc "$exe" "$EP" "$TK" "${cmd#* }"
    fi
  done
}

discover_instances() {
  D_COUNT=0
  D_NAME=(); D_KIND=(); D_EXE=(); D_DIR=(); D_EP=(); D_TK=(); D_TAG=(); D_ARGS=()
  detect_init >/dev/null
  case "$INIT_SYS" in
    systemd) discover_systemd ;;
    openrc)  discover_openrc ;;
  esac
  discover_procs
}

count_managed() {
  local i n=0
  for ((i = 0; i < D_COUNT; i++)); do
    if [ "${D_TAG[$i]}" = "受管" ]; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

# ---------------------------------------------------------------- 元数据 ---
META_FILE="${KA_META:-/etc/ka-meta.tsv}"

http_get() { curl -fsSL --max-time 4 "$1" 2>/dev/null; }

detect_public_ip() {
  local u ip
  for u in "https://api.ip.sb/ip" "https://ipinfo.io/ip"; do
    ip="$(http_get "$u" | tr -d '[:space:]')"
    case "$ip" in
      ''|*[!0-9a-fA-F:.]*) continue ;;
    esac
    printf '%s' "$ip"
    return 0
  done
  return 1
}

detect_geo_label() {
  local ip="$1" j c cy
  j="$(http_get "http://ip-api.com/json/${ip}?lang=zh-CN&fields=status,country,city")"
  if printf '%s' "$j" | grep -q '"status":"success"'; then
    c="$(printf '%s' "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')"
    cy="$(printf '%s' "$j" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')"
    if [ -n "$c" ] && [ -n "$cy" ]; then printf '%s·%s' "$c" "$cy"; return 0; fi
    if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  fi
  j="$(http_get "https://ipinfo.io/${ip}/json")"
  c="$(printf '%s' "$j" | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p')"
  cy="$(printf '%s' "$j" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p')"
  if [ -n "$c" ] && [ -n "$cy" ]; then printf '%s·%s' "$c" "$cy"; return 0; fi
  if [ -n "$c" ]; then printf '%s' "$c"; fi
  return 0
}

GEO_TRIED=0
GEO_IP=""
GEO_RESULT=""
geo_note() {
  GEO_RESULT=""
  [ "${KA_NO_GEO:-0}" = "1" ] && return 0
  if [ "$GEO_TRIED" -eq 0 ]; then
    GEO_TRIED=1
    GEO_IP="$(detect_public_ip || true)"
    if [ -n "$GEO_IP" ]; then
      GEO_RESULT="$(detect_geo_label "$GEO_IP")"
    fi
  fi
  return 0
}

meta_get() {
  [ -f "$META_FILE" ] || return 0
  awk -F "$(printf '\t')" -v k="$1" '$1 == k { print $2; exit }' "$META_FILE" 2>/dev/null
}

meta_set() {
  local name="$1" note="$2" tmp
  mkdir -p "$(dirname "$META_FILE")" 2>/dev/null || true
  tmp="${META_FILE}.tmp.$$"
  : > "$tmp" 2>/dev/null || { warn "无法写入 $META_FILE"; return 1; }
  if [ -f "$META_FILE" ]; then
    awk -F "$(printf '\t')" -v k="$name" '$1 != k' "$META_FILE" >> "$tmp" 2>/dev/null
  fi
  if [ -n "$note" ]; then
    printf '%s\t%s\n' "$name" "$note" >> "$tmp"
  fi
  if mv -f "$tmp" "$META_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  warn "写入 $META_FILE 失败"
  return 1
}

find_idx() {
  local name="$1" i
  for ((i = 0; i < D_COUNT; i++)); do
    if [ "${D_NAME[$i]}" = "$name" ]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

# ------------------------------------------------ 安装器 / 服务操作工具 ---
KA_TMP=""
fetch_installer() {
  [ -n "$KA_TMP" ] && [ -s "$KA_TMP" ] && return 0
  need_curl
  KA_TMP="$(mktemp /tmp/ka-install.XXXXXX)" || return 1
  if ! curl -fsSL --max-time 120 "$KA_INSTALLER" -o "$KA_TMP" || [ ! -s "$KA_TMP" ]; then
    rm -f "$KA_TMP"
    KA_TMP=""
    return 1
  fi
}

filter_args() { # 去掉 -e/-t 及其值，保留其余参数
  local -a av=($1)
  local i s=""
  for ((i = 0; i < ${#av[@]}; i++)); do
    case "${av[$i]}" in
      -e|--endpoint|-t|--token) i=$((i + 1)); continue ;;
      *) s+=" ${av[$i]}" ;;
    esac
  done
  printf '%s' "${s# }"
}

reinstall_service() { # 目录 服务名 面板 token 额外参数
  local dir="$1" name="$2" ep="$3" tk="$4" extra="${5:-}"
  install_args
  # shellcheck disable=SC2086
  bash "$KA_TMP" -e "$ep" -t "$tk" "${IARGS[@]}" \
    --install-dir "$dir" --install-service-name "$name" $extra </dev/null
}

enable_start() { # 名字 类型
  local n="$1" k="$2"
  case "$k" in
    systemd) systemctl enable --now "$n" >/dev/null 2>&1 || true ;;
    openrc)
      rc-update add "$n" default >/dev/null 2>&1 || true
      rc-service "$n" start >/dev/null 2>&1 || true ;;
  esac
}

purge_service() { # 名字 类型：只删服务定义，不动目录
  local n="$1" k="$2"
  case "$k" in
    systemd)
      systemctl disable "$n" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$n.service"
      systemctl daemon-reload 2>/dev/null || true ;;
    openrc)
      rc-update del "$n" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/$n" ;;
  esac
}

remove_index() { # 下标 [force]
  local idx="$1" force="${2:-0}"
  local n="${D_NAME[$idx]}" k="${D_KIND[$idx]}" dir="${D_DIR[$idx]}"
  local go ok_dir=0 j shared=0

  # 目录是否被其它实例共用：单实例装在 /opt/komari，
  # 多开实例在 /opt/komari/natN，删父目录会把别人一起清掉
  for ((j = 0; j < D_COUNT; j++)); do
    [ "$j" -eq "$idx" ] && continue
    case "${D_DIR[$j]}" in
      "$dir"|"$dir"/*) shared=1; break ;;
    esac
  done

  if [ "$force" -eq 0 ]; then
    warn "将停止并删除 $n（$k）"
    dim "目录 $dir"
    if [ "$shared" -eq 1 ]; then
      warn "该目录下还有其它实例，目录会保留，只删这个服务"
      for ((j = 0; j < D_COUNT; j++)); do
        [ "$j" -eq "$idx" ] && continue
        case "${D_DIR[$j]}" in
          "$dir"|"$dir"/*) dim "  · ${D_NAME[$j]}  ${D_DIR[$j]}" ;;
        esac
      done
    fi
    ask "确认? (y/N)" "N" go
    case "$go" in
      [Yy]*) ;;
      *) warn "已跳过"; return 0 ;;
    esac
  fi

  case "$k" in
    systemd)
      systemctl disable --now "$n" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$n.service"
      systemctl daemon-reload ;;
    openrc)
      rc-service "$n" stop >/dev/null 2>&1 || true
      rc-update del "$n" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/$n" ;;
    proc)
      kill "${n#pid-}" >/dev/null 2>&1 || true ;;
  esac

  case "$dir" in
    /opt/komari*|/opt/ka*) ok_dir=1 ;;
  esac
  if [ "$ok_dir" -eq 0 ] && [ -n "${BASE_DIR:-}" ] && [ "$BASE_DIR" != "/" ]; then
    case "$dir" in
      "$BASE_DIR"|"${BASE_DIR%/}"/*) ok_dir=1 ;;
    esac
  fi

  if [ "$ok_dir" -eq 1 ] && [ "$k" != "proc" ] && [ "$shared" -eq 0 ]; then
    rm -rf "$dir"
    ok "$n 已卸载，目录 $dir 已删除"
  elif [ "$shared" -eq 1 ]; then
    ok "$n 已卸载"
    warn "目录 $dir 仍被其它实例使用，已保留"
  else
    ok "$n 已卸载"
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

  # 机器上已有实例：新节点从下一个空闲编号开始，绝不覆盖老实例
  FORCE_SUFFIX=0
  NAME_START=1
  if [ "$D_COUNT" -gt 0 ]; then
    FORCE_SUFFIX=1
    local n=1
    while service_name_taken "${SVC_PREFIX}-${n}"; do n=$((n + 1)); done
    NAME_START="$n"
  fi

  # 同一 token 只能对应一个节点，重复会互相顶掉
  local i k
  for ((i = 0; i < INSTANCE_COUNT; i++)); do
    for ((k = 0; k < D_COUNT; k++)); do
      if [ -n "${D_TK[$k]:-}" ] && [ "${D_TK[$k]}" = "${TOKENS[$i]}" ]; then
        warn "token 与已有实例 ${D_NAME[$k]} 相同，会抢同一个节点"
      fi
    done
  done

  blank
  if [ "$FORCE_SUFFIX" -eq 1 ] && [ "$INSTANCE_COUNT" -eq 1 ]; then
    ok "共 1 个节点 → ${SVC_PREFIX}-${NAME_START}（不动已有的 ${SVC_PREFIX}）"
  elif [ "$FORCE_SUFFIX" -eq 1 ]; then
    ok "共 ${INSTANCE_COUNT} 个节点 → ${SVC_PREFIX}-${NAME_START} … ${SVC_PREFIX}-$((NAME_START + INSTANCE_COUNT - 1))"
  elif [ "$MULTI" -eq 1 ]; then
    ok "共 ${INSTANCE_COUNT} 个节点 → ${SVC_PREFIX}-1 … ${SVC_PREFIX}-${INSTANCE_COUNT}"
  else
    ok "共 1 个节点 → 单实例 ${SVC_PREFIX}"
  fi
}

adv_run() { # 标题 副标题 绘制函数 编辑函数 项数
  local title="$1" sub="$2" draw="$3" edit="$4" n="$5"
  local sel=0
  hide_cursor
  while :; do
    screen_home
    draw_header "$title" "$sub"
    "$draw" "$sel"
    printf '\n   %s↑↓ 移动 · Enter 修改 · Esc 返回%s\n' "$GRAY" "$RESET"
    if ! read_key; then break; fi
    case "$KEY" in
      UP)   sel=$(((sel + n - 1) % n)) ;;
      DOWN) sel=$(((sel + 1) % n)) ;;
      ESC|QUIT) break ;;
      ENTER|SPACE)
        if ! "$edit" "$sel"; then break; fi ;;
    esac
  done
  show_cursor
  blank
}

ADV_MORE_DRAW="adv_draw2"
ADV_MORE_EDIT="adv_edit2"
ADV_MORE_N=8

adv_draw1() {
  local s="$1"
  cfg_row 0 "$s" "采集间隔"       "${YELL}${INTERVAL}${RESET} 秒"
  cfg_row 1 "$s" "信息上报间隔"   "${YELL}${INFO_INTERVAL}${RESET} 分钟"
  cfg_row 2 "$s" "禁用远程控制"   "$(toggle_render "$DISABLE_WEBSSH")"
  cfg_row 3 "$s" "禁用自动更新"   "$(toggle_render "$DISABLE_AUTOUPDATE")"
  cfg_row 4 "$s" "忽略不安全证书" "$(toggle_render "$INSECURE")"
  cfg_row 5 "$s" "包含缓冲区内存" "$(toggle_render "$MEM_CACHE")"
  cfg_row 6 "$s" "从网卡获取 IP"  "$(toggle_render "$GET_IP_NIC")"
  cfg_row 7 "$s" "详细 GPU 监控"  "$(toggle_render "$GPU_MONITOR")"
  cfg_row 8 "$s" "更多设置"       "${GRAY}网络 / 磁盘 / 安装 →${RESET}"
  cfg_row 9 "$s" "完成并继续"     "${GREEN}→${RESET}"
}

adv_edit1() {
  case "$1" in
    0) edit_num "采集间隔（秒）" INTERVAL ;;
    1) edit_int "信息上报间隔（分钟）" INFO_INTERVAL 1 60 ;;
    2) [ "$DISABLE_WEBSSH" -eq 1 ] && DISABLE_WEBSSH=0 || DISABLE_WEBSSH=1 ;;
    3) [ "$DISABLE_AUTOUPDATE" -eq 1 ] && DISABLE_AUTOUPDATE=0 || DISABLE_AUTOUPDATE=1 ;;
    4) [ "$INSECURE" -eq 1 ] && INSECURE=0 || INSECURE=1 ;;
    5) [ "$MEM_CACHE" -eq 1 ] && MEM_CACHE=0 || MEM_CACHE=1 ;;
    6) [ "$GET_IP_NIC" -eq 1 ] && GET_IP_NIC=0 || GET_IP_NIC=1 ;;
    7) [ "$GPU_MONITOR" -eq 1 ] && GPU_MONITOR=0 || GPU_MONITOR=1 ;;
    8) adv_run "更多设置" "网卡 / 挂载点 / 安装项" "$ADV_MORE_DRAW" "$ADV_MORE_EDIT" "$ADV_MORE_N" ;;
    9) return 1 ;;
  esac
  return 0
}

adv_draw2() {
  local s="$1"
  cfg_row 0 "$s" "包含网卡"     "${WHITE}${INCLUDE_NICS:-全部}${RESET}"
  cfg_row 1 "$s" "排除网卡"     "${WHITE}${EXCLUDE_NICS:-无}${RESET}"
  cfg_row 2 "$s" "包含挂载点"   "${WHITE}${MOUNT_POINTS:-全部}${RESET}"
  cfg_row 3 "$s" "月重置日"     "${YELL}${MONTH_ROTATE}${RESET}（0=关闭）"
  cfg_row 4 "$s" "安装版本"     "${WHITE}${INSTALL_VERSION:-latest}${RESET}"
  cfg_row 5 "$s" "GitHub 代理"  "${WHITE}${GH_PROXY:-直连}${RESET}"
  cfg_row 6 "$s" "额外参数"     "${WHITE}${EXTRA_AGENT:-无}${RESET}"
  cfg_row 7 "$s" "返回"         "${GREEN}←${RESET}"
}

multi_nics() {
  local title="$1" sub="$2" var="$3" x
  local -a c=()
  while IFS= read -r x; do [ -n "$x" ] && c+=("$x"); done <<< "$(detect_nics)"
  pick_multi "$title" "$sub" "," "$var" ${c[@]+"${c[@]}"}
}

multi_mounts() {
  local x
  local -a c=()
  while IFS= read -r x; do [ -n "$x" ] && c+=("$x"); done <<< "$(detect_mounts)"
  pick_multi "包含挂载点" "勾选要统计的挂载点；全不选=全部" ";" MOUNT_POINTS ${c[@]+"${c[@]}"}
}

adv_edit2() {
  case "$1" in
    0) multi_nics "包含网卡" "勾选要统计的网卡；全不选=全部" INCLUDE_NICS ;;
    1) multi_nics "排除网卡" "勾选要排除的网卡" EXCLUDE_NICS ;;
    2) multi_mounts ;;
    3) edit_int "月重置日（1-31，0=关闭）" MONTH_ROTATE 0 31 ;;
    4) edit_str "安装版本（如 1.2.13 / snapshot，空=latest）" INSTALL_VERSION ;;
    5) edit_str "GitHub 代理（如 https://ghproxy.net，空=直连）" GH_PROXY ;;
    6) edit_str "额外参数（原样传给 agent，空=无）" EXTRA_AGENT ;;
    7) return 1 ;;
  esac
  return 0
}

# 修改已安装实例的参数时用这一屏（没有安装版本/代理）
inst_draw2() {
  local s="$1"
  cfg_row 0 "$s" "包含网卡"     "${WHITE}${INCLUDE_NICS:-全部}${RESET}"
  cfg_row 1 "$s" "排除网卡"     "${WHITE}${EXCLUDE_NICS:-无}${RESET}"
  cfg_row 2 "$s" "包含挂载点"   "${WHITE}${MOUNT_POINTS:-全部}${RESET}"
  cfg_row 3 "$s" "月重置日"     "${YELL}${MONTH_ROTATE}${RESET}（0=关闭）"
  cfg_row 4 "$s" "额外参数"     "${WHITE}${EXTRA_AGENT:-无}${RESET}"
  cfg_row 5 "$s" "返回"         "${GREEN}←${RESET}"
}

inst_edit2() {
  case "$1" in
    0) multi_nics "包含网卡" "勾选要统计的网卡；全不选=全部" INCLUDE_NICS ;;
    1) multi_nics "排除网卡" "勾选要排除的网卡" EXCLUDE_NICS ;;
    2) multi_mounts ;;
    3) edit_int "月重置日（1-31，0=关闭）" MONTH_ROTATE 0 31 ;;
    4) edit_str "额外参数（原样传给 agent，空=无）" EXTRA_AGENT ;;
    5) return 1 ;;
  esac
  return 0
}

step_advanced() {
  step_header 3 4 "高级参数"
  if [ "$UI_TUI" -eq 0 ]; then
    step_advanced_plain
    return 0
  fi
  adv_run "高级参数" "默认值够用，Esc 或「完成」继续" adv_draw1 adv_edit1 10
}

step_advanced_plain() {
  local ch v
  dim "输入编号修改，直接回车继续（输入 - 清空该项）"
  blank
  printf '   %s1%s   采集间隔        %s 秒\n' "$CYAN" "$RESET" "$INTERVAL"
  printf '   %s2%s   信息上报间隔    %s 分钟\n' "$CYAN" "$RESET" "$INFO_INTERVAL"
  printf '   %s3%s   禁用远程控制    %s\n' "$CYAN" "$RESET" "$(toggle_render "$DISABLE_WEBSSH")"
  printf '   %s4%s   禁用自动更新    %s\n' "$CYAN" "$RESET" "$(toggle_render "$DISABLE_AUTOUPDATE")"
  printf '   %s5%s   忽略不安全证书  %s\n' "$CYAN" "$RESET" "$(toggle_render "$INSECURE")"
  printf '   %s6%s   详细 GPU 监控   %s\n' "$CYAN" "$RESET" "$(toggle_render "$GPU_MONITOR")"
  printf '   %s7%s   包含网卡        %s\n' "$CYAN" "$RESET" "${INCLUDE_NICS:-全部}"
  printf '   %s8%s   排除网卡        %s\n' "$CYAN" "$RESET" "${EXCLUDE_NICS:-无}"
  printf '   %s9%s   包含挂载点      %s\n' "$CYAN" "$RESET" "${MOUNT_POINTS:-全部}"
  printf '   %s10%s  月重置日        %s\n' "$CYAN" "$RESET" "$MONTH_ROTATE"
  printf '   %s11%s  安装版本        %s\n' "$CYAN" "$RESET" "${INSTALL_VERSION:-latest}"
  printf '   %s12%s  GitHub 代理     %s\n' "$CYAN" "$RESET" "${GH_PROXY:-直连}"
  printf '   %s13%s  安装目录        %s\n' "$CYAN" "$RESET" "$BASE_DIR"
  printf '   %s14%s  服务名前缀      %s\n' "$CYAN" "$RESET" "$SVC_PREFIX"
  printf '   %s15%s  额外参数        %s\n' "$CYAN" "$RESET" "${EXTRA_AGENT:-无}"
  printf '   %s16%s  包含缓冲区内存  %s\n' "$CYAN" "$RESET" "$(toggle_render "$MEM_CACHE")"
  printf '   %s17%s  从网卡获取 IP   %s\n' "$CYAN" "$RESET" "$(toggle_render "$GET_IP_NIC")"
  blank
  while :; do
    ask "编号（回车继续）" "" ch
    case "$ch" in
      '') return 0 ;;
      1) ask_num "采集间隔（秒）" "$INTERVAL" INTERVAL ;;
      2) ask_int "信息上报间隔（分钟）" "$INFO_INTERVAL" INFO_INTERVAL 1 60 ;;
      3) [ "$DISABLE_WEBSSH" -eq 1 ] && DISABLE_WEBSSH=0 || DISABLE_WEBSSH=1 ;;
      4) [ "$DISABLE_AUTOUPDATE" -eq 1 ] && DISABLE_AUTOUPDATE=0 || DISABLE_AUTOUPDATE=1 ;;
      5) [ "$INSECURE" -eq 1 ] && INSECURE=0 || INSECURE=1 ;;
      6) [ "$GPU_MONITOR" -eq 1 ] && GPU_MONITOR=0 || GPU_MONITOR=1 ;;
      7) ask "包含网卡" "$INCLUDE_NICS" v; [ "$v" = "-" ] && v=""; INCLUDE_NICS="$v" ;;
      8) ask "排除网卡" "$EXCLUDE_NICS" v; [ "$v" = "-" ] && v=""; EXCLUDE_NICS="$v" ;;
      9) ask "包含挂载点" "$MOUNT_POINTS" v; [ "$v" = "-" ] && v=""; MOUNT_POINTS="$v" ;;
      10) ask_int "月重置日（0-31）" "$MONTH_ROTATE" MONTH_ROTATE 0 31 ;;
      11) ask "安装版本（空=latest）" "$INSTALL_VERSION" v; [ "$v" = "-" ] && v=""; INSTALL_VERSION="$v" ;;
      12) ask "GitHub 代理" "$GH_PROXY" v; [ "$v" = "-" ] && v=""; GH_PROXY="$v" ;;
      13) ask "安装目录" "$BASE_DIR" BASE_DIR ;;
      14) ask "服务名前缀" "$SVC_PREFIX" SVC_PREFIX ;;
      15) ask "额外参数" "$EXTRA_AGENT" v; [ "$v" = "-" ] && v=""; EXTRA_AGENT="$v" ;;
      16) [ "$MEM_CACHE" -eq 1 ] && MEM_CACHE=0 || MEM_CACHE=1 ;;
      17) [ "$GET_IP_NIC" -eq 1 ] && GET_IP_NIC=0 || GET_IP_NIC=1 ;;
      *) warn "没有 $ch 这个编号" ;;
    esac
    ok "已更新"
  done
}

service_name_taken() {
  local name="$1" i
  for ((i = 0; i < D_COUNT; i++)); do
    if [ "${D_NAME[$i]}" = "$name" ]; then return 0; fi
  done
  return 1
}

step_confirm() {
  build_args
  step_header 4 4 "确认部署"

  local clash="" i svc
  for ((i = 1; i <= INSTANCE_COUNT; i++)); do
    svc="$(inst_svc "$i")"
    if service_name_taken "$svc"; then clash+=" $svc"; fi
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
    printf '  %s%s%s %s#%s%s %s%s%s %s→ %s%s\n' \
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
  need_root; need_curl
  save_conf
  build_args
  install_args
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
    case "$INIT_SYS" in
      systemd) systemctl stop "$svc" >/dev/null 2>&1 || true ;;
      openrc)  rc-service "$svc" stop >/dev/null 2>&1 || true ;;
    esac
    if bash "$tmp" "${ARGS[@]}" "${IARGS[@]}" \
         -t "$token" --install-dir "$dir" --install-service-name "$svc" </dev/null; then
      case "$INIT_SYS" in
        systemd) systemctl enable --now "$svc" >/dev/null 2>&1 || true ;;
        openrc)  rc-service "$svc" start >/dev/null 2>&1 || true
                 rc-update add "$svc" default >/dev/null 2>&1 || true ;;
      esac
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
    local st_text act col dot
    act="$(svc_state "$svc" "$INIT_SYS")"
    if [ "$act" = "active" ]; then col="$GREEN"; dot="$G_DOT"; st_text="运行中"
    else col="$RED"; dot="$G_DOT_OFF"; st_text="$act"; fi
    printf '  %s%s%s %s %s%s%s\n' "$col" "$dot" "$RESET" "$svc" "$col" "$st_text" "$RESET"
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
  detect_init >/dev/null

  # 已有实例的面板地址直接沿用，避免让人重新敲一遍
  local k
  if [ -z "$ENDPOINT" ]; then
    for ((k = 0; k < D_COUNT; k++)); do
      if [ -n "${D_EP[$k]}" ]; then ENDPOINT="${D_EP[$k]}"; break; fi
    done
  fi

  if [ "$UI_TUI" -eq 1 ]; then screen_home; fi
  banner

  if [ "$D_COUNT" -gt 0 ]; then
    panel_row "已有实例" "$D_COUNT 个（$(init_label "$INIT_SYS")）"
    local j
    for ((j = 0; j < D_COUNT; j++)); do
      printf '  %s%s%s %s%s%s  %s%s%s  %s%s%s\n' \
        "$PURP" "$G_BAR" "$RESET" "$WHITE" "${D_NAME[$j]}" "$RESET" \
        "$GRAY" "${D_DIR[$j]}" "$RESET" \
        "$GRAY" "${D_EP[$j]:-—}" "$RESET"
    done
    blank
    warn "新增实例不会改动它们；但若服务名相同会被覆盖"
    if [ -n "$ENDPOINT" ]; then
      dim "面板地址将沿用：$ENDPOINT（下一步直接回车即可）"
    fi
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
  load_conf
  discover_instances
  detect_init >/dev/null

  if [ "$D_COUNT" -eq 0 ]; then
    warn "没有发现已安装的 komari-agent（$(init_label "$INIT_SYS")）"
    return 0
  fi

  printf '\n  %s%s%s %s实例状态%s %s(%s 个 · %s)%s\n' \
    "$PURP" "$G_BAR" "$RESET" "$B" "$RESET" "$GRAY" "$D_COUNT" "$(init_label "$INIT_SYS")" "$RESET"
  rule 66
  local i act col dot tag note tail_txt
  for ((i = 0; i < D_COUNT; i++)); do
    act="$(svc_state "${D_NAME[$i]}" "${D_KIND[$i]}")"
    case "$act" in
      active)   col="$GREEN"; dot="$G_DOT";     tag="运行中" ;;
      failed)   col="$RED";   dot="$G_ERR";     tag="失败" ;;
      inactive) col="$GRAY";  dot="$G_DOT_OFF"; tag="已停止" ;;
      *)        col="$YELL";  dot="$G_DOT_OFF"; tag="$act" ;;
    esac
    note="$(meta_get "${D_NAME[$i]}")"
    tail_txt="${D_EP[$i]:-—}"
    [ -n "$note" ] && tail_txt="$note · $tail_txt"
    printf '  %s%s%s %s%s%s  %s%s%s  %s%s%s  %s%s%s\n' \
      "$col" "$dot" "$RESET" \
      "$WHITE" "${D_NAME[$i]}" "$RESET" \
      "$CYAN" "${D_TAG[$i]}" "$RESET" \
      "$col" "$tag" "$RESET" \
      "$GRAY" "$tail_txt" "$RESET"
  done
  rule 66
  local conns="未知"
  if command -v ss >/dev/null 2>&1; then
    conns="$(ss -tnp 2>/dev/null | grep -c 'komari')"
  fi
  printf '  %s共 %s 个 · 面板连接 %s 条 · 受管 %s 个%s\n\n' \
    "$GRAY" "$D_COUNT" "$conns" "$(count_managed)" "$RESET"
}

cmd_doctor() {
  load_conf
  discover_instances
  detect_init >/dev/null
  if [ "$D_COUNT" -eq 0 ]; then
    warn "没有发现实例；先 ka install"
    return 0
  fi
  printf '\n  %s%s%s %s自检%s\n' "$PURP" "$G_BAR" "$RESET" "$B" "$RESET"
  rule 60
  local i act okc=0 code en
  for ((i = 0; i < D_COUNT; i++)); do
    act="$(svc_state "${D_NAME[$i]}" "${D_KIND[$i]}")"
    en="$(svc_enabled "${D_NAME[$i]}" "${D_KIND[$i]}")"
    if [ "$act" = "active" ]; then
      printf '  %s%s%s %s  服务运行中\n' "$GREEN" "$G_OK" "$RESET" "${D_NAME[$i]}"
      okc=$((okc + 1))
    else
      printf '  %s%s%s %s  服务未运行（%s）\n' "$RED" "$G_ERR" "$RESET" "${D_NAME[$i]}" "$act"
    fi
    if [ "$en" = "disabled" ]; then
      printf '  %s%s%s %s  未设置开机自启（重启后不会自动拉起）\n' "$YELL" "$G_WARN" "$RESET" "  "
    fi
    if [ -n "${D_EP[$i]}" ]; then
      code="$(curl -o /dev/null -sS -k -w '%{http_code}' --max-time 6 "${D_EP[$i]}" 2>/dev/null || printf '000')"
      if [ "$code" = "000" ]; then
        printf '  %s%s%s %s  面板连不上 %s\n' "$YELL" "$G_WARN" "$RESET" "  " "${D_EP[$i]}"
      else
        printf '  %s%s%s %s  面板可达 HTTP %s\n' "$GREEN" "$G_OK" "$RESET" "  " "$code"
      fi
    fi
  done
  rule 60
  printf '  %s%d/%d 个实例在运行%s\n\n' "$GRAY" "$okc" "$D_COUNT" "$RESET"
}

state_cn() {
  case "$1" in
    active)   printf '运行中' ;;
    inactive) printf '已停止' ;;
    failed)   printf '失败' ;;
    '')       printf '未知' ;;
    *)        printf '%s' "$1" ;;
  esac
}

cmd_instances() {
  load_conf
  while :; do
    discover_instances
    if [ "$D_COUNT" -eq 0 ]; then
      warn "没有发现已安装的 komari-agent"
      return 0
    fi
    local -a items=()
    local i st note line
    for ((i = 0; i < D_COUNT; i++)); do
      st="$(svc_state "${D_NAME[$i]}" "${D_KIND[$i]}")"
      note="$(meta_get "${D_NAME[$i]}")"
      line="${D_NAME[$i]} · ${D_TAG[$i]} · $(state_cn "$st")"
      if [ -n "$note" ]; then line+=" · $note"; fi
      items+=("$line")
    done
    pick "实例管理" "共 ${D_COUNT} 个 · Enter 进入 · q 返回" "${items[@]}" || return 0
    cmd_instance_actions "$PICK_RESULT"
  done
}

cmd_instance_actions() {
  local idx="$1"
  local n="${D_NAME[$idx]}" k="${D_KIND[$idx]}"
  local st st_cn col dot en note title sub action
  st="$(svc_state "$n" "$k")"
  st_cn="$(state_cn "$st")"
  col="$YELL"; dot="$G_DOT_OFF"
  case "$st" in
    active)   col="$GREEN"; dot="$G_DOT" ;;
    inactive) col="$GRAY" ;;
    failed)   col="$RED"; dot="$G_ERR" ;;
  esac
  en="$(svc_enabled "$n" "$k")"
  note="$(meta_get "$n")"
  title="$n  ${col}${dot} ${st_cn}${RESET}"
  sub="类型 $k · 自启 $en"
  if [ -n "$note" ]; then sub+=" · 备注 $note"; fi
  sub+=$'\n'"目录 ${D_DIR[$idx]}"
  sub+=$'\n'"面板 ${D_EP[$idx]:-—}"
  sub+=$'\n'"Token $(mask "${D_TK[$idx]:-}")"

  local -a acts=() labels=()
  if [ "$k" = "proc" ]; then
    acts+=(cmdline); labels+=("查看命令行")
    acts+=(stop);    labels+=("停止进程")
  else
    acts+=(log);     labels+=("查看日志 · 最近 100 行")
    acts+=(restart); labels+=("重启服务")
    if [ "$st" = "active" ]; then
      acts+=(stop);  labels+=("停止服务")
    else
      acts+=(start); labels+=("启动服务")
    fi
    acts+=(params); labels+=("修改参数 · 采集 / 开关 / 网络")
    if [ "${D_TAG[$idx]}" = "受管" ]; then
      acts+=(upgrade); labels+=("升级 Agent · 沿用现有参数")
    fi
  fi
  if [ "${D_TAG[$idx]}" != "受管" ] || [ "$k" = "proc" ]; then
    acts+=(adopt); labels+=("接管为 ka 管理 · 保留 token")
  fi
  acts+=(note);      labels+=("设置备注 · 地区 / 用途")
  acts+=(sep);       labels+=("──")
  acts+=(uninstall); labels+=("${RED}卸载${RESET}")

  pick "$title" "$sub" "${labels[@]}" || return 0
  action="${acts[$PICK_RESULT]}"

  case "$action" in
    cmdline)
      printf '\n  %s\n\n' "$(tr '\0' ' ' < "/proc/${n#pid-}/cmdline" 2>/dev/null)"
      pause_any ;;
    log)
      printf '\n'
      if ! svc_logs "$n" "$k" 100; then warn "没有可读日志"; fi
      pause_any ;;
    restart) svc_ctl restart "$n" "$k" && ok "已重启 $n" || warn "重启失败" ;;
    stop)    svc_ctl stop "$n" "$k" && ok "已停止 $n" || warn "停止失败" ;;
    start)   svc_ctl start "$n" "$k" && ok "已启动 $n" || warn "启动失败" ;;
    params)  cmd_edit_params "$idx" ;;
    upgrade) cmd_upgrade "$n" ;;
    adopt)   cmd_adopt "$n" ;;
    note)    cmd_note "$n" ;;
    uninstall) remove_index "$idx" ;;
  esac
}

cmd_note() {
  load_conf
  discover_instances
  if [ "$D_COUNT" -eq 0 ]; then warn "没有发现实例"; return 0; fi
  local idx
  if [ $# -ge 1 ] && [ -n "$1" ]; then
    idx="$(find_idx "$1")" || { warn "找不到实例 $1"; return 1; }
    if [ $# -ge 2 ]; then
      meta_set "$1" "$2" && ok "备注已保存"
      return 0
    fi
  else
    local -a items=()
    local i
    for ((i = 0; i < D_COUNT; i++)); do
      items+=("${D_NAME[$i]} · $(meta_get "${D_NAME[$i]}")")
    done
    pick "设置备注" "地区 / 用途，留空清除" "${items[@]}" || return 0
    idx="$PICK_RESULT"
  fi
  local name="${D_NAME[$idx]}" old note def
  old="$(meta_get "$name")"
  def="$old"
  if [ -z "$old" ] && [ "${KA_NO_GEO:-0}" != "1" ]; then
    info "识别出口 IP 归属地…"
    geo_note
    if [ -n "$GEO_RESULT" ]; then
      dim "公网 IP ${GEO_IP} → ${GEO_RESULT}"
      def="$GEO_RESULT"
    else
      warn "识别失败（网络受限？），手动填写即可"
    fi
  fi
  ask "备注（地区 / 用途，输入 - 清空）" "$def" note
  if [ "$note" = "-" ]; then note=""; fi
  meta_set "$name" "$note" && ok "$name 备注 → ${note:-（空）}"
}

reset_settings() {
  INTERVAL="1.0"
  INFO_INTERVAL="5"
  DISABLE_WEBSSH=0
  DISABLE_AUTOUPDATE=0
  MEM_CACHE=0
  GET_IP_NIC=0
  INSECURE=0
  GPU_MONITOR=0
  INCLUDE_NICS=""
  EXCLUDE_NICS=""
  MOUNT_POINTS=""
  MONTH_ROTATE="0"
  EXTRA_AGENT=""
}

load_settings_from_args() {
  reset_settings
  local -a av=($1)
  local i a
  for ((i = 0; i < ${#av[@]}; i++)); do
    a="${av[$i]}"
    case "$a" in
      -e|--endpoint|-t|--token) i=$((i + 1)) ;;
      -i|--interval)            INTERVAL="${av[$((i + 1))]:-1.0}"; i=$((i + 1)) ;;
      --info-report-interval)   INFO_INTERVAL="${av[$((i + 1))]:-5}"; i=$((i + 1)) ;;
      --include-nics)           INCLUDE_NICS="${av[$((i + 1))]:-}"; i=$((i + 1)) ;;
      --exclude-nics)           EXCLUDE_NICS="${av[$((i + 1))]:-}"; i=$((i + 1)) ;;
      --include-mountpoint)     MOUNT_POINTS="${av[$((i + 1))]:-}"; i=$((i + 1)) ;;
      --month-rotate)           MONTH_ROTATE="${av[$((i + 1))]:-0}"; i=$((i + 1)) ;;
      --disable-web-ssh)        DISABLE_WEBSSH=1 ;;
      --disable-auto-update)    DISABLE_AUTOUPDATE=1 ;;
      -u|--ignore-unsafe-cert)  INSECURE=1 ;;
      --gpu)                    GPU_MONITOR=1 ;;
      --memory-include-cache)   MEM_CACHE=1 ;;
      --get-ip-addr-from-nic)   GET_IP_NIC=1 ;;
      --memory-mode-available)  : ;;
      *) EXTRA_AGENT="${EXTRA_AGENT:+$EXTRA_AGENT }$a" ;;
    esac
  done
}

cmd_edit_params() {
  local idx="$1"
  local n="${D_NAME[$idx]}" dir="${D_DIR[$idx]}"
  local k="${D_KIND[$idx]}" ep="${D_EP[$idx]:-}" tk="${D_TK[$idx]:-}"
  if [ -z "$tk" ]; then
    warn "解析不到 $n 的 token，无法修改参数"
    return 1
  fi
  if [ -z "$ep" ]; then
    warn "解析不到 $n 的面板地址，无法修改参数"
    return 1
  fi

  load_settings_from_args "${D_ARGS[$idx]:-}"
  ENDPOINT="$ep"

  ADV_MORE_DRAW="inst_draw2"
  ADV_MORE_EDIT="inst_edit2"
  ADV_MORE_N=6
  if [ "$UI_TUI" -eq 1 ]; then
    adv_run "修改参数" "$n · Esc 取消" adv_draw1 adv_edit1 10
  else
    step_advanced_plain
  fi
  ADV_MORE_DRAW="adv_draw2"
  ADV_MORE_EDIT="adv_edit2"
  ADV_MORE_N=8

  build_args
  blank
  panel_row "服务" "$n"
  panel_row "目录" "$dir"
  dim "新参数: ${ARGS[*]}"
  blank
  local go
  ask "应用并重启服务? (y/N)" "N" go
  case "$go" in [Yy]*) ;; *) warn "已取消"; return 0 ;; esac

  fetch_installer || die "下载安装脚本失败"
  info "停止 $n"
  svc_ctl stop "$n" "$k" || true
  if bash "$KA_TMP" "${ARGS[@]}" \
       --install-dir "$dir" --install-service-name "$n" -t "$tk" </dev/null; then
    enable_start "$n" "$k"
    ok "$n 参数已更新并重启"
  else
    err "更新失败，尝试恢复"
    svc_ctl start "$n" "$k" || true
    return 1
  fi
}

cmd_cleanup() {
  local -a items=("卸载实例 · 停服务并删除目录" "卸载 ka 自身 · 保留实例" "返回")
  pick "卸载 / 清理" "两件事不一样，别选错" "${items[@]}" || return 0
  case "$PICK_RESULT" in
    0) cmd_uninstall ;;
    1) cmd_self_uninstall ;;
  esac
}

cmd_self_uninstall() {
  need_root
  warn "将删除 ka 自身：$KA_SELF"
  dim "同时清理 /usr/local/bin/ka、$KA_CONF、$META_FILE"
  dim "不会动任何 komari-agent 实例"
  local go
  ask "确认? (y/N)" "N" go
  case "$go" in [Yy]*) ;; *) warn "已取消"; return 0 ;; esac

  rm -f /usr/local/bin/ka 2>/dev/null
  rm -f "$KA_CONF" 2>/dev/null
  rm -f "$META_FILE" 2>/dev/null
  case "$KA_DIR" in
    /opt/ka|/opt/ka/*) rm -rf "$KA_DIR" ;;
    *)
      rm -f "$KA_DIR"/ka "$KA_DIR"/ka.sh 2>/dev/null
      rm -f "$KA_DIR"/ka-v*.sh 2>/dev/null
      ;;
  esac
  ok "ka 已卸载；实例仍在运行，可随时用面板重新接管"
}

cmd_batch() {
  need_root
  load_conf
  discover_instances
  if [ "$D_COUNT" -eq 0 ]; then warn "没有发现实例"; return 0; fi
  local i total=0
  for ((i = 0; i < D_COUNT; i++)); do
    if [ "${D_KIND[$i]}" != "proc" ]; then total=$((total + 1)); fi
  done
  if [ "$total" -eq 0 ]; then warn "没有可批量操作的服务实例"; return 0; fi
  local -a items=("全部重启" "全部停止" "全部启动")
  pick "批量操作" "对 ${total} 个服务实例执行（不含裸进程）" "${items[@]}" || return 0
  local act
  case "$PICK_RESULT" in
    0) act="restart" ;;
    1) act="stop" ;;
    2) act="start" ;;
  esac
  local go
  ask "确认对 ${total} 个服务执行 $act? (y/N)" "N" go
  case "$go" in [Yy]*) ;; *) warn "已取消"; return 0 ;; esac
  local okc=0
  for ((i = 0; i < D_COUNT; i++)); do
    if [ "${D_KIND[$i]}" = "proc" ]; then continue; fi
    if svc_ctl "$act" "${D_NAME[$i]}" "${D_KIND[$i]}"; then
      ok "${D_NAME[$i]} $act"
      okc=$((okc + 1))
    else
      warn "${D_NAME[$i]} $act 失败"
    fi
  done
  blank
  printf '  %s%d/%d 成功%s\n\n' "$GRAY" "$okc" "$total" "$RESET"
}

cmd_adopt() {
  need_root
  load_conf
  discover_instances
  detect_init >/dev/null
  if [ "$D_COUNT" -eq 0 ]; then warn "没有发现实例"; return 0; fi

  local idx
  if [ $# -ge 1 ] && [ -n "$1" ]; then
    idx="$(find_idx "$1")" || { warn "找不到实例 $1"; return 1; }
  else
    local -a items=()
    local i
    for ((i = 0; i < D_COUNT; i++)); do
      items+=("${D_NAME[$i]} · ${D_TAG[$i]} · $(svc_state "${D_NAME[$i]}" "${D_KIND[$i]}")")
    done
    pick "接管实例" "把外部 / 进程实例重装成 ka 管理的服务" "${items[@]}" || return 0
    idx="$PICK_RESULT"
  fi

  local on="${D_NAME[$idx]}" ok="${D_KIND[$idx]}" odir="${D_DIR[$idx]}"
  local ep="${D_EP[$idx]:-}" tk="${D_TK[$idx]:-}" raw="${D_ARGS[$idx]:-}"

  if [ -z "$tk" ]; then
    warn "解析不到 $on 的 token，无法自动接管"
    dim "可到面板复制该节点 token 后手动重装"
    return 1
  fi

  local nn nd n=1
  if [ "$on" = "$SVC_PREFIX" ]; then
    nn="$SVC_PREFIX"; nd="$odir"
  elif ! service_name_taken "$SVC_PREFIX"; then
    nn="$SVC_PREFIX"; nd="$BASE_DIR"
  else
    while [ "$n" -lt 100 ] && service_name_taken "${SVC_PREFIX}-${n}"; do
      n=$((n + 1))
    done
    nn="${SVC_PREFIX}-${n}"; nd="$BASE_DIR/nat$n"
  fi

  local extra
  extra="$(filter_args "$raw")"

  blank
  printf '  %s%s%s %s接管计划%s\n' "$PURP" "$G_BAR" "$RESET" "$B" "$RESET"
  panel_row "旧服务" "$on（$ok）"
  panel_row "新服务" "$nn"
  panel_row "新目录" "$nd"
  panel_row "面板" "${ep:-—}"
  panel_row "Token" "$(mask "$tk")"
  if [ -n "$extra" ]; then panel_row "保留参数" "$extra"; fi
  blank
  warn "先停旧服务再重装，期间约 10 秒离线"
  local go
  ask "确认接管? (y/N)" "N" go
  case "$go" in [Yy]*) ;; *) warn "已取消"; return 0 ;; esac

  fetch_installer || die "下载安装脚本失败"

  info "停止旧服务 $on"
  svc_ctl stop "$on" "$ok" || true

  if reinstall_service "$nd" "$nn" "$ep" "$tk" "$extra"; then
    enable_start "$nn" "$INIT_SYS"
    if [ "$on" != "$nn" ]; then
      purge_service "$on" "$ok"
      ok "旧服务 $on 已移除"
      if [ "$odir" != "$nd" ]; then
        dim "旧目录 $odir 保留未删"
      fi
    fi
    ok "接管完成 → $nn"
  else
    err "接管失败，正在回滚"
    svc_ctl start "$on" "$ok" || true
    return 1
  fi
}

cmd_upgrade() {
  need_root
  load_conf
  discover_instances
  detect_init >/dev/null
  if [ "$D_COUNT" -eq 0 ]; then warn "没有发现实例"; return 0; fi

  local -a cand=()
  local i
  if [ $# -ge 1 ] && [ -n "$1" ] && [ "$1" != "all" ]; then
    local one
    one="$(find_idx "$1")" || { warn "找不到实例 $1"; return 1; }
    cand=("$one")
  else
    for ((i = 0; i < D_COUNT; i++)); do cand+=("$i"); done
  fi

  local -a todo=()
  for i in "${cand[@]}"; do
    if [ "${D_TAG[$i]}" != "受管" ]; then
      warn "${D_NAME[$i]} 是外部实例，先「接管」再升级"
      continue
    fi
    if [ -z "${D_TK[$i]}" ] || [ -z "${D_EP[$i]}" ]; then
      warn "${D_NAME[$i]} 缺少面板地址或 token，跳过"
      continue
    fi
    todo+=("$i")
  done
  if [ "${#todo[@]}" -eq 0 ]; then return 0; fi

  blank
  for i in "${todo[@]}"; do
    printf '  %s%s%s %s\n' "$GRAY" "$G_ARROW" "$RESET" "${D_NAME[$i]}"
  done
  local go
  ask "升级以上 ${#todo[@]} 个实例? (y/N)" "N" go
  case "$go" in [Yy]*) ;; *) warn "已取消"; return 0 ;; esac

  fetch_installer || die "下载安装脚本失败"
  local okc=0
  for i in "${todo[@]}"; do
    local n="${D_NAME[$i]}" k="${D_KIND[$i]}" dir="${D_DIR[$i]}"
    local ep="${D_EP[$i]}" tk="${D_TK[$i]}" extra
    extra="$(filter_args "${D_ARGS[$i]:-}")"
    info "升级 $n"
    svc_ctl stop "$n" "$k" || true
    if reinstall_service "$dir" "$n" "$ep" "$tk" "$extra"; then
      enable_start "$n" "$k"
      ok "$n 已升级"
      okc=$((okc + 1))
    else
      err "$n 升级失败，尝试恢复"
      svc_ctl start "$n" "$k" || true
    fi
  done
  blank
  printf '  %s%d/%d 成功%s\n\n' "$GRAY" "$okc" "${#todo[@]}" "$RESET"
}

cmd_logs() {
  load_conf
  local id="${1:-1}" lines="${2:-80}"
  discover_instances
  if [ "$D_COUNT" -eq 0 ]; then die "没有安装任何实例"; fi

  local -a names=()
  local i
  for ((i = 0; i < D_COUNT; i++)); do names+=("${D_NAME[$i]}"); done

  local targets=()
  case "$id" in
    all)
      for ((i = 0; i < D_COUNT; i++)); do targets+=("$i"); done ;;
    *[!0-9]*)
      for ((i = 0; i < D_COUNT; i++)); do
        if [ "${D_NAME[$i]}" = "$id" ]; then targets+=("$i"); break; fi
      done
      [ "${#targets[@]}" -eq 0 ] && die "找不到实例 $id" ;;
    *)
      local idx=$((id - 1))
      if [ "$idx" -lt 0 ] || [ "$idx" -ge "$D_COUNT" ]; then die "编号超出范围"; fi
      targets=("$idx") ;;
  esac

  for i in "${targets[@]}"; do
    svc_logs "${D_NAME[$i]}" "${D_KIND[$i]}" "$lines" || warn "${D_NAME[$i]} 没有可读日志"
  done
}

cmd_uninstall() {
  need_root
  load_conf
  discover_instances
  if [ "$D_COUNT" -eq 0 ]; then warn "没有可卸载的实例"; return 0; fi

  local -a items=()
  local i
  for ((i = 0; i < D_COUNT; i++)); do
    items+=("${D_NAME[$i]}  [${D_TAG[$i]}]")
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
      remove_index "$i" 1
    done
  else
    remove_index "$PICK_RESULT"
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
  panel_row "初始化"   "$(init_label "$(detect_init)")"
  local style_text
  if [ "$KA_BUMP_STYLE" = "patch" ]; then
    style_text="patch（每次 +0.0.1）"
  else
    style_text="minor（每次 +0.1）"
  fi
  panel_row "版本规则" "$style_text"
  blank
  printf '  %s%s%s %s归档版本%s\n' "$PURP" "$G_BAR" "$RESET" "$B" "$RESET"
  rule 52
  local f found=0
  for f in "$KA_DIR"/ka-v*.sh; do
    [ -e "$f" ] || continue
    printf '   %s%s%s %s\n' "$GRAY" "$G_ARROW" "$RESET" "$(basename "$f")"
    found=1
  done
  if [ "$found" -eq 0 ]; then
    dim "（无）"
    dim "提示：当前 ka 像是手动拷贝的，运行 ka self-install 可启用版本归档"
  fi
  blank
}

cmd_help() {
  banner
  cat <<EOF
  ${B}安装${RESET}
    ka                    主菜单（↑↓ 选择）
    ka install            直接进入安装向导

  ${B}管理${RESET}
    ka status             实例状态（systemd / OpenRC 都认）
    ka doctor             一键自检（服务 / 自启 / 面板连通）
    ka adopt [名字]       接管外部实例（保留 token，重装为 ka 管理）
    ka upgrade [all|名字]  原地升级 Agent（沿用现有参数）
    ka batch              批量重启 / 停止 / 启动
    ka note [名字] [备注]  设置实例备注（地区/用途）
    ka logs <n|name|all>  查看日志，默认 80 行

  ${B}清理${RESET}
    ka uninstall          卸载实例（停服务 + 删目录）
    ka self-uninstall     卸载 ka 自身（保留实例）

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
    detect_init >/dev/null
    if [ "$D_COUNT" -eq 0 ]; then
      sub="v$KA_VERSION · $(init_label "$INIT_SYS") · 未发现实例"
    else
      sub="v$KA_VERSION · $(init_label "$INIT_SYS") · 已发现 ${D_COUNT} 个实例"
    fi
    items=("安装 / 新增实例" "实例管理" "批量操作" "自检" "卸载 / 清理" "退出")
    pick "主菜单" "$sub" "${items[@]}" || return 0
    case "$PICK_RESULT" in
      0) cmd_wizard; pause_any ;;
      1) cmd_instances; pause_any ;;
      2) cmd_batch; pause_any ;;
      3) cmd_doctor; pause_any ;;
      4) cmd_cleanup; pause_any ;;
      5) return 0 ;;
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
    doctor|check)         cmd_doctor ;;
    adopt)                cmd_adopt "$@" ;;
    upgrade)              cmd_upgrade "$@" ;;
    batch)                cmd_batch ;;
    note)                 cmd_note "$@" ;;
    logs)                 cmd_logs "$@" ;;
    uninstall|remove)     cmd_uninstall ;;
    cleanup)              cmd_cleanup ;;
    self-uninstall)       cmd_self_uninstall ;;
    version|-v|--version) cmd_version ;;
    bump)                 cmd_bump ;;
    self-install)         cmd_self_install "$@" ;;
    help|-h|--help)       cmd_help ;;
    *) err "未知命令: $cmd"; cmd_help; exit 1 ;;
  esac
}

main "$@"
