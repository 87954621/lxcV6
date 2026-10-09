# kp

VPS 纯 IPv6 切换脚本，配合 Komari / 哪吒（Nezha）探针使用。

让被监控机**只走 IPv6**，并且**不把本机 IPv4 泄露给面板**。

当前版本：[![](https://img.shields.io/badge/version-1.3.0-blue)](kp.sh) ｜ 更新：`kp update`

> 前置：机器已安装探针（Komari 或哪吒 v2）。脚本会**自动识别**，也可用 `KP_PROBE=` 强制指定。

---

## 安装

装完自动进入菜单：

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

直接敲 `kp` 进入菜单，按数字选：

```
  ╭──────────────────────────────────────╮
  │   kp  纯 IPv6 切换 · 探针自救        │
  │  让被监控机只走 IPv6，不泄露 IPv4    │
  ╰──────────────────────────────────────╯
   ◆ kp 1.3.0   ·   ONLY IPv6

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

  ┈┈┈ 提示 ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
  第一次用：先 1 看状态，再 2 探测，确认没问题后 3 切换
  面板显示本机 IPv4：选 7（路由管不了 agent 上报）
  防止 dhcpcd 续约把 IPv4 装回来：切完记得选 8

  ❯ 请选择 [0-9] :
```

顶部三行是实时状态条，用彩色圆点 + 徽章显示，不用进菜单就能看到探针、上报范围和出网情况：

| 符号 | 含义 |
| --- | --- |
| `◉` 绿 | 正常 / 运行中 |
| `◍` 橙 | 已切断 / 已封堵（预期状态） |
| `◎` 红 | 异常 / 未运行 |
| `◌` 灰 | 无数据 / 未安装 |

分隔线长度随终端宽度自适应（40~72 列），256 色终端下是渐变色，其他终端自动回落基本色。

菜单项 3、6、7 是**开关式**的：进去后先显示当前状态，再问你要不要切到另一边，同一个入口管开也管关。

危险操作都会先问一次 `y/N` 再执行。

也支持非交互调用：

| 命令 | 作用 |
| --- | --- |
| `kp` | 交互式菜单（默认） |
| `kp check` | 探测能否纯 IPv6 存活，结束自动还原（最安全） |
| `kp keep` | 探测后不还原，直接切到 IPv6-only |
| `kp restore` | 恢复 IPv4 出站（切回来的路） |
| `kp fix` | 修复 DNS（可选 `v6only` / `mixed` / `v4first`） |
| `kp block` | iptables 硬性禁止 IPv4 出站 |
| `kp unblock` | 撤除封堵 |
| `kp restart` | 重启探针 |
| `kp persist` | 持久化，重启后仍保持 IPv6-only |
| `kp persist off` | 取消持久化 |
| `kp nic` | 查看探针是否上报 IPv4 |
| `kp nic off` | 不上报 IPv4（面板不再显示本机 IPv4） |
| `kp nic on` | 恢复默认，IPv4、IPv6 都上报 |
| `kp update` | 检查更新（有新版会询问） |
| `kp update check` | 只检查，不安装 |
| `kp update force` | 直接安装，不询问 |
| `kp unlock` | 清理旧版 lockv6 在 `/etc/hosts` 留下的记录 |
| `kp version` | 显示版本 |
| `kp status` | 查看当前网络状态 |
| `kp help` | 帮助 |

### 典型流程

```bash
PANEL=你的面板域名 kp check   # 先探测，看完结论再决定
kp keep                      # 切到 IPv6-only
kp fix                       # 修 DNS（菜单里选 IPv6 优先那档）
kp restart                   # 重启探针，让它走 IPv6
```

> 改完 DNS 必须重启探针，多数 agent 只在启动时解析一次域名。

### 常用

```bash
kp status      # 看状态
kp restart     # 重启探针（自动识别 systemd / OpenRC）
kp restore     # 恢复 IPv4 出站
```

### 面板里还是能看到本机 IPv4？

这是**两回事**，先分清面板上那个 IPv4 是哪来的：

| 面板显示的 | 来源 | 用什么管 |
| --- | --- | --- |
| 连接来源 IP | 面板服务器看到的出口地址 | `kp keep` / `kp block`（改路由、防火墙） |
| 本机网卡 IPv4 | agent 主动上报的 `ip addr` 列表 | **`kp nic off`**（改 agent 参数） |

路由和 DNS 只影响"往外走"，管不到 agent 把网卡地址**报上去**。所以即使你切了 IPv6-only，只要 `eth0` 上还留着内网 IPv4，agent 就会把它一起上报。

**选菜单 7，或：**

```bash
kp nic off      # 让探针忽略 IPv4，只上报 IPv6
```

脚本会自动判断你装的是哪种探针，走对应的改法：

| 探针 | 关掉 IPv4 上报的做法 |
| --- | --- |
| **Komari** | 为 `komari-agent` 写 systemd drop-in（`/etc/systemd/system/komari-agent.service.d/nic.conf`），设 `IGNORE_IPV4=1`；OpenRC 系统写 `/etc/conf.d/komari-agent` |
| **哪吒 v2** | 改 `/opt/nezha/agent/config.yml`，写入 `nic_allowlist`，只放行有 IPv6 的那几张网卡 |

改完都会自动重启探针。

> 操作前会检查本机有没有全局 IPv6，没有就拒绝执行（否则可能彻底失联）。

恢复默认：

```bash
kp nic on       # Komari 删掉 drop-in；哪吒删掉 nic_allowlist 段。两者都重新上报
```

> 参数名以探针版本为准，建议先确认：`komari-agent --help | grep -i ipv4`。Komari 若你的版本用别的写法（如 `--ignore-ipv4`），改 drop-in 里那一行即可。

### 哪吒（Nezha）探针

哪吒 v2 的 agent 用 YAML 里的 `nic_allowlist` 决定**监控哪些网卡**，不写就是全部监控：

```yaml
# /opt/nezha/agent/config.yml
nic_allowlist:
  eth0: true
  eth1: false
```

`kp nic off` 会自动列出本机有公网 IPv6 的网卡，写成 `: true`，其余网卡不列（等于不监控），内网 IPv4 就不会再出现在面板上。

识别规则（从上往下，命中即停）：

1. 存在 `/opt/nezha/agent/config.yml` 或 `/etc/nezha/config.yml`
2. 有 `nezha-agent` 的 systemd 单元或 `/etc/init.d/nezha-agent`
3. 进程列表里有 `nezha-agent`

识别不出来时，用环境变量强制指定：

```bash
KP_PROBE=nezha kp nic off
```

> ⚠️ 哪吒面板支持**下发远程配置**，如果面板侧也配了 `nic_allowlist`，通常会覆盖本机文件。面板能改的话，优先在面板改更稳妥。
>
> 改完配置建议留意 `ip_report_period`（本机 IP 更新间隔，默认 1800 秒）——面板上的地址列表不会立刻刷新。

---

## 注意

- **切换是运行时改动，dhcpcd 续约（约 28 分钟）或重启后 IPv4 默认路由会自动装回来** —— 要长期保持请选菜单 8 或跑 `kp persist`
- 动手前确认有服务商的 VNC / 控制台，并确保 `ssh -6` 能连进来
- `kp block` 需要 `NET_ADMIN` 权限，容器里没有的话用 `kp keep`
- 脚本改的是运行时状态，重启失效；要持久化在 `/etc/dhcpcd.conf` 加 `nogateway`
- DNS 最多生效 3 个 nameserver（glibc MAXNS），所以 `kp fix` 只写 3 个
- 服务名不同时用 `KP_AGENT=实际服务名 kp restart`；内网网段不同时用 `KP_LAN=x.x.x.x/x`
- 探针识别不准时用 `KP_PROBE=komari` 或 `KP_PROBE=nezha` 强制指定
- 面板显示本机 IPv4 ≠ 出网没禁干净，那是探针上报的网卡地址，用 `kp nic off` 处理
- 哪吒的 `nic_allowlist` 可能被面板下发的远程配置覆盖，面板能改就优先在面板改

---

## License

MIT
