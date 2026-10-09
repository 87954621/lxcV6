# kp

VPS 纯 IPv6 切换脚本，配合 Komari 探针使用。

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
════════ kp · 纯 IPv6 切换 ════════

  1) 查看当前状态
  2) 探测能否纯 IPv6（自动还原，安全）
  3) 切换到 IPv6-only
  4) 修复 DNS 并重启探针
  5) 禁止 IPv4 出站（iptables）
  6) 撤除封堵
  0) 退出

  提示：第一次用建议先选 1 看状态，再选 2 探测
```

危险操作（3、5）会先问一次 `y/N` 再执行。

也支持非交互调用：

| 命令 | 作用 |
| --- | --- |
| `kp` | 交互式菜单（默认） |
| `kp check` | 探测能否纯 IPv6 存活，结束自动还原（最安全） |
| `kp keep` | 探测后不还原，直接切到 IPv6-only |
| `kp fix` | 换成 IPv6 DNS 并重启探针 |
| `kp block` | iptables 硬性禁止 IPv4 出站 |
| `kp unblock` | 撤除封堵 |
| `kp status` | 查看当前网络状态 |
| `kp help` | 帮助 |

### 典型流程

```bash
PANEL=你的面板域名 kp check   # 探测，看完结论再决定
kp keep                      # 切到 IPv6-only
kp fix                       # 重启探针，让它走 IPv6
```

### 常用

```bash
kp status                           # 随时看状态
systemctl restart komari-agent      # systemd 重启探针
rc-service komari-agent restart     # Alpine 重启探针
```

---

## 注意

- 动手前确认有服务商的 VNC / 控制台，并确保 `ssh -6` 能连进来
- `kp block` 需要 `NET_ADMIN` 权限，容器里没有的话用 `kp keep`
- 脚本改的是运行时状态，重启失效；要持久化在 `/etc/dhcpcd.conf` 加 `nogateway`

---

## License

MIT
