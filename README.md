# kp

VPS 纯 IPv6 切换脚本，配合 Komari 探针使用。

> 前置：机器已安装 Komari 探针。

---

## 安装

```bash
wget -qO /usr/local/bin/kp https://raw.githubusercontent.com/87954621/lxcV6/main/kp.sh \
  && chmod +x /usr/local/bin/kp
```

没有 `wget` 用 curl：

```bash
curl -fsSL https://raw.githubusercontent.com/87954621/lxcV6/main/kp.sh \
  -o /usr/local/bin/kp && chmod +x /usr/local/bin/kp
```

国内网络走镜像：

```bash
wget -qO /usr/local/bin/kp https://cdn.jsdelivr.net/gh/87954621/lxcV6@main/kp.sh \
  && chmod +x /usr/local/bin/kp
```

---

## 使用

| 命令 | 作用 |
| --- | --- |
| `kp` | 探测能否纯 IPv6 存活，退出自动还原（最安全，先跑这个） |
| `kp keep` | 探测后不还原，直接切到 IPv6-only |
| `kp fix` | 换成 IPv6 DNS 并重启探针 |
| `kp block` | iptables 硬性禁止 IPv4 出站 |
| `kp unblock` | 撤除封堵 |
| `kp status` | 查看当前网络状态 |
| `kp help` | 帮助 |

### 典型流程

```bash
PANEL=你的面板域名 kp     # 探测，看完结论再决定
kp keep                  # 切到 IPv6-only
kp fix                   # 重启探针，让它走 IPv6
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
