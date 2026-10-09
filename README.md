# kp

VPS 纯 IPv6 切换脚本，配合 Komari / 哪吒（Nezha）探针使用。

让被监控机**只走 IPv6**，并且**不把本机 IPv4 泄露给面板**。

当前版本：

![](https://img.shields.io/badge/version-1.5.0-blue)

 ｜ 更新：`kp update`

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
   ◆ kp 1.5.0   ·   ONLY IPv6

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

| 符号    | 含义              |
| ----- | --------------- |
| `◉` 绿 | 正常 / 运行中        |
| `◍` 橙 | 已切断 / 已封堵（预期状态） |
| `◎` 红 | 异常 / 未运行        |
| `◌` 灰 | 无数据 / 未安装       |

分隔线长度随终端宽度自适应（40~72 列），256 色终端下是渐变色，其他终端自动回落基本色。

菜单项 3、6、7 是**开关式**的：进去后先显示当前状态，再问你要不要切到另一边，同一个入口管开也管关。

危险操作都会先问一次 `y/N` 再执行。

也支持非交互调用：

| 命令                | 作用                                        |
| ----------------- | ----------------------------------------- |
| `kp`              | 交互式菜单（默认）                                 |
| `kp check`        | 探测能否纯 IPv6 存活，结束自动还原（最安全）                 |
| `kp keep`         | 探测后不还原，直接切到 IPv6-only                     |
| `kp restore`      | 恢复 IPv4 出站（切回来的路）                         |
| `kp fix`          | 修复 DNS（可选 `v6only` / `mixed` / `v4first`） |
| `kp block`        | iptables 硬性禁止 IPv4 出站                     |
| `kp unblock`      | 撤除封堵                                      |
| `kp restart`      | 重启探针                                      |
| `kp persist`      | 持久化，重启后仍保持 IPv6-only                      |
| `kp persist off`  | 取消持久化                                     |
| `kp nic`          | 查看探针是否上报 IPv4                             |
| `kp nic off`      | 不上报 IPv4（面板不再显示本机 IPv4）                   |
| `kp nic on`       | 恢复默认，IPv4、IPv6 都上报                        |
| `kp update`       | 检查更新（有新版会询问）                              |
| `kp update check` | 只检查，不安装                                   |
| `kp update force` | 直接安装，不询问                                  |
| `kp unlock`       | 清理旧版 lockv6 在 `/etc/hosts` 留下的记录          |
| `kp version`      | 显示版本                                      |
| `kp status`       | 查看当前网络状态                                  |
| `kp help`         | 帮助                                        |

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

| 面板显示的     | 来源                       | 用什么管                            |
| --------- | ------------------------ | ------------------------------- |
| 连接来源 IP   | 面板服务器看到的出口地址             | `kp keep` / `kp block`（改路由、防火墙） |
| 本机网卡 IPv4 | agent 主动上报的 `ip addr` 列表 | **`kp nic off`**（改 agent 参数）    |

路由和 DNS 只影响"往外走"，管不到 agent 把网卡地址**报上去**。所以即使你切了 IPv6-only，只要 `eth0` 上还留着内网 IPv4，agent 就会把它一起上报。

**选菜单 7，或：**

```bash
kp nic off      # 让探针忽略 IPv4，只上报 IPv6
```

脚本会自动判断你装的是哪种探针，走对应的改法：

| 探针         | 关掉 IPv4 上报的做法                                                                                                                                                                                        |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Komari** | 两个参数**缺一不可**：`AGENT_GET_IP_ADDR_FROM_NIC=true` + `AGENT_INCLUDE_NICS=<有 IPv6 的网卡>`。systemd 写 drop-in；OpenRC 写 `/etc/conf.d/komari-agent`，若 init 脚本不 export 则**直接注入启动参数** |
| **哪吒 v2**  | 改 `/opt/nezha/agent/config.yml`，写入 `nic_allowlist`，只放行有 IPv6 的那几张网卡                                                                                                                                   |

改完都会自动重启探针。

> 操作前会检查本机有没有全局 IPv6，没有就拒绝执行（否则可能彻底失联）。

恢复默认：

```bash
kp nic on       # Komari 删掉 drop-in/conf.d 并撤销注入的参数；哪吒删掉 nic_allowlist 段
```

### OpenRC / Alpine 的坑（写 conf.d 不一定生效）

Alpine / OpenRC 上，`/etc/conf.d/<svc>` 只是**变量仓库** —— 变量能不能进到进程，
取决于 `/etc/init.d/<svc>` 脚本有没有 `export` 或 `set -a`。

用 `supervise-daemon` 拉起的探针（`ps -ef` 里能看到 `supervise-daemon komari-agent ...`）
**通常不会自动继承 conf.d 的变量**，所以只写 conf.d 往往无效。

`kp nic off` 会自动判断：

1. 先查 `/etc/init.d/<svc>` 有没有 `export` / `set -a`
2. **有** → 写 conf.d 就够了
3. **没有** → 直接把 `--get-ip-addr-from-nic --include-nics eth1` 注入到 init 脚本的
   `command_args=` 行尾（带 `# kp-nic-args` 标记，便于 `kp nic on` 精确撤销）

怎么确认是否生效：

```bash
# 看进程实际拿到的参数（最直接）
ps -ef | grep -v grep | grep komari

# 看环境变量有没有进去
tr '\0' '\n' < /proc/$(pgrep -f 'komari|agent' | head -1)/environ | grep -iE 'nic|IP_ADDR'
```

### Komari 探针（重要）

**Komari agent 默认压根不读网卡** —— 它是向 `api.ipify.org` 之类的外部 API 查**出口公网 IP**，
查到什么报什么。所以**单设 `include_nics` 完全没用**，这是个很容易踩的坑。

官方 README 里没列、但源码里真实存在的关键参数（`cmd/flags/flag.go`）：

| JSON 字段                    | 环境变量                            | 说明                    |
| ------------------------- | ------------------------------- | --------------------- |
| `get_ip_addr_from_nic`    | `AGENT_GET_IP_ADDR_FROM_NIC`    | **从网卡获取 IP**（默认 `false`） |
| `custom_ipv4`             | `AGENT_CUSTOM_IPV4`             | 自定义 IPv4 地址           |
| `custom_ipv6`             | `AGENT_CUSTOM_IPV6`             | 自定义 IPv6 地址           |
| `include_nics`            | `AGENT_INCLUDE_NICS`            | 仅统计指定网卡，逗号分隔          |
| `exclude_nics`            | `AGENT_EXCLUDE_NICS`            | 排除指定网卡，逗号分隔           |

源码逻辑（`monitoring/unit/ip.go` 的 `GetIPAddress()`）：

```
if get_ip_addr_from_nic {            ← 默认 false，直接跳过
    从 include_nics 白名单网卡取 IP     ← 这里才用到 include_nics
    if 取到了 { 返回 }
}
从外部 API 查出口 IP                 ← 默认走这条
```

所以正确的组合是**两个一起开**：

```ini
[Service]
Environment="AGENT_GET_IP_ADDR_FROM_NIC=true"
Environment="AGENT_INCLUDE_NICS=eth1"
```

`kp nic off` 会同时写这两行。原理：改成从网卡取 IP 后，只遍历白名单里的 `eth1`，
而 `eth1` 上只有 IPv6 没有 IPv4 → IPv4 取到空值 → **上报空值 → 面板不再显示 IPv4**。

> ⚠️ 早前版本的本脚本写过 `IGNORE_IPV4`，**那个参数根本不存在**（我编的），
> 所以那时怎么改都"没有效果"。现在已改为上面这组真实参数。

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

### 改完面板还是显示 IPv4？

按这个顺序排查：

**1. 等一会儿，别急着下结论**

上报是**定时任务**，不是改完立刻生效。Komari 基础信息默认每 **5 分钟**一次，哪吒 `ip_report_period` 默认 **1800 秒**。等过一轮再看。

**2. 确认配置真的写进去了**

```bash
kp nic                                  # 看「当前过滤」那一行有没有值
cat /etc/systemd/system/komari-agent.service.d/nic.conf   # Komari
cat /opt/nezha/agent/config.yml                           # 哪吒
systemctl cat komari-agent              # 看 drop-in 是否被加载
```

**3. 看 agent 进程实际拿到的参数**

drop-in 写了不代表生效 —— 如果原始 service 里有 `Environment=AGENT_INCLUDE_NICS=...`，或者 agent 直接读 JSON 配置文件，**优先级会盖过 drop-in**。

Komari 的配置优先级（低 → 高）：**默认值 → 命令行参数 → 环境变量 → JSON 配置文件**。

```bash
tr '\0' '\n' < /proc/$(pgrep -f komari-agent | head -1)/environ | grep -iE 'nic|IP_ADDR'
```

**两个变量都要看到**：`AGENT_GET_IP_ADDR_FROM_NIC=true` 和 `AGENT_INCLUDE_NICS=eth1`。
少了前者，agent 就会继续走外部 API 查出口 IP，`include_nics` 等于空转。

**4. 确认那张网卡真的没有 IPv4**

```bash
ip -br addr show eth1
```

如果 `eth1` 上同时挂着 IPv4 和 IPv6，那 IPv4 照样会被取到并上报。
这种情况下改用 `exclude_nics` 排除那张有 IPv4 的网卡（比如 `eth0`），而不是用白名单。

**5. 面板上的 IPv4 可能来自连接来源 IP**

看第一节那张表。如果是"连接来源 IP"，`kp nic` 完全管不着 —— 那得用 `kp keep` / `kp block`。

**6. 刷新面板 / 清缓存**

有些面板会缓存最近一次上报，清一下或重新加载页面。

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
- `kp nic off` 只筛**网卡**不筛地址族：那张网卡上如果同时有 IPv4，IPv4 仍会被上报
- 上报是定时的（Komari 约 5 分钟 / 哪吒默认 30 分钟），改完不会立刻在面板上看到变化

---

## License

MIT
