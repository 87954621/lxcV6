#!/bin/sh
# fkp.sh — 给本机绑一个「指定归属地」的 IP，并让探针只上报它
#
# 与 kp.sh 完全独立：单文件、无依赖，可单独拷贝到每台机器执行。
# kp.sh 1.6.2 已不含伪造 IP 功能，这里是唯一入口。
# 完整文档：fkp-README.md
#
# 默认从同一个 /48 里按「主机名 + /etc/machine-id」算出一个唯一且稳定的
# IPv6 地址 —— 每台机器各不相同，重启也不变。
#
#   fkp                       启用（自动分配唯一 IPv6）
#   fkp 2a12:bec0:160::5     启用（指定地址，IPv4 / IPv6 都行）
#   fkp on                    同 fkp（不带参数）
#   fkp kp4 / kp6 / cf4 / cf6  内置快捷地址（见 fkp help）
#   fkp ip [名字]            只算出地址并打印，不改系统（无母机池时的兜底）
#   fkp status                查看状态
#   fkp off                   删网卡、还原探针配置、清开机自启
#   fkp help / fkp version
#
# 母机侧（集中造一个假的 /48 地址池，把地址分给各 NAT 小鸡）：
#   fkp pool init [前缀]      建立地址池账本
#   fkp pool add <名字> [IP]  给一台小鸡分配地址（不给 IP 就顺序取下一个）
#   fkp pool list             列出 名字 -> 地址
#   fkp pool cmd <名字>       输出该台小鸡要执行的命令
#   fkp pool del <名字>       释放
# 小鸡侧跑 fkp <母机分来的 IP>：建假网卡绑这个地址，探针只上报它。
#
# 更稳的朝鲜段（Cloudflare 官方 geofeed 明确写 KP,KP-01,Pyongyang）：
#   IPv4  104.29.195.20 ~ .23        只有 4 个 /32，边界外就是 MY / BR
#   IPv6  2606:54c1:1:c4::/64       整段都是 KP，可给每台小鸡各分一个
#   fkp pool init 2606:54c1:1:c4    生成 :1::1、:2::1…，实测 ipinfo 都是 KP
#   104.28.0.0/16 里没有 KP：官方 geofeed 的 K 段 KN 之后直接跳到 KR。
#
# 环境变量：
#   FKP_PREFIX6=2a12:bec0:160   /48 前缀（三段；也可四段 /64，不带 :: 和掩码）
#   FKP_SEED=名字               覆盖自动分配的种子（同名 => 同地址）
#   FKP_DEV=fkp0                虚拟网卡名
#   FKP_PROBE=nezha|komari      强制探针种类
#   FKP_CONF / FKP_UP / ...     覆盖各文件路径（测试用）
#
# 限制（重要）：
#   * 只改 agent 上报的地址，IP 不可达、不参与路由、不出网。
#   * 面板若按 gRPC / WebSocket 连接来源 IP 查 GeoIP，仍显示真实出口归属地。
#   * 2a12:bec0:160::/48 是 AS212336 真实在网宣告的段（别人家的），
#     ipinfo / ipwho.is 标为 KP，MaxMind 系标为 GB —— 结果看面板用哪个库。
#   * 母机 NAT 改的是「出口源地址」，改不了小鸡本地网卡的地址；
#     伪造 IP 直接当出口源还会因上游没路由而失联。所以本脚本在每台本机跑。
set -u

VERSION="1.0.0"
# 内置快捷地址（从 kp.sh 的 fakeip 迁来 + Cloudflare 官方 KP 段）
IP_KP4="31.6.16.15"              # ipinfo: KP / Pyongyang
IP_KP6="2a12:bec0:160::1"        # 部分 GeoIP 库标 KP
IP_CF4="104.29.195.20"           # Cloudflare geofeed: KP / Pyongyang
IP_CF6="2606:54c1:1:c4::1"      # 同上，整 /64 都是 KP
P6="${FKP_PREFIX6:-2a12:bec0:160}"
DEV="${FKP_DEV:-fkp0}"
PROBE_FORCE="${FKP_PROBE:-auto}"
SEED="${FKP_SEED:-}"
CONF="${FKP_CONF:-/etc/fkp.conf}"
UPS="${FKP_UP:-/usr/local/sbin/fkp-up}"
LOCALD="${FKP_LOCAL:-/etc/local.d/fkp.start}"
UNIT="${FKP_UNIT:-/etc/systemd/system/fkp.service}"
RCF="${FKP_RC:-/etc/rc.local}"
BAK="${FKP_BAK:-/etc/fkp.probe.bak}"
DROPIN="${FKP_DROPIN:-/etc/systemd/system/komari-agent.service.d/fkp.conf}"
KCF="${FKP_KOMARI_CONF:-/etc/conf.d/komari-agent}"
POOL="${FKP_POOL:-/etc/fkp-pool}"

# ── 输出 ──────────────────────────────────────────────────
hr()  { printf '\n── %s ──\n' "$1"; }
kv()  { printf '  %-14s %s\n' "$1" "$2"; }
ok()  { printf '  [+] %s\n' "$1"; }
warn(){ printf '  [!] %s\n' "$1"; }
err() { printf '  [x] %s\n' "$1"; }
dim() { printf '      %s\n' "$1"; }

# ── 环境识别 ──────────────────────────────────────────────
init_kind() {
  [ -d /run/systemd/system ] && { printf 'systemd'; return 0; }
  if command -v rc-service >/dev/null 2>&1 || [ -d /etc/init.d ]; then
    printf 'openrc'; return 0
  fi
  printf 'other'
}

probe_kind() {
  case "$PROBE_FORCE" in
    nezha|komari) printf '%s' "$PROBE_FORCE"; return 0 ;;
  esac
  if ps ax 2>/dev/null | grep -v grep | grep -qi 'nezha-agent'; then
    printf 'nezha'; return 0
  fi
  if ps ax 2>/dev/null | grep -v grep | grep -qi 'komari-agent\|/opt/komari/agent'; then
    printf 'komari'; return 0
  fi
  for f in /opt/nezha/agent/config.yml /etc/nezha/config.yml /opt/nezha/agent/config.yaml; do
    [ -f "$f" ] && { printf 'nezha'; return 0; }
  done
  printf 'komari'
}

nezha_conf() {
  for f in /opt/nezha/agent/config.yml /etc/nezha/config.yml /opt/nezha/agent/config.yaml; do
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  # 从进程命令行抠 -c 指定的路径
  P="$(ps ax 2>/dev/null | grep -v grep | grep 'nezha-agent' | head -1)"
  if [ -n "$P" ]; then
    CF="$(printf '%s' "$P" | grep -oE '\-c[= ][^ ]+\.ya?ml' | head -1 | sed -E 's/^-c[= ]//')"
    [ -n "$CF" ] && [ -f "$CF" ] && { printf '%s' "$CF"; return 0; }
  fi
  printf ''
}

# ── 自动分配：从 /48 里按名字算一个唯一且稳定的地址 ───────
addr_for() {
  NAME="${1:-}"
  if [ -n "$NAME" ]; then
    S="$NAME"
  elif [ -n "$SEED" ]; then
    S="$SEED"
  else
    S="$(hostname 2>/dev/null || printf 'host')"
    M=""
    [ -r /etc/machine-id ] && IFS= read -r M < /etc/machine-id
    S="$S${M:-}"
  fi
  if command -v cksum >/dev/null 2>&1; then
    set -- $(printf '%s' "$S" | cksum)
    C="${1:-1}"
  else
    C="$(printf '%s' "$S" | wc -c)"
    dim "没有 cksum，回落到长度哈希，不同机器可能撞地址（可用 FKP_SEED 区分）"
  fi
  H=$(( C % 65534 + 1 ))          # 1..65534，避开 ::0 与 ::ffff
  printf '%s:%x::1\n' "$P6" "$H"
}

valid_ip() {
  case "$1" in ''|*[!0-9a-fA-F.:]*) return 1 ;; esac
  case "$1" in *:*) return 0 ;; esac
  _o="$IFS"; IFS='.'
  set -- $1
  IFS="$_o"
  [ "$#" -eq 4 ] || return 1
  for _s in "$@"; do
    case "$_s" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_s" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

mask_of() { case "$1" in *:*) printf '128' ;; *) printf '32' ;; esac }

# ── 网卡 ──────────────────────────────────────────────────
link_up() {
  IP="$1"; MASK="$2"
  DEV_USED="$DEV"; TYPE=""
  if ip link show "$DEV" >/dev/null 2>&1; then
    TYPE="existing"
  elif ip link add "$DEV" type dummy 2>/dev/null; then
    TYPE="dummy"
  elif ip link add "$DEV" type veth peer name "${DEV}p" 2>/dev/null; then
    TYPE="veth"
  else
    DEV_USED="lo"; TYPE="lo"
    warn "建不了虚拟网卡（多半缺 CAP_NET_ADMIN），改为绑到 lo"
  fi
  # scope global：探针扫 `ip addr show scope global` 才看得见
  if ! ip addr add "$IP/$MASK" dev "$DEV_USED" scope global 2>/dev/null; then
    if ! ip -o addr show dev "$DEV_USED" 2>/dev/null | grep -qF " $IP/$MASK "; then
      err "绑地址失败：$IP/$MASK"
      case "$TYPE" in dummy|veth) ip link del "$DEV" 2>/dev/null ;; esac
      return 1
    fi
  fi
  ip link set "$DEV_USED" up 2>/dev/null
  kv "虚拟网卡" "$DEV_USED（$TYPE）"
  kv "绑定地址" "$IP/$MASK"
  LAST_DEV="$DEV_USED"; LAST_TYPE="$TYPE"
  return 0
}

# ── 开机自启（自包含脚本，不依赖 fkp.sh）──────────────────
write_up() {
  IP="$1"; MASK="$2"; D="$3"
  mkdir -p "$(dirname "$UPS")" 2>/dev/null
  cat > "$UPS" <<EOF
#!/bin/sh
# fkp：重启后重建伪造 IP 网卡（不依赖 fkp.sh）
ip link show $D >/dev/null 2>&1 || {
  ip link add $D type dummy 2>/dev/null || \\
  ip link add $D type veth peer name ${D}p 2>/dev/null || exit 1
}
ip -o addr show dev $D 2>/dev/null | grep -qF ' $IP/$MASK ' || \\
  ip addr add $IP/$MASK dev $D scope global 2>/dev/null
ip link set $D up 2>/dev/null
exit 0
EOF
  chmod +x "$UPS" 2>/dev/null
}

persist_on() {
  case "$(init_kind)" in
    openrc)
      mkdir -p "$(dirname "$LOCALD")" 2>/dev/null
      printf '#!/bin/sh\n# fkp\n%s\n' "$UPS" > "$LOCALD"
      chmod +x "$LOCALD" 2>/dev/null
      rc-update add local default >/dev/null 2>&1
      kv "开机自启" "$LOCALD"
      ;;
    systemd)
      cat > "$UNIT" <<EOF
[Unit]
Description=fkp fake IP interface
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$UPS
[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload 2>/dev/null
      systemctl enable fkp.service >/dev/null 2>&1
      kv "开机自启" "$UNIT"
      ;;
    *)
      if [ -f "$RCF" ]; then
        cp -a "$RCF" "$RCF.fkp.bak" 2>/dev/null
        awk -v cmd="$UPS" '
          /^[[:space:]]*exit([[:space:]]|$)/ && !d { print cmd; d=1 }
          { print }
          END { if (!d) print cmd }
        ' "$RCF" > "$RCF.tmp" 2>/dev/null && mv "$RCF.tmp" "$RCF"
        chmod +x "$RCF" 2>/dev/null
        kv "开机自启" "$RCF"
      else
        warn "没识别出 init 系统，重启后需手动跑：$UPS"
      fi
      ;;
  esac
}

persist_off() {
  [ -f "$LOCALD" ] && { rm -f "$LOCALD"; ok "移除 $LOCALD"; }
  if [ -f "$UNIT" ]; then
    systemctl disable fkp.service >/dev/null 2>&1
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

# ── 探针：只监控 fkp0 ─────────────────────────────────────
# 全局记录，off 时据此还原
PROBE_KIND=""; PROBE_FILE=""; PROBE_BAK=""; PROBE_DROP=""

probe_on() {
  D="$1"
  K="$(probe_kind)"
  if [ "$K" = "nezha" ]; then
    PF="$(nezha_conf)"
    if [ -z "$PF" ]; then
      warn "找不到哪吒 config.yml；网卡已建好，请手动把 nic_allowlist 设为 $D"
      return 1
    fi
    cp -a "$PF" "$BAK" 2>/dev/null || { err "备份 $PF 失败"; return 1; }
    awk -v dev="$D" '
      BEGIN { blk=0; done=0 }
      /^[[:space:]]*nic_allowlist:/ {
        ind = substr($0, 1, match($0, /[^[:space:]]/) - 1)
        blk=1; print ind "nic_allowlist:"; print ind "  " dev ": true"; done=1; next
      }
      blk==1 { if ($0 ~ /^[^ \t]/) blk=0; else next }
      { print }
      END { if (!done) { print "nic_allowlist:"; print "  " dev ": true" } }
    ' "$PF" > "$PF.tmp" && mv "$PF.tmp" "$PF" || { err "写入 YAML 失败"; return 1; }
    PROBE_FILE="$PF"; PROBE_BAK="$BAK"
    kv "探针" "哪吒：$PF"
    kv "只监控" "$D"
  else
    case "$(init_kind)" in
      systemd)
        mkdir -p "$(dirname "$DROPIN")" 2>/dev/null
        [ -f "$DROPIN" ] && { cp -a "$DROPIN" "$BAK" 2>/dev/null; PROBE_BAK="$BAK"; }
        cat > "$DROPIN" <<EOF
# fkp
[Service]
Environment="AGENT_GET_IP_ADDR_FROM_NIC=true"
Environment="AGENT_INCLUDE_NICS=$D"
EOF
        systemctl daemon-reload 2>/dev/null
        PROBE_DROP="$DROPIN"
        kv "探针" "Komari：$DROPIN"
        ;;
      *)
        CF="$KCF"
        [ -f "$CF" ] && { cp -a "$CF" "$BAK" 2>/dev/null; PROBE_BAK="$BAK"; }
        if [ -f "$CF" ]; then
          grep -vE '^(AGENT_)?(INCLUDE_NICS|GET_IP_ADDR_FROM_NIC|EXCLUDE_NICS)=' "$CF" > "$CF.tmp" 2>/dev/null && mv "$CF.tmp" "$CF"
        else
          printf '# fkp\n' > "$CF"
        fi
        printf 'AGENT_GET_IP_ADDR_FROM_NIC=true\nAGENT_INCLUDE_NICS=%s\n' "$D" >> "$CF"
        PROBE_FILE="$CF"
        kv "探针" "Komari：$CF"
        warn "OpenRC 的 conf.d 变量不一定 export 给进程；没生效就手动加 --include-nics $D"
        ;;
    esac
  fi
  PROBE_KIND="$K"
  return 0
}

probe_off() {
  if [ -n "$L_BAK" ] && [ -n "$L_FILE" ] && [ -f "$L_BAK" ]; then
    cp -a "$L_BAK" "$L_FILE" && ok "已还原 $L_FILE"
    rm -f "$L_BAK"
  elif [ -n "$L_FILE" ] && [ -f "$L_FILE" ]; then
    if [ "$L_KIND" = "nezha" ]; then
      awk '/^[[:space:]]*nic_allowlist:/{skip=1;next} skip==1&&/^[ \t]/{next}{skip=0;print}' \
        "$L_FILE" > "$L_FILE.tmp" && mv "$L_FILE.tmp" "$L_FILE"
      ok "已移除 nic_allowlist"
    else
      grep -vE '^(AGENT_)?(INCLUDE_NICS|GET_IP_ADDR_FROM_NIC|EXCLUDE_NICS)=' \
        "$L_FILE" > "$L_FILE.tmp" && mv "$L_FILE.tmp" "$L_FILE"
      ok "已清掉 $L_FILE 中的 fkp 变量"
    fi
  fi
  if [ -n "$L_DROP" ] && [ -f "$L_DROP" ]; then
    rm -f "$L_DROP"
    rmdir "$(dirname "$L_DROP")" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    ok "已移除 $L_DROP"
  fi
  [ -f "$BAK" ] && rm -f "$BAK"
  return 0
}

restart_agent() {
  U="komari-agent"
  [ "$(probe_kind)" = "nezha" ] && U="nezha-agent"
  IK="$(init_kind)"
  if [ "$IK" = "openrc" ]; then
    rc-service "$U" restart >/dev/null 2>&1 && { ok "已重启 $U"; return 0; }
  elif [ "$IK" = "systemd" ]; then
    systemctl restart "$U" >/dev/null 2>&1 && { ok "已重启 $U"; return 0; }
  fi
  P="$(ps ax 2>/dev/null | grep -v grep | grep "$U" | head -1 | awk '{print $1}')"
  if [ -n "$P" ]; then
    kill "$P" 2>/dev/null && { ok "已 kill $U ($P)，由 supervisor 拉起"; return 0; }
  fi
  warn "没自动重启成功，请手动重启 $U"
  return 1
}

# ── 配置账本 ──────────────────────────────────────────────
save() {
  cat > "$CONF" <<EOF
# fkp 配置（自动生成，可手改）
FKP_IP="$IP"
FKP_MASK="$MASK"
FKP_DEV_USED="$DEV_USED"
FKP_TYPE="$TYPE"
FKP_KIND="$PROBE_KIND"
FKP_FILE="$PROBE_FILE"
FKP_BAK="$PROBE_BAK"
FKP_DROP="$PROBE_DROP"
EOF
  chmod 644 "$CONF" 2>/dev/null
}

load() {
  L_IP=""; L_MASK=""; L_DEV=""; L_TYPE=""; L_KIND=""
  L_FILE=""; L_BAK=""; L_DROP=""
  [ -f "$CONF" ] || return 1
  . "$CONF" 2>/dev/null || return 1
  L_IP="${FKP_IP:-}";     L_MASK="${FKP_MASK:-}"
  L_DEV="${FKP_DEV_USED:-}"; L_TYPE="${FKP_TYPE:-}"
  L_KIND="${FKP_KIND:-}"; L_FILE="${FKP_FILE:-}"
  L_BAK="${FKP_BAK:-}";   L_DROP="${FKP_DROP:-}"
  [ -n "$L_IP" ] || return 1
  return 0
}

# ── 命令 ──────────────────────────────────────────────────
cmd_on() {
  ARG="${1:-}"
  case "$ARG" in
    ''|on|auto) IP="$(addr_for)" ;;
    *)          IP="$ARG" ;;
  esac
  if ! valid_ip "$IP"; then
    err "IP 格式不对：$IP"
    dim "支持 IPv4（如 175.45.176.1）或 IPv6（如 2a12:bec0:160::5）"
    return 1
  fi
  MASK="$(mask_of "$IP")"

  hr "fkp $VERSION — 启用"
  dim "只改 agent 上报的地址；IP 不可达、不改路由、不出网"
  dim "GeoIP 结果取决于面板用的地址库；面板可能反查连接来源 IP"
  case "$IP" in
    *:*) [ -r /proc/net/if_inet6 ] || warn "看不到 /proc/net/if_inet6：内核 IPv6 栈可能被禁用" ;;
  esac
  echo
  hr "创建网卡"
  LAST_DEV=""; LAST_TYPE=""
  link_up "$IP" "$MASK" || return 1
  DEV_USED="$LAST_DEV"; TYPE="$LAST_TYPE"

  hr "持久化"
  write_up "$IP" "$MASK" "$DEV_USED"
  persist_on

  hr "让探针只监控这张网卡"
  PROBE_KIND=""; PROBE_FILE=""; PROBE_BAK=""; PROBE_DROP=""
  if probe_on "$DEV_USED"; then
    restart_agent
  else
    warn "探针配置没写成；网卡已建好，可手动把白名单设为 $DEV_USED"
  fi

  save
  hr "完成"
  kv "上报 IP" "$IP"
  kv "监控网卡" "$DEV_USED"
  dim "预览每台地址：fkp ip <名字>   关闭还原：fkp off"
  return 0
}

cmd_off() {
  hr "fkp — 关闭"
  if ! load; then
    dim "没有 fkp 配置记录"
    persist_off
    return 0
  fi
  hr "删除网卡"
  if [ "$L_DEV" = "lo" ]; then
    if ip addr del "$L_IP/$L_MASK" dev lo 2>/dev/null; then
      ok "已从 lo 删除 $L_IP/$L_MASK"
    else
      dim "lo 上本来就没有这个地址"
    fi
  elif ip link show "$L_DEV" >/dev/null 2>&1; then
    if ip link del "$L_DEV" 2>/dev/null; then ok "已删除 $L_DEV"
    else err "删除失败（可手动：ip link del $L_DEV）"; fi
  else
    dim "$L_DEV 本来就不存在"
  fi
  hr "清理开机自启"
  persist_off
  hr "还原探针配置"
  probe_off
  rm -f "$CONF"
  restart_agent
  hr "完成"
  ok "已还原"
  return 0
}

cmd_status() {
  hr "fkp status"
  if load; then
    kv "配置 IP" "$L_IP/$L_MASK"
    kv "网卡" "$L_DEV（$L_TYPE）"
    kv "探针" "$L_KIND"
  else
    kv "当前状态" "未启用"
  fi
  echo
  hr "网卡地址"
  D="${L_DEV:-$DEV}"
  if ip link show "$D" >/dev/null 2>&1; then
    ip -o addr show dev "$D" 2>/dev/null
  else
    dim "$D 不存在"
  fi
  echo
  hr "文件"
  for f in "$CONF" "$UPS" "$LOCALD" "$UNIT"; do
    [ -f "$f" ] && kv "已存在" "$f"
  done
  return 0
}

# ── 母机侧：假的 /48 地址池 ───────────────────────────────
# 「造 /48」在这里只是**地址池账本**，不在母机上把整段 /48 绑到网卡 ——
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
  _N="$1"
  [ -f "$POOL" ] || return 1
  while IFS= read -r _L || [ -n "${_L:-}" ]; do
    case "$_L" in
      'A|'*) _R="${_L#A|}"; _NN="${_R%%|*}"; _IP="${_R#*|}"
             [ "$_NN" = "$_N" ] && { printf '%s\n' "$_IP"; return 0; } ;;
    esac
  done < "$POOL"
  return 1
}

pool_save() {   # 重写头部配置，保留所有 A| 分配记录
  _T="$POOL.tmp"
  {
    printf '# fkp pool — 母机地址池账本（自动生成，可手改）\n'
    printf 'POOL_PREFIX=%s\n' "$POOL_PREFIX"
    printf 'POOL_NEXT=%s\n' "$POOL_NEXT"
    if [ -f "$POOL" ]; then
      while IFS= read -r _L || [ -n "${_L:-}" ]; do
        case "$_L" in 'A|'*) printf '%s\n' "$_L" ;; esac
      done < "$POOL"
    fi
  } > "$_T" && mv "$_T" "$POOL"
  chmod 644 "$POOL" 2>/dev/null
}

pool_addr() { printf '%s:%x::1\n' "$POOL_PREFIX" "$1"; }

cmd_pool() {
  ACT="${1:-list}"
  case "$ACT" in
    init)
      if [ -f "$POOL" ]; then
        warn "账本已存在：$POOL（保留原分配，不覆盖）"
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
      NAME="${2:-}"
      [ -n "$NAME" ] || { err "用法：fkp pool add <名字> [IP]"; return 1; }
      pool_load || { err "先跑 fkp pool init"; return 1; }
      if pool_find "$NAME" >/dev/null 2>&1; then
        warn "$NAME 已分配：$(pool_find "$NAME")（要改先 del）"
        return 1
      fi
      GIVEN="${3:-}"
      if [ -n "$GIVEN" ]; then
        valid_ip "$GIVEN" || { err "IP 格式不对：$GIVEN"; return 1; }
        A="$GIVEN"
      else
        A="$(pool_addr "$POOL_NEXT")"
        POOL_NEXT=$(( POOL_NEXT + 1 ))
      fi
      printf 'A|%s|%s\n' "$NAME" "$A" >> "$POOL"
      pool_save
      kv "$NAME" "$A"
      dim "该台执行：fkp $A"
      ;;
    del)
      NAME="${2:-}"
      [ -f "$POOL" ] || { dim "没有地址池账本"; return 0; }
      pool_load                      # 必须先读回头部，否则 POOL_NEXT 会退回 1
      _T="$POOL.tmp"
      {
        printf '# fkp pool — 母机地址池账本（自动生成，可手改）\n'
        printf 'POOL_PREFIX=%s\n' "$POOL_PREFIX"
        printf 'POOL_NEXT=%s\n' "$POOL_NEXT"
        while IFS= read -r _L || [ -n "${_L:-}" ]; do
          case "$_L" in
            'A|'*) _R="${_L#A|}"; _NN="${_R%%|*}"
                   [ "$_NN" = "$NAME" ] || printf '%s\n' "$_L" ;;
          esac
        done < "$POOL"
      } > "$_T" && mv "$_T" "$POOL"
      ok "已释放 $NAME"
      ;;
    list)
      pool_load || { dim "没有地址池账本，先跑 fkp pool init"; return 0; }
      printf '  前缀        %s\n' "$POOL_PREFIX"
      printf '  下一个序号  %s\n' "$POOL_NEXT"
      echo
      _C=0
      while IFS= read -r _L || [ -n "${_L:-}" ]; do
        case "$_L" in
          'A|'*) _R="${_L#A|}"; _NN="${_R%%|*}"; _IP="${_R#*|}"
                 printf '  %-16s %s\n' "$_NN" "$_IP"; _C=$(( _C + 1 )) ;;
        esac
      done < "$POOL"
      [ "$_C" -eq 0 ] && dim "还没有分配任何地址"
      ;;
    cmd)
      NAME="${2:-}"
      A="$(pool_find "$NAME")" || { err "没找到 $NAME 的分配记录"; return 1; }
      printf 'fkp %s\n' "$A"
      ;;
    *) err "未知 pool 操作：$ACT"; return 1 ;;
  esac
  return 0
}

usage() {
  cat <<EOF
fkp $VERSION — 给本机绑一个指定归属地的 IP，让探针只上报它

  fkp                       启用（自动从 /48 分配本机唯一 IPv6）
  fkp <IP>                  启用并指定地址，如 fkp 2a12:bec0:160::5
  fkp on                    同 fkp（不带参数；后面跟 IP 会被忽略）
  fkp kp4|kp6|cf4|cf6      用内置快捷地址启用
  fkp ip [名字]            只算出地址并打印（无母机池时的兜底）
  fkp status                查看状态
  fkp off                   删网卡、还原探针配置、清开机自启
  fkp help / fkp version

母机侧 —— 集中造一个假的 /48 池，分给各 NAT 小鸡：
  fkp pool init [前缀]           建地址池账本（默认 2a12:bec0:160）
  fkp pool init 2606:54c1:1:c4   推荐：Cloudflare geofeed 标 KP 的 /64
  fkp pool add <名字> [IP]       给一台分配地址（不写 IP 就顺序取下一个）
  fkp pool list                  名字 -> 地址
  fkp pool cmd <名字>            输出该台要跑的命令
  fkp pool del <名字>            释放
小鸡侧跑 fkp <分到的 IP>，建假网卡绑地址并让探针只上报它。

内置地址：
  kp4  31.6.16.15            kp6  2a12:bec0:160::1
  cf4  104.29.195.20         cf6  2606:54c1:1:c4::1
  （cf4 / cf6 来自 Cloudflare 官方 geofeed，整 /64 都标 KP；kp6 部分库标 GB）

环境变量：
  FKP_PREFIX6=2a12:bec0:160   /48 前缀（三段；四段 /64 如 2606:54c1:1:c4 也行）
  FKP_SEED=名字               覆盖自动分配种子（同名 => 同地址）
  FKP_DEV=fkp0                虚拟网卡名
  FKP_PROBE=nezha|komari      强制探针种类
  FKP_KOMARI_CONF=路径         Komari 的 conf.d 文件路径
  FKP_POOL=路径               母机地址池账本（默认 /etc/fkp-pool）

注意：只改 agent 上报值，IP 不可达不出网；面板若按连接来源查 GeoIP，
      或 GeoIP 库不认该段，仍显示真实归属地。哪吒默认 1800 秒上报一轮。
完整文档：fkp-README.md
EOF
}

case "${1:-on}" in
  off|down|del|delete|clean|remove) cmd_off ;;
  status|show|stat)                 cmd_status ;;
  ip|addr|seed)                     addr_for "${2:-}" ;;
  pool)                             cmd_pool "${2:-list}" "${3:-}" "${4:-}" ;;
  help|-h|--help)                   usage ;;
  version|-v|--version)             printf 'fkp %s\n' "$VERSION" ;;
  kp4|kp)                           cmd_on "$IP_KP4" ;;
  kp6|kp-v6|kpv6)                  cmd_on "$IP_KP6" ;;
  cf4|cfkp4)                        cmd_on "$IP_CF4" ;;
  cf6|cfkp6)                        cmd_on "$IP_CF6" ;;
  on|auto|'')                       cmd_on "" ;;
  *)                                cmd_on "$1" ;;
esac
