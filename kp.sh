#!/bin/sh
# kp.sh — VPS 纯 IPv6 切换 / 监控探针自救
#
# 直接运行 kp 会进入交互式菜单，按提示一步步选即可。
# 也支持非交互调用：
#
#   kp menu     交互式菜单（默认）
#   kp check    探测能否纯 IPv6 存活，结束自动还原（最安全）
#   kp keep     探测后不还原，直接切到 IPv6-only
#   kp fix      换成 IPv6 DNS 并重启探针
#   kp block    iptables 硬性禁止 IPv4 出站
#   kp unblock  撤除封堵
#   kp status   查看当前网络状态
#   kp help
#
# 环境变量：
#   PANEL=面板域名   额外检查面板域名能否解析出 AAAA
#
# 安装：
#   wget -qO /usr/local/bin/kp https://raw.githubusercontent.com/87954621/lxcV6/main/kp.sh && chmod +x /usr/local/bin/kp && kp

set -u

# ── 配置区 ──────────────────────────────────────────────
LAN="10.10.0.0/22"                    # 内网网段，放行以便 SSH 管理
AGENT="komari-agent"                  # 探针服务名
D1="2606:4700:4700::1111"             # Cloudflare IPv6 DNS
D2="2606:4700:4700::1001"
D3="2001:4860:4860::8888"             # Google IPv6 DNS
TEST_URL="https://ifconfig.co"

# ── 小工具 ──────────────────────────────────────────────
hr()   { echo; echo "── $* ──"; }
note() { echo "  $*"; }

have_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

restart_agent() {
  if have_systemd; then
    systemctl restart "$AGENT" 2>/dev/null
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "$AGENT" restart 2>/dev/null
  elif command -v service >/dev/null 2>&1; then
    service "$AGENT" restart 2>/dev/null
  else
    return 1
  fi
}

write_dns6() {
  cat > /etc/resolv.conf <<EOF
nameserver $D1
nameserver $D2
nameserver $D3
options timeout:2 attempts:2
EOF
}

backup_resolv() {
  cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%s)" 2>/dev/null
}

ipv4_gw()  { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'; }
ipv4_dev() { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

ask() {                                # ask "提示"  → y 返回 0
  printf '%s [y/N]: ' "$1"
  read -r a || return 1
  case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

pause() {
  printf '\n按回车继续...'
  read -r _ || true
  echo
}

# ── 探测 / 切换 ─────────────────────────────────────────
GW=""
DEV=""
BAK="/tmp/.kp-resolv.bak.$$"
KEEP=no
DONE=no

finish() {
  [ "$DONE" = "yes" ] && return 0
  DONE=yes
  trap - EXIT INT TERM
  echo
  if [ "$KEEP" = "yes" ]; then
    hr "已保持 IPv6-only，未还原"
    [ -n "$GW" ] && [ -n "$DEV" ] && note "需要还原时执行：ip route add default via $GW dev $DEV"
    rm -f "$BAK"
    return 0
  fi
  hr "还原"
  if [ -f "$BAK" ]; then
    cp -a "$BAK" /etc/resolv.conf && note "resolv.conf 已还原"
    rm -f "$BAK"
  fi
  if [ -n "$GW" ] && [ -n "$DEV" ]; then
    ip route add default via "$GW" dev "$DEV" 2>/dev/null \
      && note "IPv4 默认路由已还原 via $GW dev $DEV" \
      || note "!! 还原失败，手动执行：ip route add default via $GW dev $DEV"
  else
    note "原本就没有 IPv4 默认路由，无需还原"
  fi
}

cmd_check() {
  KEEP="$1"
  trap finish EXIT INT TERM

  GW=$(ipv4_gw)
  DEV=$(ipv4_dev)
  backup_resolv || note "!! 无法备份 resolv.conf"

  hr "现状"
  if [ -n "$GW" ] || [ -n "$DEV" ]; then
    note "IPv4 默认路由: ${GW:+via $GW }${DEV:+dev $DEV}"
  else
    note "IPv4 默认路由: 无"
  fi
  note "原 DNS: $(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)"

  hr "临时切断 IPv4 出网"
  if [ -n "$DEV" ]; then
    ip route del default dev "$DEV" 2>/dev/null \
      && note "已删除 IPv4 默认路由（地址保留，内网仍可达）" \
      || note "删除失败或本就没有"
  else
    note "没有 IPv4 默认路由，跳过"
  fi
  write_dns6
  note "已切换为 IPv6 DNS"

  hr "验证"
  printf '  %-24s' "IPv6 连通(不依赖DNS):"
  timeout 5 ping -6 -c 1 "$D1" >/dev/null 2>&1 && echo "OK" || echo "失败"

  printf '  %-24s' "curl -6 出网:"
  V6=$(curl -6 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V6" ] && echo "$V6" || echo "失败"

  printf '  %-24s' "curl -4 出网(应失败):"
  if curl -4 -m 5 -s -o /dev/null "$TEST_URL" 2>/dev/null; then
    echo "仍然可达  <-- IPv4 没断干净"
  else
    echo "不可达，符合预期"
  fi

  if [ -n "${PANEL:-}" ]; then
    printf '  %-24s' "面板 $PANEL:"
    ADDRS=$(getent ahosts "$PANEL" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    [ -n "$ADDRS" ] && echo "$ADDRS" || echo "解析失败"
    echo "$ADDRS" | grep -q ':' \
      && echo "                          ^ 含 IPv6，纯 IPv6 可连" \
      || echo "                          ^ 只有 IPv4，需加 AAAA 或套 Cloudflare"
  fi

  hr "结论"
  if [ -n "$V6" ]; then
    note "这台机器可以纯 IPv6 存活"
    [ "$KEEP" = "no" ] && note "确认要切换就选菜单里的「切换到 IPv6-only」"
  else
    note "!! IPv6 不通，切过去会失联"
    note "   先查 ip -6 route 有没有 default via fe80::1"
  fi

  finish
}

# ── 修复 DNS ────────────────────────────────────────────
cmd_fix() {
  hr "修复 IPv6 DNS"
  backup_resolv && note "已备份原 resolv.conf"
  write_dns6
  note "已写入: $D1 / $D2 / $D3"

  cat > /etc/resolv.conf.head <<EOF
nameserver $D1
nameserver $D2
EOF
  note "已写 /etc/resolv.conf.head，dhcpcd 重写时也保持 IPv6 优先"

  hr "验证"
  printf '  %-24s' "解析测试:"
  getent ahosts ifconfig.co >/dev/null 2>&1 && echo "OK" || echo "失败"
  printf '  %-24s' "curl -6:"
  V6=$(curl -6 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V6" ] && echo "$V6" || echo "失败"
  printf '  %-24s' "curl -4:"
  curl -4 -m 5 -s -o /dev/null "$TEST_URL" 2>/dev/null \
    && echo "可达（IPv4 未封堵）" || echo "不可达"

  hr "重启探针 $AGENT"
  if restart_agent; then
    note "已重启"
    if have_systemd; then
      note "看日志：journalctl -u $AGENT -f"
    else
      note "看日志：tail -f /var/log/$AGENT.log"
    fi
  else
    note "!! 没找到 $AGENT 服务，请手动重启（改完 DNS 必须重启才会重连）"
  fi
}

# ── 封堵 / 解封 ─────────────────────────────────────────
ipt_add() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
ipt_del() { iptables -C "$@" 2>/dev/null && iptables -D "$@"; return 0; }

cmd_block() {
  hr "禁止 IPv4 出站"
  if ! command -v iptables >/dev/null 2>&1; then
    note "系统没有 iptables，请改用「切换到 IPv6-only」（只删默认路由）"
    return 1
  fi
  if ! iptables -L OUTPUT -n >/dev/null 2>&1; then
    note "!! 没有 iptables 权限（容器可能缺 NET_ADMIN）"
    note "   请改用「切换到 IPv6-only」（只删默认路由，无需权限）"
    return 1
  fi

  iptables-save > "/root/iptables.bak.$(date +%s)" 2>/dev/null && note "已备份现有规则到 /root/"

  ipt_add OUTPUT -o lo -j ACCEPT
  ipt_add OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ipt_add OUTPUT -d "$LAN" -j ACCEPT
  ipt_add OUTPUT -p udp -m multiport --dports 67,68 -j ACCEPT
  ipt_add OUTPUT -j REJECT --reject-with icmp-net-unreachable

  hr "当前 OUTPUT 链"
  iptables -S OUTPUT | sed 's/^/  /'

  hr "验证"
  printf '  %-24s' "curl -6:"
  V6=$(curl -6 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V6" ] && echo "$V6" || echo "失败"
  printf '  %-24s' "curl -4:"
  curl -4 -m 5 -s -o /dev/null "$TEST_URL" 2>/dev/null \
    && echo "仍然可达  <-- 没封住" || echo "不可达，符合预期"

  hr "让重启后依然生效"
  note "Debian : apt install iptables-persistent && netfilter-persistent save"
  note "Alpine : iptables-save > /etc/iptables/rules-save && rc-update add iptables default"
  note "需要撤销：菜单选「撤除封堵」，或执行 kp unblock"
}

cmd_unblock() {
  hr "撤除 IPv4 出站封堵"
  ipt_del OUTPUT -j REJECT --reject-with icmp-net-unreachable
  ipt_del OUTPUT -p udp -m multiport --dports 67,68 -j ACCEPT
  ipt_del OUTPUT -d "$LAN" -j ACCEPT
  ipt_del OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ipt_del OUTPUT -o lo -j ACCEPT
  iptables -S OUTPUT | sed 's/^/  /'
}

# ── 状态 ────────────────────────────────────────────────
cmd_status() {
  hr "IPv4"
  ip -4 addr show scope global 2>/dev/null | awk '/inet /{print "  地址: " $2 "  dev " $NF}'
  R4=$(ip -4 route show default 2>/dev/null)
  [ -n "$R4" ] && note "默认路由: $R4" || note "默认路由: 无（IPv4 出网已切断）"

  hr "IPv6"
  ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print "  地址: " $2 "  dev " $NF}'
  R6=$(ip -6 route show default 2>/dev/null)
  if [ -n "$R6" ]; then
    echo "$R6" | sed 's/^/  默认路由: /'
  else
    note "默认路由: 无  <-- IPv6 出不了网，不要切换"
  fi

  hr "DNS"
  awk '/^nameserver/{print "  " $2}' /etc/resolv.conf

  hr "防火墙"
  if command -v iptables >/dev/null 2>&1 && iptables -L OUTPUT -n >/dev/null 2>&1; then
    if iptables -C OUTPUT -j REJECT --reject-with icmp-net-unreachable 2>/dev/null; then
      note "IPv4 出站已封堵"
    else
      note "无封堵规则"
    fi
  else
    note "iptables 不可用或无权限"
  fi
}

# ── 交互式菜单 ──────────────────────────────────────────
cmd_menu() {
  while :; do
    echo
    echo "════════ kp · 纯 IPv6 切换 ════════"
    echo
    echo "  1) 查看当前状态"
    echo "  2) 探测能否纯 IPv6（自动还原，安全）"
    echo "  3) 切换到 IPv6-only"
    echo "  4) 修复 DNS 并重启探针"
    echo "  5) 禁止 IPv4 出站（iptables）"
    echo "  6) 撤除封堵"
    echo "  0) 退出"
    echo
    echo "  提示：第一次用建议先选 1 看状态，再选 2 探测"
    echo
    printf '请选择 [0-6]: '
    read -r c || return 0

    case "$c" in
      1) cmd_status; pause ;;
      2) cmd_check no; pause ;;
      3)
        if ask "确认切换？切换后 IPv4 将无法访问公网"; then
          cmd_check yes
        else
          echo "  已取消"
        fi
        pause
        ;;
      4) cmd_fix; pause ;;
      5)
        if ask "确认禁止 IPv4 出站？（内网 $LAN 与 SSH 仍保留）"; then
          cmd_block
        else
          echo "  已取消"
        fi
        pause
        ;;
      6) cmd_unblock; pause ;;
      0) echo; exit 0 ;;
      *) echo "  无效选项" ;;
    esac
  done
}

usage() {
  cat <<'USAGE'
kp — VPS 纯 IPv6 切换 / 探针自救

  kp               交互式菜单（默认）
  kp check         探测能否纯 IPv6 存活，结束自动还原
  kp keep          探测后不还原，直接切到 IPv6-only
  kp fix           换成 IPv6 DNS 并重启探针
  kp block         iptables 硬性禁止 IPv4 出站
  kp unblock       撤除封堵
  kp status        查看当前网络状态
  kp help          帮助

环境变量：
  PANEL=面板域名   额外检查面板域名能否解析出 AAAA
USAGE
}

# ── 入口 ────────────────────────────────────────────────
case "${1:-}" in
  "")        if [ -t 0 ]; then cmd_menu; else cmd_check no; fi ;;
  menu)      cmd_menu ;;
  check)     cmd_check no ;;
  keep)      cmd_check yes ;;
  fix)       cmd_fix ;;
  block)     cmd_block ;;
  unblock)   cmd_unblock ;;
  status)    cmd_status ;;
  help|-h|--help) usage ;;
  *) echo "未知子命令: $1"; echo; usage; exit 1 ;;
esac
