#!/bin/sh
# fip-v0.1.sh — 给本机绑一个「指定归属地」的 IP，并让探针只上报它
#
# 单文件、无依赖，可单独拷贝到每台机器执行。UI 与 kp.sh 保持同一套风格。
#
# 版本规则：每次改动 +0.1，文件名跟着走（fip-v0.1.sh → fip-v0.2.sh）。
#
# 直接运行进交互菜单：
#   fip
#
# 命令行：
#   fip on [IP]               启用（自动分配唯一 IPv6，或指定地址）
#   fip 2a12:bec0:160::5      启用（指定地址，IPv4 / IPv6 都行）
#   fip kp4|kp6|cf4|cf6       内置快捷地址
#   fip ip [名字]             只算出地址并打印，不改系统
#   fip status                查看状态
#   fip off                   删网卡、还原探针配置、清开机自启
#   fip menu                  强制进入交互菜单
#   fip help / fip version
#
# 母机侧（集中造一个假的地址池，把地址分给各 NAT 小鸡）：
#   fip pool init [前缀]      建立地址池账本
#   fip pool add <名字> [IP]  给一台小鸡分配地址（不给 IP 就顺序取下一个）
#   fip pool list             列出 名字 -> 地址
#   fip pool cmd [名字]       输出该台要执行的命令（不给名字就输出全部）
#   fip pool del <名字>       释放
# 小鸡侧跑 fip <母机分来的 IP>：建假网卡绑这个地址，探针只上报它。
#
# 地址格式：
#   默认前缀 2606:54c1:1:c4（Cloudflare 官方 geofeed 标 KP 的 /64）
#   自动分配的 /128 一律输出**完整 8 段、不用 :: 简写**，例如
#     2606:54c1:1:c4:0:28c8:de8c:add4
#   每台机器地址由「主机名 + /etc/machine-id」哈希得到，各不相同，重启不变。
#
# 环境变量：
#   FIP_PREFIX6=2606:54c1:1:c4  /64 或 /48 前缀（不带 :: 和掩码）
#   FIP_SEED=名字               覆盖自动分配的种子（同名 => 同地址）
#   FIP_DEV=fip0                虚拟网卡名
#   FIP_PROBE=nezha|komari      强制探针种类
#   FIP_MENU=0                  无参数时不进菜单，直接启用（脚本里用）
#   FIP_COLOR=0                 关掉颜色
#   FIP_CONF / FIP_UP / ...     覆盖各文件路径（测试用）
#
# 限制（重要）：
#   * 只改 agent 上报的地址，IP 不可达、不参与路由、不出网。
#   * 面板若按 gRPC / WebSocket 连接来源 IP 查 GeoIP，仍显示真实出口归属地。
#   * 2a12:bec0:160::/48 是 AS212336 真实在网宣告的段（别人家的），
#     ipinfo / ipwho.is 标为 KP，MaxMind 系标为 GB —— 结果看面板用哪个库。
#   * 母机 NAT 改的是「出口源地址」，改不了小鸡本地网卡的地址；
#     伪造 IP 直接当出口源还会因上游没路由而失联。所以本脚本在每台本机跑。
set -u

VERSION="0.1"

# 内置快捷地址（全部写成完整 8 段，方便和自动分配的结果对照）
IP_KP4="31.6.16.15"                       # ipinfo: KP / Pyongyang
IP_KP6="2a12:bec0:160:0:0:0:1"            # 部分 GeoIP 库标 KP
IP_CF4="104.29.195.20"                    # Cloudflare geofeed: KP / Pyongyang
IP_CF6="2606:54c1:1:c4:0:0:0:1"           # 同上，整 /64 都是 KP

P6="${FIP_PREFIX6:-2606:54c1:1:c4}"
# 前缀允许写成 2606:54c1:1:c4 或 2606:54c1:1:c4/64：去掉掩码和尾部冒号
P6="${P6%%/*}"
while [ "${P6%:}" != "$P6" ]; do P6="${P6%:}"; done
[ -n "$P6" ] || P6="2606:54c1:1:c4"

DEV="${FIP_DEV:-fip0}"
PROBE_FORCE="${FIP_PROBE:-auto}"
SEED="${FIP_SEED:-}"
CONF="${FIP_CONF:-/etc/fip.conf}"
UPS="${FIP_UP:-/usr/local/sbin/fip-up}"
LOCALD="${FIP_LOCAL:-/etc/local.d/fip.start}"
UNIT="${FIP_UNIT:-/etc/systemd/system/fip.service}"
RCF="${FIP_RC:-/etc/rc.local}"
BAK="${FIP_BAK:-/etc/fip.probe.bak}"
DROPIN="${FIP_DROPIN:-/etc/systemd/system/komari-agent.service.d/fip.conf}"
KCF="${FIP_KOMARI_CONF:-/etc/conf.d/komari-agent}"
POOL="${FIP_POOL:-/etc/fip-pool}"

# ── 颜色 ────────────────────────────────────────────────
# 优先用 256 色（更细腻），终端不支持则回落基本 16 色。
# 判定：COLORTERM 含 truecolor/24bit，或 TERM 含 256color。
ESC="$(printf '\033')"
USE256=0
if [ -t 1 ] && [ "${FIP_COLOR:-auto}" != "0" ] && [ "${NO_COLOR:-}" = "" ]; then
  case "${COLORTERM:-}:${TERM:-}" in
    *truecolor*|*24bit*|*256color*) USE256=1 ;;
  esac
fi

if [ -t 1 ] && [ "${FIP_COLOR:-auto}" != "0" ] && [ "${NO_COLOR:-}" = "" ]; then
  # 基本属性
  RST=$(printf '\033[0m'); BOLD=$(printf '\033[1m'); HDIM=$(printf '\033[2m')
  ITAL=$(printf '\033[3m'); UNDL=$(printf '\033[4m')
  # 基本 16 色
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m')
  BLU=$(printf '\033[34m'); MAG=$(printf '\033[35m'); CYN=$(printf '\033[36m')
  GRY=$(printf '\033[37m'); GRA=$(printf '\033[90m')
  BRED=$(printf '\033[91m'); BGRN=$(printf '\033[92m'); BYEL=$(printf '\033[93m')
  BBLU=$(printf '\033[94m'); BMAG=$(printf '\033[95m'); BCYN=$(printf '\033[96m')
  BOLD_W=$(printf '\033[1;37m')
  BOLD_MAG=$(printf '\033[1;35m'); BOLD_CYN=$(printf '\033[1;36m')
  if [ "$USE256" = "1" ]; then
    ORNG=$(printf '\033[38;5;208m')        # 橙
    ORNG_B=$(printf '\033[1;38;5;214m')    # 亮橙
    VIO=$(printf '\033[38;5;141m')         # 紫罗兰
    VIO_B=$(printf '\033[1;38;5;141m')
    TEAL=$(printf '\033[38;5;51m')         # 青
    TEAL_B=$(printf '\033[1;38;5;45m')
    PINK=$(printf '\033[38;5;205m')        # 粉
    PINK_B=$(printf '\033[1;38;5;213m')
    LIME=$(printf '\033[38;5;118m')        # 柠檬绿
    LIME_B=$(printf '\033[1;38;5;119m')
    SKY=$(printf '\033[38;5;117m')         # 天蓝
    SKY_B=$(printf '\033[1;38;5;117m')
    BORD=$(printf '\033[38;5;99m')         # 边框紫
    BORD2=$(printf '\033[38;5;63m')        # 边框蓝紫
  else
    ORNG="$YEL"; ORNG_B="$BOLD_MAG"; VIO="$MAG"; VIO_B="$BOLD_MAG"
    TEAL="$CYN"; TEAL_B="$BOLD_CYN"; PINK="$MAG"; PINK_B="$BOLD_MAG"
    LIME="$GRN"; LIME_B="$BOLD"; SKY="$CYN"; SKY_B="$BOLD_CYN"
    BORD="$MAG"; BORD2="$BLU"
  fi
else
  RST=""; BOLD=""; HDIM=""; ITAL=""; UNDL=""
  RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; GRY=""; GRA=""
  BRED=""; BGRN=""; BYEL=""; BBLU=""; BMAG=""; BCYN=""; BOLD_W=""
  BOLD_MAG=""; BOLD_CYN=""
  ORNG=""; ORNG_B=""; VIO=""; VIO_B=""; TEAL=""; TEAL_B=""; PINK=""; PINK_B=""
  LIME=""; LIME_B=""; SKY=""; SKY_B=""; BORD=""; BORD2=""
fi

# ── 输出小工具 ──────────────────────────────────────────
# 分隔线长度：优先读 COLUMNS，其次 stty，最后回落 46；夹在 40~72
TERMW="${COLUMNS:-}"
if [ -z "$TERMW" ] || [ "$TERMW" -eq 0 ] 2>/dev/null; then
  TERMW=$(stty size 2>/dev/null | awk '{print $2}')
fi
case "$TERMW" in ''|*[!0-9]*) TERMW=46 ;; esac
[ "$TERMW" -lt 40 ] 2>/dev/null && TERMW=40
[ "$TERMW" -gt 72 ] 2>/dev/null && TERMW=72

# 用循环拼分隔线：避免 tr 在多字节字符上的编码问题
LINE=""
i=0
while [ "$i" -lt "$TERMW" ]; do LINE="$LINE─"; i=$((i + 1)); done

# 渐变色分隔线（256 色下更像一条彩虹）
grad_line() {
  if [ "$USE256" != "1" ]; then printf '%s%s%s' "$BOLD_CYN" "$LINE" "$RST"; return; fi
  n=0; out=""
  i=0
  while [ "$i" -lt "$TERMW" ]; do
    n=$(( 33 + (i * 60 / TERMW) ))       # 33 → 93，蓝到紫的渐变
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

# 菜单项：序号用亮色徽章，文字用灰色说明
item()  { printf '   %s▸%s  %s%s%s%s   %s%s%s\n' \
            "$PINK_B" "$RST" "$BOLD_W" "$1" "$RST" "$RST" "$GRY" "$2" "$RST"; }

res()   { printf '%s%s%s\n' "$2" "$1" "$RST"; }

# 键值行：键右对齐到 18 列，值可带颜色
kv()    { printf '  %s%-18s%s %s\n' "$GRA" "$1" "$RST" "$2"; }
kvp()   { printf '  %s%-18s%s %s\n' "$GRA" "$1" "$RST" "$2"; }
kvn()   { printf '  %s%-18s%s '     "$GRA" "$1" "$RST"; }

# 标题小节（带前后装饰点）
sec()   { printf '\n   %s◆%s %s%s%s\n' "$ORNG_B" "$RST" "$BOLD" "$*" "$RST"; }

# 徽章：badge 文字 颜色
badge() { printf '%s %s %s' "$2" "$1" "$RST"; }

# 状态徽章：▐ 运行中 ▐
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

# ── 环境识别 ──────────────────────────────────────────────
# 判断本机能不能用 systemd 管服务。
# 容器（incus / LXC）里 /run/systemd/system 常常不存在，
# 所以不能只看目录或命令存在性 —— 必须确认 systemd 真的在跑。
have_systemd() {
  command -v systemctl >/dev/null 2>&1 || return 1
  if [ -r /proc/1/comm ] && grep -q '^systemd' /proc/1/comm 2>/dev/null; then
    return 0
  fi
  [ -d /run/systemd/system ] && return 0
  systemctl list-units >/dev/null 2>&1 && return 0
  return 1
}

init_kind() {
  if have_systemd; then printf 'systemd'; return; fi
  if [ -d /run/openrc ] || [ -e /sbin/openrc ] || command -v rc-service >/dev/null 2>&1; then
    printf 'openrc'; return
  fi
  if [ -d /etc/init.d ] && [ -n "$(ls /etc/init.d 2>/dev/null)" ]; then
    printf 'sysvinit'; return
  fi
  printf 'none'
}

ps_all() { ps ax 2>/dev/null || ps -ef 2>/dev/null || true; }

probe_kind() {
  case "$PROBE_FORCE" in
    nezha|komari) printf '%s' "$PROBE_FORCE"; return 0 ;;
  esac
  if ps_all | grep -v grep | grep -qi 'nezha-agent'; then
    printf 'nezha'; return 0
  fi
  if ps_all | grep -v grep | grep -qi 'komari'; then
    printf 'komari'; return 0
  fi
  if have_systemd; then
    systemctl list-unit-files 2>/dev/null | grep -q '^nezha-agent' && { printf 'nezha'; return; }
    systemctl list-unit-files 2>/dev/null | grep -q '^komari-agent' && { printf 'komari'; return; }
  fi
  [ -f /etc/init.d/nezha-agent ]  && { printf 'nezha';  return; }
  [ -f /etc/init.d/komari-agent ] && { printf 'komari'; return; }
  for f in /opt/nezha/agent/config.yml /etc/nezha/config.yml /opt/nezha/agent/config.yaml; do
    [ -f "$f" ] && { printf 'nezha'; return; }
  done
  printf 'komari'
}

# 探针进程在不在跑（只看进程，不碰网络）
probe_alive() {
  case "$1" in
    nezha)  ps_all | grep -v grep | grep -qi 'nezha-agent' ;;
    *)      ps_all | grep -v grep | grep -qi 'komari' ;;
  esac
}

nezha_conf() {
  for f in /opt/nezha/agent/config.yml /etc/nezha/config.yml /opt/nezha/agent/config.yaml; do
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  # 从进程命令行抠 -c 指定的路径
  _p="$(ps_all | grep -v grep | grep 'nezha-agent' | head -1)"
  if [ -n "$_p" ]; then
    _cf="$(printf '%s' "$_p" | grep -oE '\-c[= ][^ ]+\.ya?ml' | head -1 | sed -E 's/^-c[= ]//')"
    [ -n "$_cf" ] && [ -f "$_cf" ] && { printf '%s' "$_cf"; return 0; }
  fi
  printf ''
}

# ── IPv6 拼装：始终输出完整 8 段，不用 :: ─────────────────
# 前缀里有几段
prefix_groups() {
  _n=1; _s="$1"
  while :; do
    case "$_s" in *:*) _s="${_s#*:}"; _n=$(( _n + 1 )) ;; *) break ;; esac
  done
  printf '%s' "$_n"
}

# v6_addr <前缀> <g5> <g6> <g7> <g8>
# 前缀不足 4 段时右补 0（/48 -> /64），再拼 4 段尾巴，输出 8 段完整地址。
v6_addr() {
  _pfx="$1"
  _n="$(prefix_groups "$_pfx")"
  while [ "$_n" -lt 4 ]; do
    _pfx="$_pfx:0"
    _n=$(( _n + 1 ))
  done
  if [ "$_n" -gt 4 ]; then
    # 前缀比 /64 还长：只取前 4 段，保证结果仍是合法 8 段
    _s="$_pfx"; _out=""; _i=0
    while [ "$_i" -lt 4 ]; do
      case "$_s" in
        *:*) _g="${_s%%:*}"; _s="${_s#*:}" ;;
        *)   _g="$_s"; _s="" ;;
      esac
      if [ -z "$_out" ]; then _out="$_g"; else _out="$_out:$_g"; fi
      _i=$(( _i + 1 ))
    done
    _pfx="$_out"
  fi
  printf '%s:%x:%x:%x:%x\n' "$_pfx" "$2" "$3" "$4" "$5"
}

# 把任意字符串压成 0..65535 的稳定整数
hash16() {
  if command -v cksum >/dev/null 2>&1; then
    set -- $(printf '%s' "$1" | cksum 2>/dev/null)
    _v="${1:-1}"
    case "$_v" in ''|*[!0-9]*) _v=1 ;; esac
    printf '%s' "$(( _v % 65536 ))"
    return 0
  fi
  if command -v wc >/dev/null 2>&1; then
    _v="$(printf '%s' "$1" | wc -c | tr -d ' ')"
    case "$_v" in ''|*[!0-9]*) _v=1 ;; esac
    printf '%s' "$(( _v * 257 % 65536 ))"
    return 0
  fi
  printf '1'
}

# ── 自动分配：从 /64 里按名字算一个唯一且稳定的地址 ───────
addr_for() {
  _name="${1:-}"
  if [ -n "$_name" ]; then
    _seed="$_name"
  elif [ -n "$SEED" ]; then
    _seed="$SEED"
  else
    _seed="$(hostname 2>/dev/null || printf 'host')"
    _mid=""
    [ -r /etc/machine-id ] && IFS= read -r _mid < /etc/machine-id
    _seed="$_seed${_mid:-}"
  fi
  v6_addr "$P6" 0 \
    "$(hash16 "fip:5:$_seed")" \
    "$(hash16 "fip:6:$_seed")" \
    "$(hash16 "fip:7:$_seed")"
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
  case "$_ip" in *::*::*) return 1 ;; esac          # 最多一个 ::
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

mask_of() { case "$1" in *:*) printf '128' ;; *) printf '32' ;; esac }

need_root() {
  _u="$(id -u 2>/dev/null || printf '0')"
  [ "$_u" = "0" ] || warn "当前不是 root（uid=$_u）：建网卡 / 改探针配置很可能失败，建议 sudo 运行"
}

# ── 网卡 ──────────────────────────────────────────────────
link_up() {
  _ip="$1"; _mask="$2"
  _dev="$DEV"; _type=""
  if ip link show "$_dev" >/dev/null 2>&1; then
    _type="existing"
  elif ip link add "$_dev" type dummy 2>/dev/null; then
    _type="dummy"
  elif ip link add "$_dev" type veth peer name "${_dev}p" 2>/dev/null; then
    _type="veth"
  else
    _dev="lo"; _type="lo"
    warn "建不了虚拟网卡（多半缺 CAP_NET_ADMIN），改为绑到 lo"
  fi
  # scope global：探针扫 `ip addr show scope global` 才看得见
  if ! ip addr add "$_ip/$_mask" dev "$_dev" scope global 2>/dev/null; then
    if ! ip -o addr show dev "$_dev" 2>/dev/null | grep -qF " $_ip/$_mask "; then
      err "绑地址失败：$_ip/$_mask"
      case "$_type" in dummy|veth) ip link del "$DEV" 2>/dev/null ;; esac
      return 1
    fi
  fi
  ip link set "$_dev" up 2>/dev/null
  kvp "虚拟网卡" "$_dev（$_type）"
  kvp "绑定地址" "$_ip/$_mask"
  DEV_USED="$_dev"; TYPE="$_type"
  return 0
}

# ── 开机自启（自包含脚本，不依赖本脚本）────────────────────
write_up() {
  _ip="$1"; _mask="$2"; _dev="$3"
  mkdir -p "$(dirname "$UPS")" 2>/dev/null
  cat > "$UPS" <<EOF
#!/bin/sh
# FIP：重启后重建伪造 IP 网卡（自包含，不依赖 fip 脚本）
ip link show $_dev >/dev/null 2>&1 || {
  ip link add $_dev type dummy 2>/dev/null || \\
  ip link add $_dev type veth peer name ${_dev}p 2>/dev/null || exit 1
}
ip -o addr show dev $_dev 2>/dev/null | grep -qF ' $_ip/$_mask ' || \\
  ip addr add $_ip/$_mask dev $_dev scope global 2>/dev/null
ip link set $_dev up 2>/dev/null
exit 0
EOF
  if [ ! -s "$UPS" ]; then
    err "写 $UPS 失败（需要 root）"
    return 1
  fi
  chmod +x "$UPS" 2>/dev/null
  return 0
}

persist_on() {
  case "$(init_kind)" in
    openrc)
      mkdir -p "$(dirname "$LOCALD")" 2>/dev/null
      printf '#!/bin/sh\n# FIP\n%s\n' "$UPS" > "$LOCALD"
      chmod +x "$LOCALD" 2>/dev/null
      rc-update add local default >/dev/null 2>&1
      kvp "开机自启" "$LOCALD"
      ;;
    systemd)
      cat > "$UNIT" <<EOF
[Unit]
Description=FIP fake IP interface
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$UPS
[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload 2>/dev/null
      systemctl enable fip.service >/dev/null 2>&1
      kvp "开机自启" "$UNIT"
      ;;
    *)
      if [ -f "$RCF" ]; then
        cp -a "$RCF" "$RCF.fip.bak" 2>/dev/null
        awk -v cmd="$UPS" '
          /^[[:space:]]*exit([[:space:]]|$)/ && !d { print cmd; d=1 }
          { print }
          END { if (!d) print cmd }
        ' "$RCF" > "$RCF.tmp" 2>/dev/null && mv "$RCF.tmp" "$RCF"
        chmod +x "$RCF" 2>/dev/null
        kvp "开机自启" "$RCF"
      else
        warn "没识别出 init 系统，重启后需手动跑：$UPS"
      fi
      ;;
  esac
}

persist_off() {
  [ -f "$LOCALD" ] && { rm -f "$LOCALD"; ok "移除 $LOCALD"; }
  if [ -f "$UNIT" ]; then
    systemctl disable fip.service >/dev/null 2>&1
    rm -f "$UNIT"
    systemctl daemon-reload 2>/dev/null
    ok "移除 $UNIT"
  fi
  if [ -f "$RCF" ] && grep -qF "$UPS" "$RCF" 2>/dev/null; then
    grep -vF "$UPS" "$RCF" > "$RCF.tmp" 2>/dev/null && mv "$RCF.tmp" "$RCF"
    ok "清理 $RCF"
  fi
  [ -f "$UPS" ] && { rm -f "$UPS"; ok "移除 $UPS"; }
}

# ── 探针：只监控 fip0 ─────────────────────────────────────
# 全局记录，off 时据此还原
PROBE_KIND=""; PROBE_FILE=""; PROBE_BAK=""; PROBE_DROP=""

# 只删掉 nic_allowlist 里属于本网卡的那一项，其它条目原样保留
remove_allow() {
  awk -v dev="$2" '
    function flush() {
      if (n > 0) { print hdr; for (i = 1; i <= n; i++) print "  " body[i] }
      n = 0; inblk = 0
    }
    /^[ \t]*nic_allowlist:/ {
      hdr = $0
      sub(/[ \t]*#.*$/, "", hdr)
      if (hdr !~ /nic_allowlist:[ \t]*$/) sub(/nic_allowlist:.*$/, "nic_allowlist:", hdr)
      inblk = 1; n = 0; next
    }
    inblk {
      if ($0 ~ /^[ \t]+[^ \t]/) {
        line = $0
        sub(/^[ \t]+/, "", line)
        k = line
        sub(/[ \t]*:.*/, "", k)
        if (k == dev) next
        body[++n] = line
        next
      }
      flush()
    }
    { print }
    END { if (inblk) flush() }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

probe_on() {
  _d="$1"
  _k="$(probe_kind)"
  if [ "$_k" = "nezha" ]; then
    _pf="$(nezha_conf)"
    if [ -z "$_pf" ]; then
      warn "找不到哪吒 config.yml；网卡已建好，请手动把 nic_allowlist 设为 $_d"
      return 1
    fi
    cp -a "$_pf" "$BAK" 2>/dev/null || { err "备份 $_pf 失败"; return 1; }
    awk -v dev="$_d" '
      BEGIN { done = 0; inblk = 0 }
      /^[ \t]*nic_allowlist:/ {
        hdr = $0
        sub(/[ \t]*#.*$/, "", hdr)
        if (hdr !~ /nic_allowlist:[ \t]*$/) sub(/nic_allowlist:.*$/, "nic_allowlist:", hdr)
        print hdr
        ind = substr($0, 1, match($0, /[^ \t]/) - 1) "  "
        print ind dev ": true"
        inblk = 1; done = 1; next
      }
      inblk {
        if ($0 ~ /^[ \t]+[^ \t]/) {
          line = $0
          sub(/^[ \t]+/, "", line)
          k = line
          sub(/[ \t]*:.*/, "", k)
          if (k == dev) next
          print
          next
        }
        inblk = 0
      }
      { print }
      END { if (!done) { print "nic_allowlist:"; print "  " dev ": true" } }
    ' "$_pf" > "$_pf.tmp" && mv "$_pf.tmp" "$_pf" || { err "写入 YAML 失败"; return 1; }
    PROBE_FILE="$_pf"; PROBE_BAK="$BAK"
    kvp "探针" "哪吒：$_pf"
    kvp "只监控" "$_d"
  else
    case "$(init_kind)" in
      systemd)
        mkdir -p "$(dirname "$DROPIN")" 2>/dev/null
        [ -f "$DROPIN" ] && { cp -a "$DROPIN" "$BAK" 2>/dev/null; PROBE_BAK="$BAK"; }
        cat > "$DROPIN" <<EOF
# FIP
[Service]
Environment="AGENT_GET_IP_ADDR_FROM_NIC=true"
Environment="AGENT_INCLUDE_NICS=$_d"
EOF
        systemctl daemon-reload 2>/dev/null
        PROBE_DROP="$DROPIN"
        kvp "探针" "Komari：$DROPIN"
        ;;
      *)
        _cf="$KCF"
        [ -f "$_cf" ] && { cp -a "$_cf" "$BAK" 2>/dev/null; PROBE_BAK="$BAK"; }
        if [ -f "$_cf" ]; then
          grep -vE '^(AGENT_)?(INCLUDE_NICS|GET_IP_ADDR_FROM_NIC|EXCLUDE_NICS)=' "$_cf" > "$_cf.tmp" 2>/dev/null && mv "$_cf.tmp" "$_cf"
        else
          printf '# FIP\n' > "$_cf"
        fi
        printf 'AGENT_GET_IP_ADDR_FROM_NIC=true\nAGENT_INCLUDE_NICS=%s\n' "$_d" >> "$_cf"
        PROBE_FILE="$_cf"
        kvp "探针" "Komari：$_cf"
        warn "OpenRC 的 conf.d 变量不一定 export 给进程；没生效就手动加 --include-nics $_d"
        ;;
    esac
  fi
  PROBE_KIND="$_k"
  return 0
}

probe_off() {
  if [ -n "${L_BAK:-}" ] && [ -n "${L_FILE:-}" ] && [ -f "$L_BAK" ]; then
    cp -a "$L_BAK" "$L_FILE" && ok "已还原 $L_FILE"
    rm -f "$L_BAK"
  elif [ -n "${L_FILE:-}" ] && [ -f "$L_FILE" ]; then
    if [ "$L_KIND" = "nezha" ]; then
      remove_allow "$L_FILE" "$L_DEV"
      ok "已从 nic_allowlist 移除 $L_DEV"
    else
      grep -vE '^(AGENT_)?(INCLUDE_NICS|GET_IP_ADDR_FROM_NIC|EXCLUDE_NICS)=' \
        "$L_FILE" > "$L_FILE.tmp" && mv "$L_FILE.tmp" "$L_FILE"
      ok "已清掉 $L_FILE 中的 FIP 变量"
    fi
  fi
  if [ -n "${L_DROP:-}" ] && [ -f "$L_DROP" ]; then
    rm -f "$L_DROP"
    rmdir "$(dirname "$L_DROP")" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    ok "已移除 $L_DROP"
  fi
  [ -f "$BAK" ] && rm -f "$BAK"
  return 0
}

restart_agent() {
  _u="komari-agent"
  [ "$(probe_kind)" = "nezha" ] && _u="nezha-agent"
  _ik="$(init_kind)"
  if [ "$_ik" = "openrc" ]; then
    rc-service "$_u" restart >/dev/null 2>&1 && { ok "已重启 $_u"; return 0; }
  elif [ "$_ik" = "systemd" ]; then
    systemctl restart "$_u" >/dev/null 2>&1 && { ok "已重启 $_u"; return 0; }
  fi
  _p="$(ps_all | grep -v grep | grep "$_u" | head -1 | awk '{print $1}')"
  if [ -n "$_p" ]; then
    kill "$_p" 2>/dev/null && { ok "已 kill $_u ($_p)，由 supervisor 拉起"; return 0; }
  fi
  warn "没自动重启成功，请手动重启 $_u"
  return 1
}

# ── 配置账本 ──────────────────────────────────────────────
save() {
  cat > "$CONF" <<EOF
# FIP 配置（自动生成，可手改）
FIP_IP="$IP"
FIP_MASK="$MASK"
FIP_DEV_USED="$DEV_USED"
FIP_TYPE="$TYPE"
FIP_KIND="$PROBE_KIND"
FIP_FILE="$PROBE_FILE"
FIP_BAK="$PROBE_BAK"
FIP_DROP="$PROBE_DROP"
EOF
  chmod 644 "$CONF" 2>/dev/null
}

load() {
  L_IP=""; L_MASK=""; L_DEV=""; L_TYPE=""; L_KIND=""
  L_FILE=""; L_BAK=""; L_DROP=""
  [ -f "$CONF" ] || return 1
  . "$CONF" 2>/dev/null || return 1
  L_IP="${FIP_IP:-}";       L_MASK="${FIP_MASK:-}"
  L_DEV="${FIP_DEV_USED:-}"; L_TYPE="${FIP_TYPE:-}"
  L_KIND="${FIP_KIND:-}";   L_FILE="${FIP_FILE:-}"
  L_BAK="${FIP_BAK:-}";     L_DROP="${FIP_DROP:-}"
  [ -n "$L_IP" ] || return 1
  return 0
}

# ── 拆除（off 与重复启用共用）─────────────────────────────
teardown() {
  if [ -n "${L_DEV:-}" ]; then
    if [ "$L_DEV" = "lo" ]; then
      if ip addr del "$L_IP/$L_MASK" dev lo 2>/dev/null; then
        ok "已从 lo 删除 $L_IP/$L_MASK"
      else
        dim "lo 上本来就没有这个地址"
      fi
    elif ip link show "$L_DEV" >/dev/null 2>&1; then
      if ip link del "$L_DEV" 2>/dev/null; then
        ok "已删除网卡 $L_DEV"
      else
        err "删除失败（可手动：ip link del $L_DEV）"
      fi
    else
      dim "网卡 $L_DEV 本来就不存在"
    fi
  fi
  persist_off
  probe_off
  rm -f "$CONF"
}

# ── 命令 ──────────────────────────────────────────────────
cmd_on() {
  _arg="${1:-}"
  case "$_arg" in
    ''|on|auto|default) IP="$(addr_for)" ;;
    *)                  IP="$_arg" ;;
  esac
  if ! valid_ip "$IP"; then
    err "IP 格式不对：$IP"
    dim "支持 IPv4（如 175.45.176.1）或 IPv6（如 2606:54c1:1:c4:0:0:0:5）"
    return 1
  fi
  MASK="$(mask_of "$IP")"
  need_root

  hrt "启用 FIP"
  dim "只改 agent 上报的地址；IP 不可达、不改路由、不出网"
  dim "GeoIP 结果取决于面板用的地址库；面板也可能反查连接来源 IP"
  case "$IP" in
    *:*) [ -r /proc/net/if_inet6 ] || warn "看不到 /proc/net/if_inet6：内核 IPv6 栈可能被禁用" ;;
  esac

  # 重复执行时先把上一次的网卡 / 探针 / 自启清干净，避免留下旧地址
  if [ -f "$CONF" ] && load; then
    hr "清理原有配置"
    teardown
    ok "已清掉上一次的配置"
  fi

  hr "创建网卡"
  link_up "$IP" "$MASK" || return 1

  hr "持久化"
  if write_up "$IP" "$MASK" "$DEV_USED"; then
    persist_on
  else
    warn "开机自启没写成，重启后需手动重建网卡"
  fi

  hr "让探针只监控这张网卡"
  PROBE_KIND=""; PROBE_FILE=""; PROBE_BAK=""; PROBE_DROP=""
  if probe_on "$DEV_USED"; then
    restart_agent
  else
    warn "探针配置没写成；网卡已建好，可手动把白名单设为 $DEV_USED"
  fi

  save
  hr "完成"
  kvp "上报 IP" "$IP"
  kvp "监控网卡" "$DEV_USED"
  dim "预览每台地址：fip ip <名字>   关闭还原：fip off"
  return 0
}

cmd_off() {
  hrt "关闭 FIP"
  if ! load; then
    dim "没有 FIP 配置记录"
    persist_off
    return 0
  fi
  teardown
  restart_agent
  hr "完成"
  ok "已还原"
  return 0
}

cmd_status() {
  hrt "FIP 状态"

  hr "上报地址"
  if load; then
    kvp "配置 IP" "$L_IP/$L_MASK"
    kvp "网卡" "$L_DEV（$L_TYPE）"
    if ip link show "$L_DEV" >/dev/null 2>&1; then
      if ip -o addr show dev "$L_DEV" 2>/dev/null | grep -qF " $L_IP/"; then
        kvn "网卡现状"; res "地址已绑定" "$BGRN"
      else
        kvn "网卡现状"; res "网卡在，地址不在（重跑 fip on）" "$BYEL"
      fi
    else
      kvn "网卡现状"; res "不存在（重启后自启可能没生效）" "$BRED"
    fi
  else
    kvp "当前状态" "未启用"
    dim "启用：fip on（自动分配）或菜单 1 / 2 / 3"
  fi

  hr "探针"
  _k="$(probe_kind)"
  _u="komari-agent"; [ "$_k" = "nezha" ] && _u="nezha-agent"
  kvn "种类"; res "$_k" "$BOLD_W"
  if probe_alive "$_k"; then
    kvn "$_u"; res "运行中" "$BGRN"
  else
    kvn "$_u"; res "未运行" "$BRED"
  fi
  if load; then
    kvp "只监控" "${L_DEV:-$DEV}"
  fi

  hr "网卡地址"
  _d="${L_DEV:-$DEV}"
  if ip link show "$_d" >/dev/null 2>&1; then
    ip -o addr show dev "$_d" 2>/dev/null | awk '{print "  " $2 "  " $4 "  (" $1 ")"}'
  else
    dim "$_d 不存在"
  fi

  hr "文件"
  _n=0
  for f in "$CONF" "$UPS" "$LOCALD" "$UNIT" "$DROPIN"; do
    [ -f "$f" ] && { kvp "已存在" "$f"; _n=$(( _n + 1 )); }
  done
  [ "$_n" -eq 0 ] && dim "没有 FIP 相关文件"
  return 0
}

cmd_ip() {
  _n="${1:-}"
  if [ -n "$_n" ] && pool_find "$_n" >/dev/null 2>&1; then
    pool_find "$_n"
    return 0
  fi
  addr_for "$_n"
}

# ── 母机侧：假的地址池 ────────────────────────────────────
# 「造地址池」在这里只是**地址池账本**，不在母机上把整段绑到网卡 ——
# 那会让内核把整段路由指向一个 dummy 黑洞，反而拿不到地址。
# 只骗探针、不出网，地址只需要出现在小鸡自己的网卡上。
POOL_PREFIX=""; POOL_NEXT=1

pool_load() {
  POOL_PREFIX="$P6"; POOL_NEXT=1
  [ -f "$POOL" ] || return 1
  while IFS= read -r _L || [ -n "${_L:-}" ]; do
    case "$_L" in
      POOL_PREFIX=*) POOL_PREFIX="${_L#POOL_PREFIX=}" ;;
      POOL_NEXT=*)   POOL_NEXT="${_L#POOL_NEXT=}" ;;
    esac
  done < "$POOL"
  return 0
}

pool_find() {   # $1=名字 → 打印分配到的地址
  _n="$1"
  [ -f "$POOL" ] || return 1
  while IFS= read -r _L || [ -n "${_L:-}" ]; do
    case "$_L" in
      'A|'*) _r="${_L#A|}"; _nn="${_r%%|*}"; _ip="${_r#*|}"
             [ "$_nn" = "$_n" ] && { printf '%s\n' "$_ip"; return 0; } ;;
    esac
  done < "$POOL"
  return 1
}

pool_count() {
  _c=0
  [ -f "$POOL" ] || { printf '0'; return; }
  while IFS= read -r _L || [ -n "${_L:-}" ]; do
    case "$_L" in 'A|'*) _c=$(( _c + 1 )) ;; esac
  done < "$POOL"
  printf '%s' "$_c"
}

pool_save() {   # 重写头部配置，保留所有 A| 分配记录
  _t="$POOL.tmp"
  {
    printf '# FIP 地址池 — 母机账本（自动生成，可手改）\n'
    printf 'POOL_PREFIX=%s\n' "$POOL_PREFIX"
    printf 'POOL_NEXT=%s\n' "$POOL_NEXT"
    if [ -f "$POOL" ]; then
      while IFS= read -r _L || [ -n "${_L:-}" ]; do
        case "$_L" in 'A|'*) printf '%s\n' "$_L" ;; esac
      done < "$POOL"
    fi
  } > "$_t" && mv "$_t" "$POOL"
  chmod 644 "$POOL" 2>/dev/null
}

# 顺序分配：完整 8 段，最后一段递增
pool_addr() {
  _x="${1:-1}"
  case "$_x" in ''|*[!0-9]*) _x=1 ;; esac
  v6_addr "$POOL_PREFIX" 0 0 0 "$(( _x % 65536 ))"
}

cmd_pool() {
  _act="${1:-list}"
  case "$_act" in
    init)
      if [ -f "$POOL" ]; then
        warn "账本已存在：$POOL（保留原分配，不覆盖；要重建先删掉它）"
      else
        POOL_PREFIX="${2:-$P6}"; POOL_NEXT=1
        mkdir -p "$(dirname "$POOL")" 2>/dev/null
        : > "$POOL"
        pool_save
        ok "已建地址池：$POOL（前缀 $POOL_PREFIX）"
        dim "可用地址形如 $(pool_addr 1)、$(pool_addr 2) …"
      fi
      ;;
    add)
      _name="${2:-}"
      [ -n "$_name" ] || { err "用法：fip pool add <名字> [IP]"; return 1; }
      pool_load || { err "先跑 fip pool init"; return 1; }
      if pool_find "$_name" >/dev/null 2>&1; then
        warn "$_name 已分配：$(pool_find "$_name")（要改先 del）"
        return 1
      fi
      _given="${3:-}"
      if [ -n "$_given" ]; then
        valid_ip "$_given" || { err "IP 格式不对：$_given"; return 1; }
        _a="$_given"
      else
        _a="$(pool_addr "$POOL_NEXT")"
        POOL_NEXT=$(( POOL_NEXT + 1 ))
      fi
      printf 'A|%s|%s\n' "$_name" "$_a" >> "$POOL"
      pool_save
      kvp "$_name" "$_a"
      dim "该台执行：fip $_a"
      ;;
    del)
      _name="${2:-}"
      [ -n "$_name" ] || { err "用法：fip pool del <名字>"; return 1; }
      [ -f "$POOL" ] || { dim "没有地址池账本"; return 0; }
      pool_load                      # 先读回头部，否则 POOL_NEXT 会退回 1
      _t="$POOL.tmp"
      {
        printf '# FIP 地址池 — 母机账本（自动生成，可手改）\n'
        printf 'POOL_PREFIX=%s\n' "$POOL_PREFIX"
        printf 'POOL_NEXT=%s\n' "$POOL_NEXT"
        while IFS= read -r _L || [ -n "${_L:-}" ]; do
          case "$_L" in
            'A|'*) _r="${_L#A|}"; _nn="${_r%%|*}"
                   [ "$_nn" = "$_name" ] || printf '%s\n' "$_L" ;;
          esac
        done < "$POOL"
      } > "$_t" && mv "$_t" "$POOL"
      ok "已释放 $_name"
      ;;
    list)
      pool_load || { dim "没有地址池账本，先跑 fip pool init"; return 0; }
      kvp "前缀" "$POOL_PREFIX"
      kvp "下一个序号" "$POOL_NEXT"
      echo
      _c=0
      while IFS= read -r _L || [ -n "${_L:-}" ]; do
        case "$_L" in
          'A|'*) _r="${_L#A|}"; _nn="${_r%%|*}"; _ip="${_r#*|}"
                 printf '  %-16s %s\n' "$_nn" "$_ip"; _c=$(( _c + 1 )) ;;
        esac
      done < "$POOL"
      [ "$_c" -eq 0 ] && dim "还没有分配任何地址"
      ;;
    cmd)
      _name="${2:-}"
      if [ -z "$_name" ]; then
        pool_load || { dim "没有地址池账本"; return 0; }
        _c=0
        while IFS= read -r _L || [ -n "${_L:-}" ]; do
          case "$_L" in
            'A|'*) _r="${_L#A|}"; _ip="${_r#*|}"
                   printf 'fip %s\n' "$_ip"; _c=$(( _c + 1 )) ;;
          esac
        done < "$POOL"
        [ "$_c" -eq 0 ] && dim "还没有分配任何地址"
        return 0
      fi
      _a="$(pool_find "$_name")" || { err "没找到 $_name 的分配记录"; return 1; }
      printf 'fip %s\n' "$_a"
      ;;
    *) err "未知 pool 操作：$_act"; return 1 ;;
  esac
  return 0
}

# ── 菜单：状态条 ──────────────────────────────────────────
menu_status() {
  dot_on()  { printf '%s◉%s' "$LIME_B" "$RST"; }
  dot_off() { printf '%s◎%s' "$BRED"   "$RST"; }
  dot_na()  { printf '%s◌%s' "$GRA"    "$RST"; }
  bar()     { printf '   %s┃%s ' "$BORD" "$RST"; }

  # ── 探针 ──
  bar
  _k="$(probe_kind)"
  _u="komari-agent"; [ "$_k" = "nezha" ] && _u="nezha-agent"
  printf '%s%s%s %s探针%s ' "$SKY_B" "◈" "$RST" "$GRA" "$RST"
  if probe_alive "$_k"; then
    printf '%s ' "$(dot_on)"; printf '%s%s%s' "$BOLD_W" "$_u" "$RST"
    printf ' %s' "$(st_badge "$BGRN" "运行中")"
  else
    printf '%s ' "$(dot_off)"; printf '%s%s%s' "$GRA" "$_u" "$RST"
    printf ' %s' "$(st_badge "$GRA" "未运行")"
  fi
  echo

  # ── 上报地址 ──
  bar
  printf '%s%s%s %s地址%s ' "$VIO_B" "◈" "$RST" "$GRA" "$RST"
  if load 2>/dev/null; then
    printf '%s ' "$(dot_on)"; printf '%s%s%s' "$BOLD_W" "$L_IP" "$RST"
    if ip link show "$L_DEV" >/dev/null 2>&1; then
      printf ' %s' "$(st_badge "$BGRN" "已绑定")"
    else
      printf ' %s' "$(st_badge "$ORNG_B" "网卡不在")"
    fi
  else
    printf '%s ' "$(dot_na)"
    printf '%s未启用%s' "$GRA" "$RST"
    printf ' %s' "$(st_badge "$GRA" "空闲")"
  fi
  echo

  # ── 前缀 ──
  bar
  printf '%s%s%s %s前缀%s ' "$LIME_B" "◈" "$RST" "$GRA" "$RST"
  printf '%s%s%s' "$BOLD_W" "$P6" "$RST"
  _pl="$(prefix_groups "$P6")"
  _bits=$(( _pl * 16 ))
  printf ' %s' "$(st_badge "$SKY_B" "/$_bits · 完整 8 段")"
  echo
}

# ── 菜单：标题 ────────────────────────────────────────────
banner() {
  printf '\n'
  printf '  %s╭──────────────────────────────────────╮%s\n' "$BORD" "$RST"
  printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$BOLD_W" "fip $VERSION   ·   FAKE IP" "$RST" "$BORD" "$RST"
  printf '  %s│%s  %s%-36s%s%s│%s\n' "$BORD" "$RST" "$GRA" "only what the agent reports" "$RST" "$BORD" "$RST"
  printf '  %s╰──────────────────────────────────────╯%s\n' "$BORD" "$RST"
  printf '   %s◆%s %sfip%s %s%s%s   %s·%s   %s伪造 IP 上报%s\n' \
    "$ORNG_B" "$RST" "$GRA" "$RST" "$BOLD_W" "$VERSION" "$RST" "$GRA" "$RST" "$TEAL_B" "$RST"
}

# ── 菜单动作 ──────────────────────────────────────────────
ui_enable_auto() {
  hr "启用 — 自动分配"
  _a="$(addr_for)"
  kvp "本机地址" "$_a"
  kvp "前缀" "$P6"
  echo
  dim "由主机名 + machine-id 算出：每台不同、重启不变"
  dim "换前缀 FIP_PREFIX6=…    换种子 FIP_SEED=…"
  echo
  if ask "用这个地址启用？"; then
    echo
    cmd_on "$_a"
  else
    printf '  %s已取消%s\n' "$GRA" "$RST"
  fi
}

ui_enable_manual() {
  hr "启用 — 指定地址"
  dim "直接回车取消；IPv4 / IPv6 都行，建议写完整 8 段"
  while :; do
    readline "地址：" ""
    [ -n "$UI_IN" ] || { printf '  %s已取消%s\n' "$GRA" "$RST"; return 0; }
    if valid_ip "$UI_IN"; then break; fi
    err "格式不对：$UI_IN"
  done
  _a="$UI_IN"
  echo
  kvp "将绑定" "$_a"
  echo
  if ask "启用这张地址，并让探针只上报它？"; then
    echo
    cmd_on "$_a"
  else
    printf '  %s已取消%s\n' "$GRA" "$RST"
  fi
}

ui_presets() {
  hr "启用 — 内置快捷地址"
  item "1" "kp4   31.6.16.15              ipinfo: KP / Pyongyang"
  item "2" "kp6   2a12:bec0:160:0:0:0:1   部分 GeoIP 库标 KP"
  item "3" "cf4   104.29.195.20            Cloudflare geofeed: KP"
  item "4" "cf6   2606:54c1:1:c4:0:0:0:1   整 /64 标 KP，推荐"
  echo
  readline "选择 [1-4]，回车取消：" ""
  case "$UI_IN" in
    1) _a="$IP_KP4" ;;
    2) _a="$IP_KP6" ;;
    3) _a="$IP_CF4" ;;
    4) _a="$IP_CF6" ;;
    *) printf '  %s已取消%s\n' "$GRA" "$RST"; return 0 ;;
  esac
  echo
  if ask "确认用 $_a 启用？"; then
    echo
    cmd_on "$_a"
  else
    printf '  %s已取消%s\n' "$GRA" "$RST"
  fi
}

ui_addr() {
  hr "生成 / 预览地址"
  dim "只打印，不改系统；名字相同的机器会得到同一个地址"
  readline "名字 / 种子（回车用本机默认）：" ""
  _a="$(cmd_ip "$UI_IN")"
  echo
  kvp "地址" "$_a"
  case "$_a" in
    *:*) kvp "长度" "$(prefix_groups "$_a") 段（完整 8 段）" ;;
    *)   kvp "长度" "IPv4" ;;
  esac
  echo
  if ask "现在就用这个地址启用？"; then
    echo
    cmd_on "$_a"
  fi
}

ui_off() {
  hr "关闭并还原"
  if ! load; then
    dim "当前没有启用记录"
    return 0
  fi
  kvp "将删除" "$L_DEV"
  kvp "将还原" "${L_FILE:-（无探针配置）}"
  echo
  if ask "删网卡、还原探针配置、清掉开机自启？"; then
    echo
    cmd_off
  else
    printf '  %s已取消%s\n' "$GRA" "$RST"
  fi
}

ui_pool_init() {
  hr "初始化地址池"
  readline "前缀（回车用 $P6）：" "$P6"
  _p="$UI_IN"
  [ -n "$_p" ] || { printf '  %s已取消%s\n' "$GRA" "$RST"; return 0; }
  if [ -f "$POOL" ]; then
    if ask "账本已存在，重建成前缀 $_p（会清空已有分配）？"; then
      rm -f "$POOL"
    else
      printf '  %s已取消%s\n' "$GRA" "$RST"; return 0
    fi
  fi
  echo
  cmd_pool init "$_p"
}

ui_pool_add() {
  hr "分配地址"
  readline "名字（如 nat-1）：" ""
  [ -n "$UI_IN" ] || { printf '  %s已取消%s\n' "$GRA" "$RST"; return 0; }
  _n="$UI_IN"
  readline "指定 IP（回车自动顺序分配）：" ""
  echo
  cmd_pool add "$_n" "$UI_IN"
}

ui_pool_cmd() {
  hr "输出要执行的命令"
  readline "名字（回车输出全部）：" ""
  echo
  cmd_pool cmd "$UI_IN"
}

ui_pool_del() {
  hr "释放分配"
  readline "名字：" ""
  [ -n "$UI_IN" ] || { printf '  %s已取消%s\n' "$GRA" "$RST"; return 0; }
  _n="$UI_IN"
  if ask "释放 $_n 的地址？"; then
    echo
    cmd_pool del "$_n"
  else
    printf '  %s已取消%s\n' "$GRA" "$RST"
  fi
}

ui_help() {
  hr "速查"
  sec "启用 / 关闭"
  note "  fip                    本菜单（无 TTY 时等同 fip on）"
  note "  fip on [IP]            启用；不给 IP 就自动分配本机唯一 /128"
  note "  fip <IP>               指定地址启用，IPv4 / IPv6 都行"
  note "  fip kp4|kp6|cf4|cf6    内置快捷地址"
  note "  fip status / fip off   查看状态 / 关闭还原"

  sec "只看不改"
  note "  fip ip [名字]          算出一个地址并打印"

  sec "母机侧地址池"
  note "  fip pool init [前缀]   建账本（默认 2606:54c1:1:c4）"
  note "  fip pool add <名字> [IP]"
  note "  fip pool list          名字 -> 地址"
  note "  fip pool cmd [名字]    输出该台要跑的命令"
  note "  fip pool del <名字>"

  sec "地址格式"
  dim "自动分配的 /128 一律完整 8 段、不用 :: 简写，例如"
  dim "  2606:54c1:1:c4:0:28c8:de8c:add4"
  dim "前缀由 FIP_PREFIX6 控制，种子由 FIP_SEED 控制"

  sec "环境变量"
  dim "FIP_PREFIX6  FIP_SEED  FIP_DEV  FIP_PROBE"
  dim "FIP_MENU=0（无参数时不进菜单）  FIP_COLOR=0（关颜色）"
  dim "FIP_CONF / FIP_UP / FIP_POOL …（测试用）"
  echo
  dim "完整说明：fip help"
}

# ── 地址池二级菜单 ────────────────────────────────────────
cmd_pool_menu() {
  while :; do
    hr "地址池（母机侧）"
    if pool_load; then
      kvp "账本" "$POOL"
      kvp "前缀" "$POOL_PREFIX"
      kvp "下一个序号" "$POOL_NEXT"
      kvp "已分配" "$(pool_count) 台"
    else
      dim "还没有账本，先选 1 初始化"
    fi
    echo
    item "1" "初始化 / 改前缀"
    item "2" "分配地址"
    item "3" "列出分配"
    item "4" "输出某台的命令"
    item "5" "输出全部命令"
    item "6" "释放"
    item "0" "返回主菜单"
    echo
    printf '  %s❯%s %s请选择%s %s[0-6]%s %s:%s ' "$PINK_B" "$RST" "$BOLD_W" "$RST" "$TEAL_B" "$RST" "$GRA" "$RST"
    read -r c || return 0
    case "$c" in
      1) ui_pool_init; pause ;;
      2) ui_pool_add; pause ;;
      3) cmd_pool list; pause ;;
      4) ui_pool_cmd; pause ;;
      5) cmd_pool cmd ""; pause ;;
      6) ui_pool_del; pause ;;
      0|q|Q) return 0 ;;
      *) printf '  %s✘ 无效选项%s\n' "$BRED" "$RST"; pause ;;
    esac
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
    printf '   %s┄┄%s %s%s启用%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$SKY_B" "$RST" "$BORD" "$RST"
    item "1" "启用 · 自动分配唯一 IPv6"
    item "2" "启用 · 指定 IP / IPv6"
    item "3" "启用 · 内置快捷地址"
    echo
    printf '   %s┄┄%s %s%s查看%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$VIO_B" "$RST" "$BORD" "$RST"
    item "4" "查看当前状态"
    item "5" "生成 / 预览地址（不改系统）"
    echo
    printf '   %s┄┄%s %s%s维护与地址池%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$ORNG_B" "$RST" "$BORD" "$RST"
    item "6" "关闭并还原"
    item "7" "地址池（母机批量分配）"
    echo
    printf '   %s┄┄%s %s%s其他%s %s┄┄%s\n' "$BORD" "$RST" "$BOLD" "$LIME_B" "$RST" "$BORD" "$RST"
    item "8" "帮助 / 速查"
    item "0" "退出"
    echo
    printf '  %s┈┈┈%s %s提示%s %s┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈%s\n' "$BORD2" "$RST" "$PINK_B" "$RST" "$BORD2" "$RST"
    dim "自动分配 = 主机名 + machine-id 哈希，每台不同、重启不变"
    dim "只改 agent 上报值：IP 不可达、不改路由、不出网"
    dim "重复执行会先清理旧配置，不会留下多余地址"
    echo
    printf '  %s❯%s %s请选择%s %s[0-8]%s %s:%s ' "$PINK_B" "$RST" "$BOLD_W" "$RST" "$TEAL_B" "$RST" "$GRA" "$RST"
    read -r c || return 0
    case "$c" in
      1) ui_enable_auto; pause ;;
      2) ui_enable_manual; pause ;;
      3) ui_presets; pause ;;
      4) cmd_status; pause ;;
      5) ui_addr; pause ;;
      6) ui_off; pause ;;
      7) cmd_pool_menu ;;
      8) ui_help; pause ;;
      0) printf '\n  %s再见 👋%s\n\n' "$TEAL_B" "$RST"; exit 0 ;;
      *) printf '  %s✘ 无效选项%s\n' "$BRED" "$RST"; pause ;;
    esac
  done
}

usage() {
  printf 'fip %s — 给本机绑一个指定归属地的 IP，让探针只上报它\n\n' "$VERSION"
  cat <<'EOF'
交互界面：
  fip                       终端里直接进菜单（无 TTY 时等同 fip on）
  fip menu                  强制进菜单

启用：
  fip on [IP]               启用；不给 IP 就从 /64 自动分配本机唯一地址
  fip <IP>                  启用并指定地址，如 fip 2606:54c1:1:c4:0:0:0:5
  fip kp4|kp6|cf4|cf6       用内置快捷地址启用
  fip ip [名字]             只算出地址并打印（池里有这个名字就用池里的）
  fip status                查看状态
  fip off                   删网卡、还原探针配置、清开机自启
  fip help / fip version

母机侧 —— 集中造一个假的地址池，分给各 NAT 小鸡：
  fip pool init [前缀]           建地址池账本（默认 2606:54c1:1:c4）
  fip pool add <名字> [IP]       给一台分配（不写 IP 就顺序取下一个）
  fip pool list                  名字 -> 地址
  fip pool cmd [名字]            输出该台要跑的命令（不给名字输出全部）
  fip pool del <名字>            释放
小鸡侧跑 fip <分到的 IP>，建假网卡绑地址并让探针只上报它。

地址格式：
  默认前缀 2606:54c1:1:c4（Cloudflare 官方 geofeed 明确标 KP 的 /64）
  自动分配出的 /128 一律**完整 8 段、不用 :: 简写**，例如
    2606:54c1:1:c4:0:28c8:de8c:add4
  地址由 主机名 + machine-id 哈希得出：每台不同、重启不变。
  换前缀 FIP_PREFIX6=…  换种子 FIP_SEED=…（同名 => 同地址）

内置地址：
  kp4  31.6.16.15                   kp6  2a12:bec0:160:0:0:0:1
  cf4  104.29.195.20                cf6  2606:54c1:1:c4:0:0:0:1
  （cf4 / cf6 来自 Cloudflare 官方 geofeed，整 /64 都标 KP；kp6 部分库标 GB）

环境变量：
  FIP_PREFIX6=2606:54c1:1:c4   /64 或 /48 前缀（不带 :: 和掩码）
  FIP_SEED=名字                覆盖自动分配种子（同名 => 同地址）
  FIP_DEV=fip0                 虚拟网卡名
  FIP_PROBE=nezha|komari       强制探针种类
  FIP_MENU=0                   无参数时不进菜单
  FIP_COLOR=0                  关掉颜色
  FIP_CONF / FIP_UP / FIP_POOL …  覆盖各文件路径（测试用）

安装：
  install -m 755 fip-v0.1.sh /usr/local/bin/fip

注意：只改 agent 上报值，IP 不可达不出网；面板若按连接来源查 GeoIP，
      或 GeoIP 库不认该段，仍显示真实归属地。哪吒默认 1800 秒上报一轮。
EOF
}

case "${1:-}" in
  '' )
      if [ -t 0 ] && [ -t 1 ] && [ "${FIP_MENU:-1}" != "0" ]; then
        cmd_menu
      else
        cmd_on ""
      fi
      ;;
  menu|ui|tui|interactive|-i)      cmd_menu ;;
  off|down|del|delete|clean|remove) cmd_off ;;
  status|show|stat)                 cmd_status ;;
  ip|addr|seed)                     cmd_ip "${2:-}" ;;
  pool)                             cmd_pool "${2:-list}" "${3:-}" "${4:-}" ;;
  help|-h|--help)                   usage ;;
  version|-v|--version)             printf 'fip %s\n' "$VERSION" ;;
  on|auto|default)                  cmd_on "${2:-}" ;;
  kp4|kp)                           cmd_on "$IP_KP4" ;;
  kp6|kp-v6|kpv6)                   cmd_on "$IP_KP6" ;;
  cf4|cfkp4)                        cmd_on "$IP_CF4" ;;
  cf6|cfkp6)                        cmd_on "$IP_CF6" ;;
  *)                                cmd_on "$1" ;;
esac
