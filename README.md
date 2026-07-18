# dns 解析服务器

一键把 Linux 服务器部署成 **DNS 解析服务器**，让其他服务器强制走本机 DNS 解析。

底层组件：**CoreDNS + nftables**。支持两种模式：

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| **gateway**（默认） | CoreDNS 解析/缓存 + nftables 劫持所有 53 端口流量 + NAT 网关 | 强制其他服务器走本机 DNS，**即使它们写死 8.8.8.8 也会被劫持** |
| **simple** | CoreDNS 解析/缓存 + nftables 访问控制(ACL) | 其他服务器只把 DNS 指过来即可（软强制），不改上网出口 |

## 工作原理（gateway 模式）

```text
其他服务器 --[默认网关指向本机]--> 本机(nftables 劫持 53) --> CoreDNS --> 上游DNS
                                        |
                +--即使客户端写死 8.8.8.8，53 请求也会被强制 DNAT 到本机 CoreDNS
```

1. **CoreDNS** 监听 53 端口，提供解析 + 缓存 + 本地域名
2. **nftables prerouting** 劫持所有经过本机转发的 53 请求 → 本机 CoreDNS
3. **nftables output** 劫持本机自身发往外部的 53 请求 → 本机 CoreDNS（排除回环）
4. **NAT masquerade** 让其他服务器把网关指向本机后可正常上网

## 一键安装（服务端）

**默认 gateway 模式（强制劫持 + NAT）：**

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

**simple 模式（仅 DNS + ACL）：**

```bash
MODE=simple sudo -E ./install.sh
```

安装完成后会输出 `DNS 地址: 服务器IP:53`，并把安装信息写入 `/etc/coredns/install-info.txt`。

## 其他服务器如何接入（客户端）

配套的 `client-setup.sh` 会自动适配 systemd-resolved / resolv.conf / NetworkManager，并移除原有公共 DNS。

假设 DNS 服务器 IP 是 `10.0.0.10`：

### 硬强制（配合 gateway 模式，推荐）

同时改 DNS + 默认网关，让流量经过本机被劫持：

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/client-setup.sh -o client-setup.sh
chmod +x client-setup.sh
sudo ./client-setup.sh 10.0.0.10 --gateway
```

> ⚠️ `--gateway` 会修改默认网关。请先确认服务端已启用 IP 转发与 NAT（gateway 模式默认已开），否则客户端会断网。脚本会打印原网关，便于回滚。

### 软强制（仅改 DNS）

```bash
sudo ./client-setup.sh 10.0.0.10
# 主备 DNS：
# sudo ./client-setup.sh 10.0.0.10 10.0.0.11
```

### 手动方式

```bash
# 软强制：只改 DNS
echo 'nameserver 10.0.0.10' | sudo tee /etc/resolv.conf

# 硬强制：改网关 + DNS
sudo ip route replace default via 10.0.0.10
echo 'nameserver 10.0.0.10' | sudo tee /etc/resolv.conf
```

### 验证

```bash
# 正常查询
dig @10.0.0.10 example.com

# gateway 模式下，即使指定 8.8.8.8 也会被劫持到本机 CoreDNS
dig @8.8.8.8 example.com
```

## 配置变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `MODE` | 部署模式 `gateway` / `simple` | `gateway` |
| `DNS_PORT` | DNS 监听端口 | `53` |
| `LISTEN_ADDR` | 监听地址 | `0.0.0.0` |
| `UPSTREAM_DNS` | 上游 DNS | `223.5.5.5 223.6.6.6 119.29.29.29 8.8.8.8 1.1.1.1` |
| `CACHE_TTL` | 缓存秒数 | `300` |
| `COREDNS_VERSION` | `latest` 或指定版本号 | `latest` |
| `MIRROR_PREFIX` | 下载加速前缀 | 空 |
| `ENABLE_NAT` | gateway 模式是否启用 NAT 网关 | `true` |
| `WAN_IFACE` | 外网网卡（留空自动检测） | 自动检测 |
| `ALLOW_NETS` | simple 模式允许查询的源网段 | 私网三段 + 127 |
| `RESTRICT_DNS` | simple 模式是否按 ALLOW_NETS 限制 | `true` |

示例：

```bash
MODE=simple \
UPSTREAM_DNS="1.1.1.1 8.8.8.8" \
ALLOW_NETS="10.0.0.0/8 127.0.0.0/8" \
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

# 查看劫持/ACL 规则
nft list table inet dns_force

# 查看完整 nftables 规则
nft list ruleset

# 查看 IP 转发状态
cat /proc/sys/net/ipv4/ip_forward

# 健康检查
curl -s http://127.0.0.1:8080/health
```

## 一键卸载

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/uninstall.sh -o uninstall.sh
chmod +x uninstall.sh
sudo ./uninstall.sh          # 交互确认，-y 免确认
```

卸载会清理 CoreDNS、systemd 服务、nftables 表、IP 转发和防火墙放行。若客户端曾用 `--gateway` 改过网关，需到客户端手动回滚。

## 注意事项

- **gateway 模式**：其他服务器必须把默认网关指向本机，DNS 劫持才对"写死的公共 DNS"生效；仅改 nameserver 属于软强制。
- **单网卡**：单网卡也能用，但客户端与本机需在同一网段可互通。
- **云服务器**：安全组需放行 UDP/TCP 53；gateway 模式还需允许内网互通。
- **DoH/DoT**：劫持只对标准 53 端口有效，DoH(443)/DoT(853) 无法劫持。
- **备份**：安装前建议备份现有 nftables 规则：`sudo nft list ruleset > nftables.backup`。

## 许可证

MIT
