# kp

VPS 纯 IPv6 切换脚本，配合 Komari / 哪吒（Nezha）探针使用。

让被监控机**只走 IPv6**，并且**不把本机 IPv4 泄露给面板**。

![](https://img.shields.io/badge/version-1.6.2-blue) ｜ 更新：`kp update`

> 前置：机器已安装探针（Komari 或哪吒 v2）。脚本会自动识别，也可用 `KP_PROBE=` 强制指定。

---

## 安装

```bash
wget -qO /usr/local/bin/kp https://raw.githubusercontent.com/87954621/lxcV6/main/kp.sh && chmod +x /usr/local/bin/kp && kp
```

没有 `wget` 用 curl：

```bash
curl -fsSL https://raw.githubusercontent.com/87954621/lxcV6/main/kp.sh -o /usr/local/bin/kp && chmod +x /usr/local/bin/kp && kp
```

国内网络走镜像：

```bash
wget -qO /usr/local/bin/kp https://cdn.jsdelivr.net/gh/87954621/lxcV6@main/kp.sh && chmod +x /usr/local/bin/kp && kp
```

---

## 使用

直接敲 `kp` 进菜单，按数字选：

```
  ╭──────────────────────────────────────╮
  │   kp  纯 IPv6 切换 · 探针自救        │
  │  让被监控机只走 IPv6，不泄露 IPv4    │
  ╰──────────────────────────────────────╯
   ◆ kp 1.6.2   ·   ONLY IPv6

   ┃ ◈ 探针 ◉ komari-agent ▐ 运行中 ▐   隔离 IPv4
   ┃ ◈ IPv4 ◍ 10.10.2.25/22    ▐ 出网已断 ▐
   ┃ ◈ IPv6 ◉ 2600:70ff:b8a0:… ▐ 出网正常 ▐

   ┄┄ 查看与切换 ┄┄
   ▸  1   查看当前状态
   ▸  2   探测能否纯 IPv6（自动还原）
   ▸  3   切换出网模式（IPv6-only ⇄ 恢复 IPv4）

   ┄┄ 修复与维护 ┄┄
   ▸  4   修复 DNS（IPv6 + IPv4 可选）
   ▸  5   重启探针
   ▸  6   IPv4 出站封堵（iptables 开/关）
   ▸  7   屏蔽面板显示的本机 IPv4
   ▸  8   持久化（重启后仍保持）

   ┄┄ 其他 ┄┄
   ▸  9   检查更新
   ▸  0   退出
```

菜单项 3、6、7 是**开关式**的：进去先显示当前状态，再问你要不要切到另一边。危险操作都会先问一次 `y/N`。

### 典型流程

```bash
PANEL=你的面板域名 kp check   # 先探测，看完结论再决定
kp keep                      # 切到 IPv6-only
kp fix                       # 修 DNS（选 IPv6 优先那档）
kp restart                   # 重启探针，让它走 IPv6
```

> 改完 DNS 必须重启探针，多数 agent 只在启动时解析一次域名。

### 非交互调用

| 命令 | 作用 |
| --- | --- |
| `kp` | 交互式菜单（默认） |
| `kp check` | 探测能否纯 IPv6 存活，结束自动还原（最安全） |
| `kp keep` | 探测后不还原，直接切到 IPv6-only |
| `kp restore` | 恢复 IPv4 出站 |
| `kp fix` | 修复 DNS（可选 `v6only` / `mixed` / `v4first`） |
| `kp block` / `kp unblock` | iptables 硬性禁止 / 撤除 IPv4 出站 |
| `kp restart` | 重启探针 |
| `kp persist` / `kp persist off` | 持久化 / 取消持久化 |
| `kp nic` | 查看探针是否上报 IPv4 |
| `kp nic off` | 不上报 IPv4（默认白名单） |
| `kp nic on` | 恢复默认，IPv4、IPv6 都上报 |
| `kp update` | 检查更新（`check` 只查 / `force` 直接装） |
| `kp status` | 查看当前网络状态 |
| `kp unlock` | 清理旧版 lockv6 在 `/etc/hosts` 留下的记录 |
| `kp version` / `kp help` | 版本 / 帮助 |

---

## 面板里还是能看到本机 IPv4？

先分清面板上那个 IPv4 是哪来的：

| 面板显示的 | 来源 | 用什么管 |
| --- | --- | --- |
| 连接来源 IP | 面板服务器看到的出口地址 | `kp keep` / `kp block`（改路由、防火墙） |
| 本机网卡 IPv4 | agent 主动上报的 `ip addr` 列表 | **`kp nic off`**（改 agent 参数） |

路由和 DNS 只影响"往外走"，管不到 agent 把网卡地址**报上去**。所以即使切了 IPv6-only，只要 `eth0` 上还留着内网 IPv4，agent 就会一起上报。

**选菜单 7，或：**

```bash
kp nic off      # 让探针不上报 IPv4
kp nic on       # 恢复默认
```

脚本自动判断探针种类，并自动挑出该统计/该排除的网卡，改完自动重启探针。

> 操作前会检查本机有没有全局 IPv6，没有就拒绝执行（否则可能彻底失联）。
>
> **上报是定时的**（Komari 约 5 分钟 / 哪吒默认 30 分钟），改完不会立刻在面板上看到变化，等一轮再看。

### 两种方式

默认用**白名单**：只统计**没有 IPv4** 的网卡。

```bash
kp nic off            # 白名单（默认）：只统计纯 IPv6 网卡，如 eth1
kp nic off --exclude  # 排除法：排掉带 IPv4 的网卡，其余照常统计
```

白名单最精确 —— 被统计的网卡上压根没有 IPv4。但如果机器上所有网卡都是双栈（挑不出纯 v6 网卡），就用 `--exclude`。

> 原理：Komari agent 默认向外部 API 查**出口公网 IP** 上报，不读网卡。
> 所以要同时开「从网卡取 IP」+ 网卡过滤，两个缺一不可：
>
> ```ini
> AGENT_GET_IP_ADDR_FROM_NIC=true
> AGENT_INCLUDE_NICS=eth1      # 白名单；排除法则用 AGENT_EXCLUDE_NICS=eth0
> ```
>
> 这样取到的 IPv4 为空 → 上报空值 → 面板不再显示 IPv4。

### 哪吒 v2

改 `/opt/nezha/agent/config.yml`，`nic_allowlist` 里**只列出要监控的网卡**：

```yaml
nic_allowlist:
  eth1: true     # 只监控 eth1；没列出来的网卡本来就不监控
```

> 面板支持下发远程配置，会覆盖本机文件。面板能改就优先在面板改。

### 识别不准时

```bash
KP_PROBE=nezha kp nic off     # 强制按哪吒处理
KP_PROBE=komari kp nic off    # 强制按 Komari 处理
```

### 生效了吗？

```bash
kp nic                                        # 看「当前过滤」那行
ps -ef | grep -v grep | grep -E 'komari|nezha'  # 看进程实际参数
```

期望看到 `--get-ip-addr-from-nic --include-nics eth1`（或 `--exclude-nics eth0`）。

---

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `PANEL=面板域名` | 额外检查面板域名能否解析出 AAAA |
| `KP_PROBE=komari\|nezha` | 强制指定探针种类（默认 auto） |
| `KP_AGENT=服务名` | 探针服务名不是 `komari-agent` 时指定 |
| `KP_LAN=网段` | 内网网段不是 `10.10.0.0/22` 时指定 |
| `KP_PROC=进程名` | 探针进程名匹配关键字（默认 komari / nezha） |

---

## 注意

- **切换是运行时改动**，dhcpcd 续约（约 28 分钟）或重启后 IPv4 默认路由会自动装回来 —— 要长期保持请选菜单 8 或跑 `kp persist`
- 动手前确认有服务商的 VNC / 控制台，并确保 `ssh -6` 能连进来
- `kp block` 需要 `NET_ADMIN` 权限，容器里没有的话用 `kp keep`
- DNS 最多生效 3 个 nameserver（glibc MAXNS），所以 `kp fix` 只写 3 个
- 面板显示本机 IPv4 ≠ 出网没禁干净，那是探针上报的网卡地址，用 `kp nic off` 处理
- 白名单挑的是「整张网卡都没有 IPv4」的网卡，双栈网卡一律不算；所有网卡都双栈时请用 `kp nic off --exclude`
- 容器里 PID 限额太小会让命令静默失败（`can't fork`），遇到就 `ulimit -u 4096` 后重跑

---

## License

MIT
