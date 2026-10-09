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

# ── 版本与更新源 ────────────────────────────────────────
VERSION="1.0.0"
SELF="${0:-kp}"
RAW_URL="https://raw.githubusercontent.com/87954621/lxcV6/main/kp.sh"
CDN_URL="https://cdn.jsdelivr.net/gh/87954621/lxcV6@main/kp.sh"

# ── 配置区 ──────────────────────────────────────────────
LAN="10.10.0.0/22"
AGENT="komari-agent"
[ -n "${KP_AGENT:-}" ] && AGENT="$KP_AGENT"   # 可用 KP_AGENT=xxx 覆盖服务名
[ -n "${KP_LAN:-}" ] && LAN="$KP_LAN"         # 可用 KP_LAN=x.x.x.x/x 覆盖内网网段
D1="2606:4700:4700::1111"     # IPv6 DNS · Cloudflare
D2="2606:4700:4700::1001"
D3="2001:4860:4860::8888"     # IPv6 DNS · Google
V4A="1.1.1.1"                 # IPv4 DNS · Cloudflare（备用）
V4B="8.8.8.8"                 # IPv4 DNS · Google（备用）
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

# 注意 glibc 最多只用前 3 个 nameserver（MAXNS=3），写多了会被忽略。
# 顺序很重要：解析器从第 1 个开始问，超时才换下一个，
# 所以把能用的那个放前面，避免每次解析都干等超时。
write_dns() {
  case "${1:-mixed}" in
    v6only)
      cat > /etc/resolv.conf <<EOF
nameserver $D1
nameserver $D2
nameserver $D3
options timeout:2 attempts:2
EOF
      ;;
    v4first)
      cat > /etc/resolv.conf <<EOF
nameserver $V4A
nameserver $V4B
nameserver $D1
options timeout:2 attempts:1
EOF
      ;;
    mixed|*)
      cat > /etc/resolv.conf <<EOF
nameserver $D1
nameserver $D2
nameserver $V4A
options timeout:2 attempts:1
EOF
      ;;
  esac
}

backup_resolv() { cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%s)" 2>/dev/null; }

ipv4_gw()  { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'; }
ipv4_dev() { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

# 默认路由被删后仍能拿到网卡名：退而求其次从地址里取
net_dev() {
  d=$(ipv4_dev)
  [ -z "$d" ] && d=$(ip -br -4 addr show scope global 2>/dev/null | awk '{print $1; exit}')
  printf '%s' "$d"
}

# 删除默认路由前把网关记下来，供恢复时使用
GWFILE="/tmp/.kp-ipv4-gw"

# 从 DHCP 租约文件里翻出网关
lease_gw() {
  for f in /var/lib/dhcp/dhclient.*.leases /var/lib/dhcpcd/*.lease \
           /var/db/dhclient.leases.* /tmp/dhcpcd*.lease; do
    [ -f "$f" ] || continue
    g=$(grep -h -oE '(option[ _]routers?|ROUTERS?)[= ]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$f" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    [ -n "$g" ] && { printf '%s' "$g"; return 0; }
  done
  printf ''
}

# 按子网推测网关（网关通常是网段第一个地址）
guess_gw() {
  dev="$1"
  line=$(ip -br -4 addr show scope global dev "$dev" 2>/dev/null | awk '{print $3; exit}')
  [ -z "$line" ] && { printf ''; return 0; }
  a=${line%%/*}; p=${line##*/}
  IFS=. read -r o1 o2 o3 o4 <<EOF
$a
EOF
  [ -z "${o4:-}" ] && { printf ''; return 0; }
  ipn=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
  mask=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  net=$(( ipn & mask ))
  g=$(( net + 1 ))
  printf '%d.%d.%d.%d' $(( (g >> 24) & 255 )) $(( (g >> 16) & 255 )) $(( (g >> 8) & 255 )) $(( g & 255 ))
}

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
  trap - EXIT INT TERM HUP
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
  # HUP 必须捕获：中途关闭 SSH 时 shell 收到的是 SIGHUP，
  # 漏掉它会导致 IPv4 默认路由来不及还原，机器卡在 IPv6-only
  trap finish EXIT INT TERM HUP

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
  [ -n "$GW" ] && [ -n "$DEV" ] && printf '%s %s\n' "$GW" "$DEV" > "$GWFILE"
  if [ -n "$DEV" ] && ip route del default dev "$DEV" 2>/dev/null; then
    printf '  %-22s%s\n' "删除默认路由" "$OK（地址保留）"
  else
    printf '  %-22s%s\n' "删除默认路由" "$DIM跳过$RST"
  fi
  write_dns v6only
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

# ── 恢复 IPv4 出站 ──────────────────────────────────────
cmd_restore() {
  hr "恢复 IPv4 出站"
  D=$(net_dev)

  # 1. 撤掉 iptables 封堵
  if command -v iptables >/dev/null 2>&1 && iptables -L OUTPUT -n >/dev/null 2>&1; then
    if iptables -C OUTPUT -j REJECT --reject-with icmp-net-unreachable 2>/dev/null; then
      ipt_del OUTPUT -j REJECT --reject-with icmp-net-unreachable
      ipt_del OUTPUT -p udp -m multiport --dports 67,68 -j ACCEPT
      ipt_del OUTPUT -d "$LAN" -j ACCEPT
      ipt_del OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      ipt_del OUTPUT -o lo -j ACCEPT
      printf '  %-22s%s\n' "iptables 封堵" "已撤除"
    else
      printf '  %-22s%s\n' "iptables 封堵" "本来就没有"
    fi
  fi

  # 2. 恢复 IPv4 默认路由
  if [ -n "$(ip -4 route show default 2>/dev/null)" ]; then
    printf '  %-22s%s\n' "默认路由" "已存在，无需恢复"
  else
    SGW=""; SDEV=""
    if [ -f "$GWFILE" ]; then
      read -r SGW SDEV < "$GWFILE" || true
      SDEV="${SDEV:-$D}"
    fi
    SDEV="${SDEV:-$D}"

    # 候选网关：记录 → DHCP 租约文件 → 子网 .1 → 手工输入
    CANDS="$SGW"
    LG=$(lease_gw); [ -n "$LG" ] && CANDS="$CANDS $LG"
    GG=$(guess_gw "$D"); [ -n "$GG" ] && CANDS="$CANDS $GG"

    FOUND=no
    for gw in $CANDS; do
      [ -z "$gw" ] && continue
      ip route add default via "$gw" dev "$SDEV" 2>/dev/null || continue
      if timeout 3 ping -4 -c 1 -W 2 "$gw" >/dev/null 2>&1; then
        printf '  %-22s%s\n' "默认路由" "已恢复 via $gw dev $SDEV"
        dim "来源：$( [ "$gw" = "$SGW" ] && echo 上次记录 || { [ "$gw" = "$LG" ] && echo DHCP租约 || echo 子网推测; } )"
        FOUND=yes
        break
      fi
      ip route del default via "$gw" dev "$SDEV" 2>/dev/null
      dim "试过 $gw，网关无响应，已撤销"
    done

    if [ "$FOUND" = "no" ]; then
      printf '  %-22s' "默认路由"
      res "未能自动确定" "$YEL"
      dim "请直接回车跳过，或输入正确网关："
      printf '  IPv4 网关: '
      read -r UGW || true
      if [ -n "$UGW" ]; then
        if ip route add default via "$UGW" dev "$SDEV" 2>/dev/null; then
          printf '  %-22s%s\n' "默认路由" "已恢复 via $UGW dev $SDEV"
          FOUND=yes
        else
          printf '  %-22s%s\n' "默认路由" "$FAIL"
        fi
      fi
    fi

    if [ "$FOUND" = "no" ]; then
      printf '  %-22s%s\n' "默认路由" "尝试重新 DHCP"
      if command -v udhcpc >/dev/null 2>&1; then
        udhcpc -i "$SDEV" -q -n -s /etc/udhcpc/default.script 2>/dev/null \
          || udhcpc -i "$SDEV" -q -n 2>/dev/null
      elif command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -n "$SDEV" 2>/dev/null || dhcpcd "$SDEV" 2>/dev/null
      elif command -v dhclient >/dev/null 2>&1; then
        dhclient -r "$SDEV" 2>/dev/null; dhclient "$SDEV" 2>/dev/null
      elif have_systemd; then
        systemctl restart systemd-networkd 2>/dev/null || systemctl restart networking 2>/dev/null
      elif command -v rc-service >/dev/null 2>&1; then
        rc-service networking restart 2>/dev/null
      else
        dim "没有可用 DHCP 客户端"
      fi
      sleep 3
      [ -n "$(ip -4 route show default 2>/dev/null)" ] \
        && printf '  %-22s%s\n' "默认路由" "已通过 DHCP 恢复" \
        || printf '  %-22s%s\n' "默认路由" "$FAIL"
    fi
  fi

  # 3. 还原 DNS
  RB=$(ls -t /etc/resolv.conf.bak.* 2>/dev/null | head -1)
  if [ -n "$RB" ]; then
    cp -a "$RB" /etc/resolv.conf && printf '  %-22s%s\n' "DNS" "已从备份还原"
    dim "$RB"
  else
    printf '  %-22s%s\n' "DNS" "没有备份，保持现状"
  fi

  # 4. 验证
  hr "验证"
  printf '  %-22s' "IPv4 出网"
  V4=$(curl -4 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V4" ] && res "$V4" "$GRN" || res "仍不可达" "$RED"
  printf '  %-22s' "IPv6 出网"
  V6=$(curl -6 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V6" ] && res "$V6" "$GRN" || res "失败" "$RED"
}

# ── 修复 DNS ────────────────────────────────────────────
cmd_fix() {
  MODE="${1:-}"

  if [ -z "$MODE" ] && [ -t 0 ]; then
    hr "选择 DNS 组合"
    note "IPv6 DNS 也能解析 IPv4 地址，只是查询报文走 IPv6 链路"
    echo
    item "1" "IPv6 优先 + IPv4 备用（推荐）"
    item "2" "仅 IPv6（纯 IPv6 机器）"
    item "3" "IPv4 优先 + IPv6 备用"
    echo
    printf '  请选择 [1-3]: '
    read -r m || m=""
    case "$m" in
      2) MODE="v6only" ;;
      3) MODE="v4first" ;;
      *) MODE="mixed" ;;
    esac
  fi
  [ -z "$MODE" ] && MODE="mixed"

  hr "修复 DNS"
  backup_resolv && dim "已备份原 resolv.conf"
  case "$MODE" in
    v6only)
      write_dns v6only
      printf '  %-22s%s\n' "模式" "仅 IPv6"
      dim "$D1 / $D2 / $D3"
      ;;
    v4first)
      write_dns v4first
      printf '  %-22s%s\n' "模式" "IPv4 优先 + IPv6 备用"
      dim "$V4A / $V4B / $D1"
      ;;
    *)
      write_dns mixed
      printf '  %-22s%s\n' "模式" "IPv6 优先 + IPv4 备用"
      dim "$D1 / $D2 / $V4A"
      ;;
  esac
  printf '  %-22s%s\n' "写入" "$OK"

  cat > /etc/resolv.conf.head <<EOF
nameserver $D1
nameserver $D2
EOF
  printf '  %-22s%s\n' "持久化" "$OK"
  dim "已写 /etc/resolv.conf.head，dhcpcd 重写时保持 IPv6 优先"

  hr "当前 resolv.conf"
  awk '/^nameserver|^options/{print "  " $0}' /etc/resolv.conf

  hr "验证"
  printf '  %-22s' "域名解析"
  getent ahosts ifconfig.co >/dev/null 2>&1 && res "OK" "$GRN" || res "失败" "$RED"
  printf '  %-22s' "IPv6 出网"
  V6=$(curl -6 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V6" ] && res "$V6" "$GRN" || res "失败" "$RED"
  printf '  %-22s' "IPv4 出网"
  V4=$(curl -4 -m 5 -s "$TEST_URL" 2>/dev/null)
  [ -n "$V4" ] && res "$V4" "$GRN" || res "不可达" "$YEL"

  dim "改完 DNS 记得重启探针才会重连"
  dim "最多生效 3 个 nameserver（glibc MAXNS），多的会被忽略"
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
    return 0

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
    return 0

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

# ── 持久化 ──────────────────────────────────────────────
DHCPCCD="/etc/dhcpcd.conf"

cmd_persist() {
  ACT="${1:-on}"
  hr "持久化设置"

  if [ ! -f "$DHCPCCD" ]; then
    printf '  %-22s%s\n' "dhcpcd.conf" "不存在，跳过"
  elif [ "$ACT" = "off" ]; then
    if grep -qE '^[[:space:]]*nogateway' "$DHCPCCD" 2>/dev/null; then
      cp -a "$DHCPCCD" "$DHCPCCD.bak.$(date +%s)"
      grep -vE '^[[:space:]]*nogateway' "$DHCPCCD" > "$DHCPCCD.tmp" 2>/dev/null \
        && mv "$DHCPCCD.tmp" "$DHCPCCD"
      printf '  %-22s%s\n' "dhcpcd nogateway" "已移除"
    else
      printf '  %-22s%s\n' "dhcpcd nogateway" "本来就没有"
    fi
  else
    if grep -qE '^[[:space:]]*nogateway' "$DHCPCCD" 2>/dev/null; then
      printf '  %-22s%s\n' "dhcpcd nogateway" "已存在"
    else
      printf '\n# kp: 不让 dhcpcd 安装 IPv4 默认网关\nnogateway\n' >> "$DHCPCCD"
      printf '  %-22s%s\n' "dhcpcd nogateway" "已写入"
      dim "续约时不会再恢复 IPv4 默认路由"
    fi
  fi

  if [ -f /etc/resolv.conf.head ]; then
    printf '  %-22s%s\n' "resolv.conf.head" "已存在"
  else
    cat > /etc/resolv.conf.head <<EOF
nameserver $D1
nameserver $D2
EOF
    printf '  %-22s%s\n' "resolv.conf.head" "已写入"
  fi
  dim "DNS：dhcpcd 重写 resolv.conf 时会把 head 放最前，IPv6 DNS 优先"

  if command -v iptables >/dev/null 2>&1 && iptables -L OUTPUT -n >/dev/null 2>&1; then
    if iptables -C OUTPUT -j REJECT --reject-with icmp-net-unreachable 2>/dev/null; then
      printf '  %-22s%s\n' "iptables 规则" "需手动保存"
      note "Debian : netfilter-persistent save"
      note "Alpine : iptables-save > /etc/iptables/rules-save"
    fi
  fi

  echo
  if [ "$ACT" = "off" ]; then
    dim "取消后重启 dhcpcd 会重新装回 IPv4 默认路由"
  else
    dim "生效：rc-service dhcpcd restart   或   重启机器"
    dim "取消：kp persist off"
  fi
}

# ── 锁定面板走 IPv6 ─────────────────────────────────────
HOSTS="/etc/hosts"
MARK="# kp-panel"

hosts_domain() {
  awk -v m="$MARK" '$0 ~ m {print $2; exit}' "$HOSTS" 2>/dev/null
}

# 取面板域名：参数 → 已有标记 → 从探针服务里解析 → 询问
panel_domain() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  [ -n "${PANEL:-}" ] && { printf '%s' "$PANEL"; return 0; }

  d=$(hosts_domain)
  [ -n "$d" ] && { printf '%s' "$d"; return 0; }

  # 从 service 单元的 ExecStart / command_args 里抠 -e 后面的地址
  for f in /etc/systemd/system/$AGENT.service /etc/init.d/$AGENT; do
    [ -f "$f" ] || continue
    u=$(grep -oE '(-e|--endpoint)[= ]+(https?://)?[^ "'"'"'\\]+' "$f" 2>/dev/null \
        | head -1 | sed -E 's/^(-e|--endpoint)[= ]+//; s#^https?://##; s#/.*$##')
    [ -n "$u" ] && { printf '%s' "$u"; return 0; }
  done

  if [ -t 0 ]; then
    printf '  面板域名（从探针配置里没找到）: ' >&2
    read -r u || true
    printf '%s' "$u"
  fi
}

cmd_lockv6() {
  hr "锁定面板走 IPv6"
  D=$(panel_domain "${1:-}")
  if [ -z "$D" ]; then
    res "拿不到面板域名" "$RED"
    dim "用法：kp lockv6 面板域名"
    dim "或先设置：PANEL=面板域名 kp lockv6"
    return 1
  fi
  printf '  %-22s%s\n' "面板域名" "$D"

  # 解析 AAAA
  A6=$(getent ahostsv6 "$D" 2>/dev/null | awk '{print $1}' | grep ':' | head -1)
  if [ -z "$A6" ]; then
    res "该域名没有 AAAA 记录" "$RED"
    dim "纯 IPv6 下无法连接。请给域名加 AAAA，或改用 kp block 全局封堵"
    return 1
  fi
  printf '  %-22s%s\n' "IPv6 地址" "$A6"

  A4=$(getent ahostsv4 "$D" 2>/dev/null | awk '{print $1; exit}')
  if [ -n "$A4" ]; then
    printf '  %-22s%s\n' "IPv4 地址" "$A4"
    dim "将通过 hosts 屏蔽，避免探针走它"
  fi

  # 写入 /etc/hosts
  if [ -f "$HOSTS" ]; then
    cp -a "$HOSTS" "$HOSTS.kp.bak.$(date +%s)" 2>/dev/null
    if grep -q "$MARK" "$HOSTS" 2>/dev/null; then
      grep -v "$MARK" "$HOSTS" > "$HOSTS.tmp" && mv "$HOSTS.tmp" "$HOSTS"
      dim "已替换原有 kp 记录"
    fi
    printf '%s %s %s\n' "$A6" "$D" "$MARK" >> "$HOSTS"
    printf '  %-22s%s\n' "写入 /etc/hosts" "$OK"
    dim "$A6 $D"
  else
    res "/etc/hosts 不存在" "$RED"
    return 1
  fi

  # 有些解析器会直接读 hosts，但进程多半已缓存
  hr "重启探针"
  if restart_agent; then
    printf '  %-22s%s\n' "$AGENT" "$OK"
  else
    dim "没找到 $AGENT 服务，请手动重启"
  fi

  hr "验证"
  printf '  %-22s' "域名解析"
  RN=$(getent ahosts "$D" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if echo "$RN" | grep -q ':'; then
    res "$RN" "$GRN"
    if echo "$RN" | grep -qE '(^| )[0-9]+\.'; then
      dim "注意：仍返回了 IPv4 地址，探针可能还会尝试走它"
    else
      dim "只返回 IPv6，符合预期"
    fi
  else
    res "$RN" "$YEL"
  fi

  printf '  %-22s' "IPv6 可达"
  curl -6 -m 5 -s -o /dev/null -w '%{http_code}' "https://$D" 2>/dev/null | grep -qE '^[1-5]' \
    && res "OK" "$GRN" || res "无响应" "$YEL"

  dim "撤销：kp lockv6 off"
}

cmd_lockv6_off() {
  hr "取消面板锁定"
  if [ ! -f "$HOSTS" ]; then
    dim "/etc/hosts 不存在"
    return 0
  fi
  if grep -q "$MARK" "$HOSTS" 2>/dev/null; then
    cp -a "$HOSTS" "$HOSTS.kp.bak.$(date +%s)" 2>/dev/null
    grep -v "$MARK" "$HOSTS" > "$HOSTS.tmp" && mv "$HOSTS.tmp" "$HOSTS"
    printf '  %-22s%s\n' "已移除 kp 记录" "$OK"
    restart_agent 2>/dev/null && dim "已重启 $AGENT"
  else
    printf '  %-22s%s\n' "k p 记录" "本来就没有"
  fi
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

  hr "面板"
  HD=$(hosts_domain)
  if [ -n "$HD" ]; then
    HA=$(awk -v m="$MARK" '$0 ~ m {print $1; exit}' "$HOSTS" 2>/dev/null)
    printf '  %-22s%s\n' "$HD" "已锁定到 $HA"
    dim "撤销：kp lockv6 off"
  else
    printf '  %-22s%s\n' "未锁定" "探针按系统解析结果选路"
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

# ── 检查更新 ────────────────────────────────────────────
fetch_url() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -m 10 "$1" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- -T 10 "$1" 2>/dev/null
  elif command -v busybox >/dev/null 2>&1; then
    busybox wget -qO- "$1" 2>/dev/null
  fi
}

remote_version() {
  fetch_url "$1" | sed -n 's/^VERSION="\([^"]*\)".*/\1/p' | head -1
}

ver_gt() {   # $1 > $2 ?
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]
}

cmd_update() {
  hr "检查更新"
  printf '  %-22s%s\n' "当前版本" "$VERSION"

  printf '  %-22s' "获取最新版本"
  NEW=$(remote_version "$RAW_URL")
  [ -z "$NEW" ] && NEW=$(remote_version "$CDN_URL")
  if [ -z "$NEW" ]; then
    res "失败" "$RED"
    dim "网络不通，或仓库地址有变"
    dim "手动更新：wget -qO $SELF $RAW_URL && chmod +x $SELF"
    return 1
  fi
  res "$NEW" "$CYN"

  if ! ver_gt "$NEW" "$VERSION"; then
    printf '  %-22s%s\n' "结果" "$GRN已是最新$RST"
    return 0
  fi

  echo
  if [ "${1:-}" != "force" ] && ! ask "有新版本，现在更新？"; then
    echo "  已取消"
    return 0
  fi

  # 更新前自检：能跑就留一份备份
  TMP=$(mktemp 2>/dev/null || echo "/tmp/kp.new.$$")
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -m 15 "$RAW_URL" -o "$TMP" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP" "$RAW_URL" 2>/dev/null
  fi

  if [ ! -s "$TMP" ]; then
    res "下载失败" "$RED"
    rm -f "$TMP"
    return 1
  fi

  printf '  %-22s' "校验"
  if [ "$(head -1 "$TMP" | cut -c1-9)" != "#!/bin/sh" ] || ! sh -n "$TMP" 2>/dev/null; then
    res "文件不完整或语法错误，已放弃" "$RED"
    rm -f "$TMP"
    return 1
  fi
  res "OK" "$GRN"

  if [ -w "$(dirname "$SELF")" ] || [ "$(id -u)" = "0" ]; then
    cp -a "$SELF" "$SELF.bak.$VERSION" 2>/dev/null
    cat "$TMP" > "$SELF" && chmod +x "$SELF"
    rm -f "$TMP"
    printf '  %-22s%s\n' "更新" "$OK  $VERSION → $NEW"
    dim "旧版备份：$SELF.bak.$VERSION"
    dim "重新进入菜单生效：kp"
  else
    res "没有写入权限" "$YEL"
    dim "手动执行：wget -qO $SELF $RAW_URL && chmod +x $SELF"
    rm -f "$TMP"
    return 1
  fi
}

# ── 菜单 ────────────────────────────────────────────────
banner() {
  printf '%s%s\n' "$CYN$BOLD" "  ┌────────────────────────────────┐"
  printf '%s\n' "  │  kp · 纯 IPv6 切换工具         │"
  printf '%s%s\n' "  └────────────────────────────────┘" "$RST"
  printf '  %sv%s%s\n' "$GRA" "$VERSION" "$RST"
}

# ── 菜单顶部状态条（只读路由表与防火墙，不做网络探测，瞬间返回）──
probe_state() {
  if have_systemd; then
    systemctl is-active "$AGENT" >/dev/null 2>&1 && { printf 'run'; return; }
    systemctl list-unit-files "$AGENT.service" >/dev/null 2>&1 && { printf 'stop'; return; }
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service "$AGENT" status >/dev/null 2>&1 && { printf 'run'; return; }
    [ -f "/etc/init.d/$AGENT" ] && { printf 'stop'; return; }
  fi
  ps ax 2>/dev/null | grep -v grep | grep -q "$AGENT" && { printf 'run'; return; }
  printf 'none'
}

v4_state() {
  if [ -z "$(ip -4 route show default 2>/dev/null)" ]; then
    printf 'off'
  elif command -v iptables >/dev/null 2>&1 \
       && iptables -C OUTPUT -j REJECT --reject-with icmp-net-unreachable >/dev/null 2>&1; then
    printf 'blocked'
  else
    printf 'on'
  fi
}

v6_state() {
  [ -n "$(ip -6 route show default 2>/dev/null)" ] && printf 'on' || printf 'off'
}

menu_status() {
  printf '  %s  ' "探针"
  case "$(probe_state)" in
    run)  printf '%-18s' "$AGENT"; res "● 运行中" "$GRN" ;;
    stop) printf '%-18s' "$AGENT"; res "● 已停止" "$RED" ;;
    *)    printf '%-18s' "-"; res "● 未安装" "$GRA" ;;
  esac

  A4=$(ip -br -4 addr show scope global 2>/dev/null | awk '{print $3; exit}')
  [ -z "$A4" ] && A4="n/a"
  printf '  %s  ' "IPv4"
  printf '%-18s' "$A4"
  case "$(v4_state)" in
    on)      res "● 出网正常" "$GRN" ;;
    off)     res "● 出网已切断" "$YEL" ;;
    blocked) res "● 已封堵" "$YEL" ;;
  esac

  A6=$(ip -br -6 addr show scope global 2>/dev/null | awk '{print $3; exit}')
  A6=${A6%%/*}
  [ -z "$A6" ] && A6="n/a"
  [ ${#A6} -gt 17 ] && A6="$(printf '%s' "$A6" | cut -c1-16)…"
  printf '  %s  ' "IPv6"
  printf '%-18s' "$A6"
  case "$(v6_state)" in
    on)  res "● 出网正常" "$GRN" ;;
    off) res "● 出网不可用" "$RED" ;;
  esac
}

cmd_menu() {
  while :; do
    clear 2>/dev/null || true
    banner
    echo
    menu_status
    echo
    item "1" "查看当前状态"
    item "2" "探测能否纯 IPv6（自动还原）"
    item "3" "切换到 IPv6-only"
    item "4" "恢复 IPv4 出站"
    item "5" "修复 DNS（IPv6 + IPv4 可选）"
    item "6" "重启探针"
    item "7" "禁止 IPv4 出站（iptables）"
    item "8" "撤除封堵"
    item "9" "持久化（重启后仍保持）"
    item "10" "锁定面板走 IPv6（只改 hosts）"
    item "11" "检查更新"
    item "0" "退出"
    echo
    dim "第一次用：先 1 看状态，再 2 探测，确认没问题后 3 切换"
    dim "想切回来：选 4 恢复 IPv4 出站"
    dim "防止 dhcpcd 续约把 IPv4 路由装回来：切完记得选 9"
    echo
    printf '  %s请选择 [0-11]: %s' "$CYN" "$RST"
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
      4) cmd_restore; pause ;;
      5) cmd_fix; pause ;;
      6) cmd_restart; pause ;;
      7)
        if ask "确认禁止 IPv4 出站？内网 $LAN 与 SSH 会保留"; then
          cmd_block
        else
          echo "  已取消"
        fi
        pause ;;
      8) cmd_unblock; pause ;;
      9) cmd_persist on; pause ;;
      10)
        if ask "把面板域名锁定到 IPv6？会写入 /etc/hosts 并重启探针"; then
          cmd_lockv6 ""
        else
          echo "  已取消"
        fi
        pause ;;
      11) cmd_update; pause ;;
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
  kp restore      恢复 IPv4 出站
  kp fix          修复 DNS（可选 v6only / mixed / v4first，不带参数则交互选择）
  kp restart      重启探针
  kp block        iptables 硬性禁止 IPv4 出站
  kp unblock      撤除封堵
  kp persist      持久化，重启后仍保持 IPv6-only
  kp persist off  取消持久化
  kp lockv6       锁定面板走 IPv6（面板域名 / PANEL 环境变量）
  kp lockv6 off   取消锁定
  kp update       检查更新（kp update force 跳过确认）
  kp version      显示版本
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
  restore|unkeep) cmd_restore ;;
  fix)       cmd_fix ;;
  restart)   cmd_restart ;;
  block)     cmd_block ;;
  unblock)   cmd_unblock ;;
  persist)   cmd_persist "${2:-on}" ;;
  lockv6)    if [ "${2:-}" = "off" ]; then cmd_lockv6_off; else cmd_lockv6 "${2:-}"; fi ;;
  update|upgrade) cmd_update "${2:-}" ;;
  version|-v|--version) echo "kp $VERSION" ;;
  status)    cmd_status ;;
  help|-h|--help) usage ;;
  *) echo "未知子命令: $1"; echo; usage; exit 1 ;;
esac
