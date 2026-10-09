# kp

VPS 纯 IPv6 切换脚本，配合 Komari 探针使用。

当前版本：[![](https://img.shields.io/badge/version-1.0.3-blue)](kp.sh) ｜ 更新：`kp update`

> 前置：机器已安装 Komari 探针。

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
  ┌────────────────────────────────┐
  │  kp · 纯 IPv6 切换工具         │
  └────────────────────────────────┘

  探针  komari-agent      ● 运行中
  IPv4  10.10.3.66/22     ● 出网已切断
  IPv6  2600:70ff:b8a0:0… ● 出网正常

   1   查看当前状态
   2   探测能否纯 IPv6（自动还原）
   3   切换到 IPv6-only
   4   恢复 IPv4 出站
   5   修复 DNS（IPv6 + IPv4 可选）
   6   重启探针
   7   禁止 IPv4 出站（iptables）
   8   撤除封堵
   9   持久化（重启后仍保持）
   10  锁定面板走 IPv6（只改 hosts）
   11  检查更新（只看）
   12  安装更新
   0   退出

  第一次用：先 1 看状态，再 2 探测，确认没问题后 3 切换
  想切回来：选 4 恢复 IPv4 出站
  防止 dhcpcd 续约把 IPv4 路由装回来：切完记得选 9
```

顶部三行是实时状态，不用进菜单就能看到探针和出网情况。

危险操作（3、7）会先问一次 `y/N` 再执行。

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
| `kp lockv6 [域名]` | 锁定面板走 IPv6（只改 hosts，不动路由） |
| `kp lockv6 off` | 取消锁定 |
| `kp update` | 检查更新（有新版会询问） |
| `kp update check` | 只检查，不安装 |
| `kp update force` | 直接安装，不询问 |
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

### 只让面板走 IPv6（推荐，最轻量）

不想全局禁 IPv4，只希望探针走 IPv6 —— 选菜单 10，或：

```bash
kp lockv6 你的面板域名
```

它会查该域名的 AAAA 记录，写进 `/etc/hosts` 并重启探针。**不动路由、不动 DNS、不影响其他 IPv4 访问**，因此也不会有「续约后恢复」的问题。

撤销：

```bash
kp lockv6 off
```

> 前提：面板域名有 AAAA 记录，且 IPv6 地址相对稳定。套 Cloudflare 的域名 IP 会变，不适合这种方式。

---

## 注意

- **切换是运行时改动，dhcpcd 续约（约 28 分钟）或重启后 IPv4 默认路由会自动装回来** —— 要长期保持请选菜单 9 或跑 `kp persist`
- 动手前确认有服务商的 VNC / 控制台，并确保 `ssh -6` 能连进来
- `kp block` 需要 `NET_ADMIN` 权限，容器里没有的话用 `kp keep`
- 脚本改的是运行时状态，重启失效；要持久化在 `/etc/dhcpcd.conf` 加 `nogateway`
- DNS 最多生效 3 个 nameserver（glibc MAXNS），所以 `kp fix` 只写 3 个
- 服务名不同时用 `KP_AGENT=实际服务名 kp restart`；内网网段不同时用 `KP_LAN=x.x.x.x/x`

---

## License

MIT
