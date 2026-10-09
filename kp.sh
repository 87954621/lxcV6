#!/bin/sh
# kp.sh — VPS 纯 IPv6 切换 / 监控探针自救，一体化脚本
#
#   kp                 探测这台机器能否纯 IPv6 存活，退出时自动还原（默认）
#   kp keep            探测后不还原，直接切到 IPv6-only
#   kp fix             换成 IPv6 DNS 并重启探针（已断线时的急救）
#   kp block           用 iptables 硬性禁止 IPv4 出站
#   kp unblock         撤掉上面的封堵
#   kp status          查看当前网络状态
#   kp help
#
# 环境变量：
#   PANEL=面板域名      额外检查面板域名能否解析出 AAAA
#
# 安装：
#   install -m 755 kp.sh /usr/local/bin/kp

set -u

# ── 配置区 ──────────────────────────────────────────────
LAN="10.10.0.0/22"                    # 内网网段，放行以便 SSH 管理
AGENT="komari-agent"                  # 探针服务名
D1="2606:4700:4700::1111"             # Cloudflare IPv6 DNS
D2="2606:4700:4700::1001"
D3="2001:4860:4860::8888"             # Google IPv6 DNS
TEST_URL="https://ifconfig.co"

# ── 小工具 ──────────────────────────────────────────────
hr()  { echo "── $* ──"; }
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
  cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%s)" 2>/dev/null \
    && return 0
  return 1
}

ipv4_gw()  { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'; }
ipv4_dev() { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

# ── kp check / keep ─────────────────────────────────────
GW=""
DEV=""
BAK="/tmp/.kp-resolv.bak.$$"
KEEP=no

cleanup() {
  trap - EXIT INT TERM
  echo
  if [ "$KEEP" = "yes" ]; then
    hr "keep 模式：保持 IPv6-only，未还原"
    [ -n "$GW" ] && [ -n "$DEV" ] && note "手动还原：ip route add default via $GW dev $DEV"
    rm -f "$BAK"
    return
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
  trap cleanup EXIT INT TERM

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

  echo
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

  echo
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

  echo
  hr "结论"
  if [ -n "$V6" ]; then
    note "可以安全切到 IPv6-only"
    note "正式切换：kp keep   或   ip route del default dev ${DEV:-eth0}"
    note "永久生效：/etc/dhcpcd.conf 加 nogateway"
    note "之后记得：kp fix（重启探针）"
  else
    note "!! IPv6 不通，切过去会失联"
    note "   先查 ip -6 route 有没有 default via fe80::1"
  fi
}

# ── kp fix ──────────────────────────────────────────────
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

  echo
  hr "验证"
  printf '  %-24s' "解析测试:"
  getent ahosts ifconfig.co >/dev/null 2>&1 && echo "OK" || echo "失败"
  printf '  %-24s' "curl -6:"
  V6=$(curl -6 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V6" ] && echo "$V6" || echo "失败"
  printf '  %-24s' "curl -4:"
  curl -4 -m 5 -s -o /dev/null "$TEST_URL" 2>/dev/null \
    && echo "可达（IPv4 未封堵）" || echo "不可达"

  echo
  hr "重启探针 $AGENT"
  if restart_agent; then
    note "已重启"
    note "日志：$(have_systemd && echo "journalctl -u $AGENT -f" || echo "tail -f /var/log/$AGENT.log")"
  else
    note "!! 没找到 $AGENT 服务，请手动重启（改完 DNS 必须重启，否则不会重连）"
  fi
}

# ── kp block / unblock ──────────────────────────────────
ipt_add() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
ipt_del() { iptables -C "$@" 2>/dev/null && iptables -D "$@"; return 0; }

cmd_block() {
  hr "禁止 IPv4 出站"
  if ! command -v iptables >/dev/null 2>&1; then
    note "系统没有 iptables"
    return 1
  fi
  if ! iptables -L OUTPUT -n >/dev/null 2>&1; then
    note "!! 没有 iptables 权限（容器可能缺 NET_ADMIN）"
    note "   改用无需权限的方案：kp keep（只删默认路由）"
    return 1
  fi

  iptables-save > "/root/iptables.bak.$(date +%s)" 2>/dev/null && note "已备份现有规则到 /root/"

  ipt_add OUTPUT -o lo -j ACCEPT
  ipt_add OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ipt_add OUTPUT -d "$LAN" -j ACCEPT
  ipt_add OUTPUT -p udp -m multiport --dports 67,68 -j ACCEPT
  ipt_add OUTPUT -j REJECT --reject-with icmp-net-unreachable

  echo
  hr "当前 OUTPUT 链"
  iptables -S OUTPUT | sed 's/^/  /'

  echo
  hr "验证"
  printf '  %-24s' "curl -6:"
  V6=$(curl -6 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V6" ] && echo "$V6" || echo "失败"
  printf '  %-24s' "curl -4:"
  curl -4 -m 5 -s -o /dev/null "$TEST_URL" 2>/dev/null \
    && echo "仍然可达  <-- 没封住" || echo "不可达，符合预期"

  echo
  hr "持久化（重启不丢）"
  note "Debian : apt install iptables-persistent && netfilter-persistent save"
  note "Alpine : iptables-save > /etc/iptables/rules-save && rc-update add iptables default"
  note "回滚   : kp unblock"
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

# ── kp status ───────────────────────────────────────────
cmd_status() {
  hr "IPv4"
  ip -4 addr show scope global 2>/dev/null | awk '/inet /{print "  地址: " $2 "  dev " $NF}'
  R4=$(ip -4 route show default 2>/dev/null)
  [ -n "$R4" ] && note "默认路由: $R4" || note "默认路由: 无（IPv4 出网已切断）"

  echo
  hr "IPv6"
  ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print "  地址: " $2 "  dev " $NF}'
  R6=$(ip -6 route show default 2>/dev/null)
  if [ -n "$R6" ]; then
    echo "$R6" | sed 's/^/  默认路由: /'
  else
    note "默认路由: 无  <-- IPv6 出不了网，别切"
  fi

  echo
  hr "DNS"
  awk '/^nameserver/{print "  " $2}' /etc/resolv.conf

  echo
  hr "防火墙"
  if command -v iptables >/dev/null 2>&1 && iptables -L OUTPUT -n >/dev/null 2>&1; then
    if iptables -C OUTPUT -j REJECT --reject-with icmp-net-unreachable 2>/dev/null; then
      note "IPv4 出站已封堵（kp block 生效中）"
    else
      note "无封堵规则"
    fi
  else
    note "iptables 不可用或无权限"
  fi
}

# ── 入口 ────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
kp — VPS 纯 IPv6 切换 / 探针自救

  kp                 探测能否纯 IPv6 存活，退出时自动还原（默认，最安全）
  kp keep            探测后不还原，直接切到 IPv6-only
  kp fix             换成 IPv6 DNS 并重启探针（已断线时的急救）
  kp block           用 iptables 硬性禁止 IPv4 出站
  kp unblock         撤除封堵
  kp status          查看当前网络状态
  kp help            显示本帮助

环境变量：
  PANEL=面板域名     额外检查面板域名能否解析出 AAAA

典型流程：
  PANEL=komari.example.com kp     # 先探测一遍，看能不能切
  kp keep                         # 确认没问题再切
  kp fix                          # 重启探针让它走 IPv6
USAGE
}

case "${1:-check}" in
  check)   cmd_check ;;
  keep)    KEEP=yes; cmd_check ;;
  fix)     cmd_fix ;;
  block)   cmd_block ;;
  unblock) cmd_unblock ;;
  status)  cmd_status ;;
  help|-h|--help) usage ;;
  *) echo "未知子命令: $1"; echo; usage; exit 1 ;;
esac
