# dns 解析服务器

一键把 Linux 服务器部署成 **DNS 解析服务器**，让其他服务器把它当作 nameserver 来解析域名。

底层组件：**CoreDNS + nftables**。默认即开即用的 **simple 模式**，另提供可选的 gateway 强制劫持模式。

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| **simple**（默认） | CoreDNS 解析/缓存 + nftables 访问控制(ACL) | 其他服务器把 DNS 指向本机即可，**最常用** |
| **gateway** | CoreDNS + nftables 劫持所有 53 流量 + NAT 网关 | 需要强制其他服务器走本机 DNS，即使它们写死 8.8.8.8 也被劫持 |

## 工作原理（simple 模式）

```text
其他服务器 --[nameserver 指向本机]--> 本机 CoreDNS(:53) --> 上游 DNS
                                          |
                          解析 + 缓存 + 本地域名(hosts)
```

1. **CoreDNS** 监听 53 端口，提供递归解析 + 缓存 + 本地域名
2. **nftables ACL** 只放行白名单来源查询本机 DNS，其余丢弃（可关闭）
3. 其他服务器把 `nameserver` 指向本机 IP 即可使用

## 一键安装（服务端）

**默认 simple 模式（仅 DNS + ACL）：**

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

安装完成后会输出 `DNS 地址: 服务器IP:53`，并把安装信息写入 `/etc/coredns/install-info.txt`。

### 放行公网客户端

默认 ACL 只放行私网段（`192.168/16`、`10/8`、`172.16/12`）。如果接入的是**公网 IP 的服务器**，用 `ALLOW_IPS` 把它们的公网 IP 加进白名单：

```bash
ALLOW_IPS="1.2.3.4 5.6.7.8" sudo -E ./install.sh
```

或者对所有来源开放（**慎用**，公网开放 DNS 可能被滥用做 DDoS 反射，务必配合云安全组限制来源）：

```bash
RESTRICT_DNS=false sudo -E ./install.sh
```

### 可选：gateway 强制劫持模式

只有当你需要"客户端即使写死 8.8.8.8 也强制走本机 DNS"时才用：

```bash
MODE=gateway sudo -E ./install.sh
```

## 其他服务器如何接入（客户端）

假设 DNS 服务器 IP 是 `10.0.0.10`。最简单的方式就是把 nameserver 指过来：

```bash
echo 'nameserver 10.0.0.10' | sudo tee /etc/resolv.conf
```

配套的 `client-setup.sh` 会自动适配 systemd-resolved / resolv.conf / NetworkManager，避免重启后被覆盖：

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/client-setup.sh -o client-setup.sh
chmod +x client-setup.sh
sudo ./client-setup.sh 10.0.0.10
# 主备 DNS：
# sudo ./client-setup.sh 10.0.0.10 10.0.0.11
```

> `--gateway` 参数仅在服务端用 gateway 模式时才需要（同时改默认网关做硬强制）。simple 模式下不要加。

### 验证

```bash
# 从客户端查询本机 DNS
dig @10.0.0.10 example.com

# 指定端口（若非 53）
dig @10.0.0.10 -p 53 example.com
```

## 配置变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `MODE` | 部署模式 `simple` / `gateway` | `simple` |
| `DNS_PORT` | DNS 监听端口 | `53` |
| `LISTEN_ADDR` | 监听地址 | `0.0.0.0` |
| `UPSTREAM_DNS` | 上游 DNS | `223.5.5.5 223.6.6.6 119.29.29.29 8.8.8.8 1.1.1.1` |
| `CACHE_TTL` | 缓存秒数 | `300` |
| `COREDNS_VERSION` | `latest` 或指定版本号 | `latest` |
| `MIRROR_PREFIX` | 下载加速前缀 | 空 |
| `ALLOW_NETS` | simple 模式允许查询的源网段 | 私网三段 + 127 |
| `ALLOW_IPS` | simple 模式额外放行的客户端 IP（公网服务器写这里） | 空 |
| `RESTRICT_DNS` | `true`=按白名单限制；`false`=对所有来源开放 | `true` |
| `ENABLE_NAT` | gateway 模式是否启用 NAT 网关 | `true` |
| `WAN_IFACE` | gateway 模式外网网卡（留空自动检测） | 自动检测 |

示例：

```bash
UPSTREAM_DNS="1.1.1.1 8.8.8.8" \
ALLOW_IPS="1.2.3.4 5.6.7.8" \
sudo -E ./install.sh
```

## 自定义本地域名

编辑 `install.sh` 中的 `LOCAL_RECORDS`：

```bash
LOCAL_RECORDS=(
  "git.local 192.168.1.10"
  "nas.local 192.168.1.20"
)
```

安装后写入 `/etc/coredns/hosts`。

## 端口 53 占用

安装时若 53 被占用（常见是 `systemd-resolved` stub），脚本会自动：

1. 关闭 `DNSStubListener`
2. 停止占用 53 的服务/进程（named/dnsmasq/unbound 等）
3. 释放后再启动 CoreDNS

## 管理命令

```bash
# CoreDNS 状态与日志
systemctl status coredns
journalctl -u coredns -f
systemctl restart coredns

# 查看 ACL / 劫持规则
nft list table inet dns_force

# 健康检查
curl -s http://127.0.0.1:8080/health
```

## 一键卸载

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/uninstall.sh -o uninstall.sh
chmod +x uninstall.sh
sudo ./uninstall.sh          # 交互确认，-y 免确认
```

卸载会清理 CoreDNS、systemd 服务、nftables 表、防火墙放行（gateway 模式还会恢复 IP 转发）。

## 注意事项

- **公网开放 DNS 风险**：把 DNS 暴露到公网（`RESTRICT_DNS=false` 或放行公网 IP）可能被用作 DNS 反射放大攻击的跳板。务必用 `ALLOW_IPS` 精确放行，并在云安全组同样限制来源 IP。
- **云服务器**：安全组需放行 UDP/TCP 53，且入站来源最好限制为你的客户端 IP。
- **gateway 模式**：其他服务器必须把默认网关指向本机，DNS 劫持才对写死的公共 DNS 生效。
- **DoH/DoT**：劫持只对标准 53 端口有效，DoH(443)/DoT(853) 无法劫持。
- **备份**：安装前建议备份现有 nftables 规则：`sudo nft list ruleset > nftables.backup`。

## 许可证

MIT
