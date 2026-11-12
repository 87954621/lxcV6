# kp

VPS 纯 IPv6 切换 / 让探针面板不再显示本机 IPv4。单文件脚本，自动识别 Komari 与哪吒 Nezha v2。

![](https://img.shields.io/badge/version-1.9.1-blue) ｜ 更新：`kp update`


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

> 若报 `cannot execute: required file not found`，文件是 Windows 行尾（CRLF），跑一次：
> `tr -d '\r' < /usr/local/bin/kp > /tmp/kp && cat /tmp/kp > /usr/local/bin/kp && chmod +x /usr/local/bin/kp && rm -f /tmp/kp`
> 脚本自更新已内置清洗，不会再把坏文件装回去。

---


## 怎么用

直接跑 `kp` 进菜单：

```text
1 查看当前状态      2 探测能否纯 IPv6（自动还原）
3 切换出网模式      4 修复 DNS
5 重启探针          6 IPv4 出站封堵
7 屏蔽面板 IPv4     8 持久化
9 检查更新          0 退出
```

**第一次用按 1 → 2 → 3 → 8 走**：先看状态，再探测（自动还原，最安全），确认没问题再切，最后开持久化，免得 dhcpcd 续约把 IPv4 装回来。

菜单里 IPv6 显示 `n/a / 出网不可用` 时，脚本会提示**先重启一次服务器**；重启后还不行再查母机有没有给本机分配 IPv6。这时候别切 IPv6-only。

## 命令

| 命令 | 作用 |
| --- | --- |
| `kp check` | 探测纯 IPv6 能否存活，结束自动还原 |
| `kp keep` | 探测后直接切到 IPv6-only |
| `kp restore` | 恢复 IPv4 出站 |
| `kp fix` | 换 IPv6 DNS |
| `kp nic off` | 面板不再显示本机 IPv4 |
| `kp nic off --exclude` | 没有纯 IPv6 网卡时改用排除法 |
| `kp nic on` | 恢复上报 IPv4 |
| `kp block` / `kp unblock` | 禁止 / 放开 IPv4 出站 |
| `kp persist` / `kp persist off` | 开机保持 / 取消 |
| `kp restart` | 重启探针 |
| `kp status` | 查看当前网络状态 |
| `kp update` | 检查并安装更新 |
| `kp unlock` | 清理旧版 hosts 记录 |

## 只想隐藏面板上的 IPv4

```bash
kp nic off
```

面板显示的是 agent 上报的网卡地址，改路由、DNS 都没用，只能改 agent 的网卡过滤 —— 这条命令会自动识别 Komari / 哪吒并改好，改前会备份。面板不会立刻刷新，等几分钟或 `kp restart`。

全部还原：

```bash
kp restore && kp unblock && kp persist off && kp nic on
```

