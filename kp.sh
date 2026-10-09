#!/bin/sh
# kp.sh — VPS 纯 IPv6 切换 / 监控探针自救
#
# 直接运行 kp 进入交互式菜单，按提示一步步选。
#
# 也支持非交互调用：
#   kp check     探测能否纯 IPv6 存活，结束自动还原（最安全）
#   kp keep      探测后不还原，直接切到 IPv6-only
#   kp fix       换成 IPv6 DNS
#   kp restart   重启探针
#   kp block     iptables 硬性禁止 IPv4 出站
#   kp unblock   撤除封堵
#   kp status    查看当前网络状态
#   kp help
#
# 环境变量：
#   PANEL=面板域名   额外检查面板域名能否解析出 AAAA
#
# 安装：
#   wget -qO /usr/local/bin/kp https://raw.githubusercontent.com/87954621/lxcV6/main/kp.sh && chmod +x /usr/local/bin/kp && kp

set -u

# ── 配置区 ──────────────────────────────────────────────
LAN="10.10.0.0/22"
AGENT="komari-agent"
[ -n "${KP_AGENT:-}" ] && AGENT="$KP_AGENT"   # 可用 KP_AGENT=xxx 覆盖服务名
[ -n "${KP_LAN:-}" ] && LAN="$KP_LAN"         # 可用 KP_LAN=x.x.x.x/x 覆盖内网网段
D1="2606:4700:4700::1111"
D2="2606:4700:4700::1001"
D3="2001:4860:4860::8888"
TEST_URL="https://ifconfig.co"

# ── 颜色 ────────────────────────────────────────────────
if [ -t 1 ]; then
  RST=$(printf '\033[0m'); BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m')
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m')
  BLU=$(printf '\033[34m'); CYN=$(printf '\033[36m'); GRA=$(printf '\033[90m')
else
  RST=""; BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; CYN=""; GRA=""
fi

# ── 输出小工具 ──────────────────────────────────────────
hr()    { printf '\n%s%s──── %s ────%s\n' "$BOLD" "$CYN" "$*" "$RST"; }
note()  { printf '  %s\n' "$*"; }
dim()   { printf '  %s%s%s\n' "$GRA" "$*" "$RST"; }
item()  { printf '   %s%s%s   %s\n' "$CYN$BOLD" "$1" "$RST" "$2"; }
res()   { printf '%s%s%s\n' "$2" "$1" "$RST"; }

OK="${GRN}OK${RST}"; FAIL="${RED}失败${RST}"; WARN="${YEL}注意${RST}"

have_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

write_dns6() {
  cat > /etc/resolv.conf <<EOF
nameserver $D1
nameserver $D2
nameserver $D3
options timeout:2 attempts:2
EOF
}

backup_resolv() { cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%s)" 2>/dev/null; }

ipv4_gw()  { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'; }
ipv4_dev() { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

ask() {
  printf '  %s%s%s [y/N]: ' "$YEL" "$1" "$RST"
  read -r a || return 1
  case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

pause() {
  printf '\n  %s按回车返回菜单...%s' "$GRA" "$RST"
  read -r _ || true
  printf '\n'
}

# ── 探测 / 切换 ─────────────────────────────────────────
GW=""; DEV=""; BAK="/tmp/.kp-resolv.bak.$$"; KEEP=no; DONE=no

finish() {
  [ "$DONE" = "yes" ] && return 0
  DONE=yes
  trap - EXIT INT TERM
  echo
  if [ "$KEEP" = "yes" ]; then
    hr "已保持 IPv6-only"
    note "IPv4 出网已切断，内网与 SSH 不受影响"
    [ -n "$GW" ] && [ -n "$DEV" ] && dim "需要还原：ip route add default via $GW dev $DEV"
    rm -f "$BAK"
    return 0
  fi
  hr "还原"
  if [ -f "$BAK" ]; then
    cp -a "$BAK" /etc/resolv.conf && printf '  %-22s%s\n' "resolv.conf" "已还原"
    rm -f "$BAK"
  fi
  if [ -n "$GW" ] && [ -n "$DEV" ]; then
    if ip route add default via "$GW" dev "$DEV" 2>/dev/null; then
      printf '  %-22s%s\n' "IPv4 默认路由" "已还原 via $GW dev $DEV"
    else
      printf '  %-22s%s%s%s\n' "IPv4 默认路由" "$RED" "还原失败" "$RST"
      dim "手动执行：ip route add default via $GW dev $DEV"
    fi
  else
    printf '  %-22s%s\n' "IPv4 默认路由" "原本就没有，无需还原"
  fi
}

cmd_check() {
  KEEP="$1"
  trap finish EXIT INT TERM

  GW=$(ipv4_gw); DEV=$(ipv4_dev)
  backup_resolv

  hr "现状"
  if [ -n "$GW" ] || [ -n "$DEV" ]; then
    printf '  %-22s%s\n' "IPv4 默认路由" "${GW:+via $GW }${DEV:+dev $DEV}"
  else
    printf '  %-22s%s\n' "IPv4 默认路由" "无"
  fi
  printf '  %-22s%s\n' "当前 DNS" "$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)"

  hr "临时切断 IPv4 出网"
  if [ -n "$DEV" ] && ip route del default dev "$DEV" 2>/dev/null; then
    printf '  %-22s%s\n' "删除默认路由" "$OK（地址保留）"
  else
    printf '  %-22s%s\n' "删除默认路由" "$DIM跳过$RST"
  fi
  write_dns6
  printf '  %-22s%s\n' "切换 IPv6 DNS" "$OK"

  hr "验证"
  printf '  %-22s' "IPv6 连通性"
  timeout 5 ping -6 -c 1 "$D1" >/dev/null 2>&1 && res "OK" "$GRN" || res "失败" "$RED"

  printf '  %-22s' "IPv6 出网"
  V6=$(curl -6 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V6" ] && res "$V6" "$GRN" || res "失败" "$RED"

  printf '  %-22s' "IPv4 出网（应失败）"
  if curl -4 -m 5 -s -o /dev/null "$TEST_URL" 2>/dev/null; then
    res "仍然可达" "$RED"
  else
    res "不可达" "$GRN"
  fi

  if [ -n "${PANEL:-}" ]; then
    printf '  %-22s' "面板 $PANEL"
    ADDRS=$(getent ahosts "$PANEL" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    [ -n "$ADDRS" ] && res "$ADDRS" "$CYN" || res "解析失败" "$RED"
    echo "$ADDRS" | grep -q ':' \
      && dim "含 IPv6，纯 IPv6 可连" \
      || dim "只有 IPv4，需加 AAAA 或套 Cloudflare"
  fi

  hr "结论"
  if [ -n "$V6" ]; then
    note "这台机器可以纯 IPv6 存活"
    [ "$KEEP" = "no" ] && dim "确认要切换，就选菜单里的「切换到 IPv6-only」"
  else
    res "IPv6 不通，切过去会失联" "$RED"
    dim "先查 ip -6 route 有没有 default via fe80::1"
  fi

  finish
}

# ── 修复 DNS ────────────────────────────────────────────
cmd_fix() {
  hr "修复 DNS"
  backup_resolv && dim "已备份原 resolv.conf"
  write_dns6
  printf '  %-22s%s\n' "写入 IPv6 DNS" "$OK"
  dim "$D1 / $D2 / $D3"

  cat > /etc/resolv.conf.head <<EOF
nameserver $D1
nameserver $D2
EOF
  printf '  %-22s%s\n' "持久化" "$OK"
  dim "已写 /etc/resolv.conf.head，dhcpcd 重写时保持 IPv6 优先"

  hr "验证"
  printf '  %-22s' "域名解析"
  getent ahosts ifconfig.co >/dev/null 2>&1 && res "OK" "$GRN" || res "失败" "$RED"
  printf '  %-22s' "IPv6 出网"
  V6=$(curl -6 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V6" ] && res "$V6" "$GRN" || res "失败" "$RED"

  dim "改完 DNS 记得重启探针才会重连"
}

# ── 重启探针 ────────────────────────────────────────────
cmd_restart() {
  hr "重启探针"
  printf '  %-22s%s\n' "服务名" "$AGENT"

  if have_systemd; then
    if systemctl restart "$AGENT" 2>/dev/null; then
      printf '  %-22s%s\n' "重启" "$OK"
    else
      printf '  %-22s%s\n' "重启" "$FAIL"
      dim "服务可能不存在，检查：systemctl status $AGENT"
      return 1
    fi
    sleep 2
    printf '  %-22s' "运行状态"
    systemctl is-active "$AGENT" >/dev/null 2>&1 && res "运行中" "$GRN" || res "未运行" "$RED"
    dim "看日志：journalctl -u $AGENT -f"

  elif command -v rc-service >/dev/null 2>&1; then
    if rc-service "$AGENT" restart 2>/dev/null; then
      printf '  %-22s%s\n' "重启" "$OK"
    else
      printf '  %-22s%s\n' "重启" "$FAIL"
      dim "服务可能不存在，检查：rc-service $AGENT status"
      return 1
    fi
    sleep 2
    printf '  %-22s' "运行状态"
    rc-service "$AGENT" status >/dev/null 2>&1 && res "运行中" "$GRN" || res "未运行" "$RED"
    dim "看日志：tail -f /var/log/$AGENT.log"

  else
    printf '  %-22s%s\n' "服务管理器" "$FAIL"
    dim "没找到 systemd 或 OpenRC"
  fi

  # 服务方式失败时，给出可操作的排查信息
  hr "排查"
  BIN=""
  for p in /opt/komari/komari-agent /usr/local/bin/komari-agent /usr/bin/komari-agent; do
    [ -x "$p" ] && BIN="$p" && break
  done
  [ -z "$BIN" ] && BIN=$(command -v "$AGENT" 2>/dev/null)

  if [ -n "$BIN" ]; then
    printf '  %-22s%s\n' "二进制" "$BIN"
    printf '  %-22s' "进程"
    ps ax 2>/dev/null | grep -v grep | grep -q "$AGENT" \
      && res "运行中" "$GRN" || res "未运行" "$RED"
    dim "没有注册成服务，手动启动："
    dim "$BIN -e https://面板域名 -t Token &"
  else
    printf '  %-22s%s\n' "二进制" "未找到"
    dim "这台机器可能还没装 Komari 探针"
    dim "确认：ls /opt/komari/   或   ps ax | grep komari"
  fi
  dim "若服务名不同，用 KP_AGENT=实际服务名 kp restart"
  return 1
}

# ── 封堵 / 解封 ─────────────────────────────────────────
ipt_add() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
ipt_del() { iptables -C "$@" 2>/dev/null && iptables -D "$@"; return 0; }

cmd_block() {
  hr "禁止 IPv4 出站"
  if ! command -v iptables >/dev/null 2>&1; then
    res "系统没有 iptables，请改用「切换到 IPv6-only」" "$RED"
    return 1
  fi
  if ! iptables -L OUTPUT -n >/dev/null 2>&1; then
    res "没有 iptables 权限（容器可能缺 NET_ADMIN）" "$RED"
    dim "请改用「切换到 IPv6-only」，只删默认路由，无需权限"
    return 1
  fi

  iptables-save > "/root/iptables.bak.$(date +%s)" 2>/dev/null && dim "已备份现有规则到 /root/"

  ipt_add OUTPUT -o lo -j ACCEPT
  ipt_add OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ipt_add OUTPUT -d "$LAN" -j ACCEPT
  ipt_add OUTPUT -p udp -m multiport --dports 67,68 -j ACCEPT
  ipt_add OUTPUT -j REJECT --reject-with icmp-net-unreachable

  printf '  %-22s%s\n' "封堵规则" "$OK"
  dim "已放行：lo / 内网 $LAN / 已建立连接 / DHCP"

  hr "验证"
  printf '  %-22s' "IPv6 出网"
  V6=$(curl -6 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V6" ] && res "$V6" "$GRN" || res "失败" "$RED"
  printf '  %-22s' "IPv4 出网"
  curl -4 -m 5 -s -o /dev/null "$TEST_URL" 2>/dev/null \
    && res "仍然可达" "$RED" || res "已阻断" "$GRN"

  hr "重启后依然生效"
  note "Debian : apt install iptables-persistent && netfilter-persistent save"
  note "Alpine : iptables-save > /etc/iptables/rules-save && rc-update add iptables default"
}

cmd_unblock() {
  hr "撤除封堵"
  if ! command -v iptables >/dev/null 2>&1; then
    note "系统没有 iptables，无需撤除"
    return 0
  fi
  if ! iptables -L OUTPUT -n >/dev/null 2>&1; then
    note "没有 iptables 权限，无法操作"
    return 0
  fi
  ipt_del OUTPUT -j REJECT --reject-with icmp-net-unreachable
  ipt_del OUTPUT -p udp -m multiport --dports 67,68 -j ACCEPT
  ipt_del OUTPUT -d "$LAN" -j ACCEPT
  ipt_del OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ipt_del OUTPUT -o lo -j ACCEPT
  printf '  %-22s%s\n' "封堵规则" "已清除"
}

# ── 状态 ────────────────────────────────────────────────
cmd_status() {
  hr "IPv4"
  ip -br -4 addr show scope global 2>/dev/null | awk '{print "  地址       " $3 "  (" $1 ")"}'
  R4=$(ip -4 route show default 2>/dev/null)
  if [ -n "$R4" ]; then
    printf '  %-22s%s\n' "默认路由" "$R4"
  else
    printf '  %-22s%s%s%s\n' "默认路由" "$YEL" "无 · IPv4 出网已切断" "$RST"
  fi

  hr "IPv6"
  ip -br -6 addr show scope global 2>/dev/null | awk '{print "  地址       " $3 "  (" $1 ")"}'
  R6=$(ip -6 route show default 2>/dev/null)
  if [ -n "$R6" ]; then
    printf '  %-22s%s\n' "默认路由" "$R6"
  else
    printf '  %-22s%s%s%s\n' "默认路由" "$RED" "无 · IPv6 出不了网，不要切换" "$RST"
  fi

  hr "DNS"
  awk '/^nameserver/{print "  " $2}' /etc/resolv.conf

  hr "防火墙"
  if command -v iptables >/dev/null 2>&1 && iptables -L OUTPUT -n >/dev/null 2>&1; then
    if iptables -C OUTPUT -j REJECT --reject-with icmp-net-unreachable 2>/dev/null; then
      printf '  %-22s%s%s%s\n' "IPv4 出站" "$GRN" "已封堵" "$RST"
    else
      printf '  %-22s%s\n' "IPv4 出站" "未封堵"
    fi
  else
    printf '  %-22s%s\n' "iptables" "不可用或无权限"
  fi

  hr "探针"
  if have_systemd; then
    printf '  %-22s' "$AGENT"
    systemctl is-active "$AGENT" >/dev/null 2>&1 && res "运行中" "$GRN" || res "未运行" "$RED"
  elif command -v rc-service >/dev/null 2>&1; then
    printf '  %-22s' "$AGENT"
    rc-service "$AGENT" status >/dev/null 2>&1 && res "运行中" "$GRN" || res "未运行" "$RED"
  else
    dim "没找到服务管理器"
  fi
}

# ── 菜单 ────────────────────────────────────────────────
banner() {
  printf '%s%s\n' "$CYN$BOLD" "  ┌────────────────────────────────┐"
  printf '%s\n' "  │  kp · 纯 IPv6 切换工具         │"
  printf '%s%s\n' "  └────────────────────────────────┘" "$RST"
}

cmd_menu() {
  while :; do
    clear 2>/dev/null || true
    banner
    echo
    item "1" "查看当前状态"
    item "2" "探测能否纯 IPv6（自动还原）"
    item "3" "切换到 IPv6-only"
    item "4" "修复 DNS（换成 IPv6 DNS）"
    item "5" "重启探针"
    item "6" "禁止 IPv4 出站（iptables）"
    item "7" "撤除封堵"
    item "0" "退出"
    echo
    dim "第一次用建议：先 1 看状态，再 2 探测，确认没问题后 3 切换"
    echo
    printf '  %s请选择 [0-7]: %s' "$CYN" "$RST"
    read -r c || return 0

    case "$c" in
      1) cmd_status; pause ;;
      2) cmd_check no; pause ;;
      3)
        if ask "切换后 IPv4 将无法访问公网，确认？"; then
          cmd_check yes
        else
          echo "  已取消"
        fi
        pause ;;
      4) cmd_fix; pause ;;
      5) cmd_restart; pause ;;
      6)
        if ask "确认禁止 IPv4 出站？内网 $LAN 与 SSH 会保留"; then
          cmd_block
        else
          echo "  已取消"
        fi
        pause ;;
      7) cmd_unblock; pause ;;
      0) echo; exit 0 ;;
      *) echo "  无效选项"; pause ;;
    esac
  done
}

usage() {
  cat <<'USAGE'
kp — VPS 纯 IPv6 切换 / 探针自救

  kp              交互式菜单（默认）
  kp check        探测能否纯 IPv6 存活，结束自动还原
  kp keep         探测后不还原，直接切到 IPv6-only
  kp fix          换成 IPv6 DNS
  kp restart      重启探针
  kp block        iptables 硬性禁止 IPv4 出站
  kp unblock      撤除封堵
  kp status       查看当前网络状态
  kp help         帮助

环境变量：
  PANEL=面板域名  额外检查面板域名能否解析出 AAAA
USAGE
}

# ── 入口 ────────────────────────────────────────────────
case "${1:-}" in
  "")        if [ -t 0 ]; then cmd_menu; else cmd_check no; fi ;;
  menu)      cmd_menu ;;
  check)     cmd_check no ;;
  keep)      cmd_check yes ;;
  fix)       cmd_fix ;;
  restart)   cmd_restart ;;
  block)     cmd_block ;;
  unblock)   cmd_unblock ;;
  status)    cmd_status ;;
  help|-h|--help) usage ;;
  *) echo "未知子命令: $1"; echo; usage; exit 1 ;;
esac
