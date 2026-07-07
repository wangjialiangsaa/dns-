# dns解析

一键把 Linux 服务器部署成 **DNS 解析服务器 + DNS 强制劫持网关**，让其他服务器强制走本机 DNS 解析。

底层组件：**CoreDNS + nftables**。

## 工作原理

```text
其他服务器 --[DNS请求:53]--> 本机(nftables劫持) --> CoreDNS --> 上游DNS
                |
                +-- 即使写了 8.8.8.8，也会被强制转到本机 CoreDNS
```

1. **CoreDNS** 监听 53 端口，提供 DNS 解析和缓存
2. **nftables** 劫持所有经过本机的 53 端口请求，强制转到本机 CoreDNS
3. **NAT 网关** 让其他服务器把网关指向本机，所有流量经过本机

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

安装完成后会输出：

```text
DNS 地址: 服务器IP:53
DNS 劫持: 已启用 (所有 53 端口请求强制转到本机)
NAT 网关: true
```

## 其他服务器如何被强制走本机 DNS

### 方式1：设置网关（硬强制，推荐）

其他服务器执行：

```bash
# 设置网关为本机
sudo ip route replace default via 服务器IP

# 设置 DNS 为本机
echo 'nameserver 服务器IP' | sudo tee /etc/resolv.conf
```

这样即使其他服务器后来改了 DNS 写 `8.8.8.8`，只要流量经过本机网关，53 端口请求都会被 nftables 劫持到本机 CoreDNS。

### 方式2：仅设置 DNS（软强制）

```bash
echo 'nameserver 服务器IP' | sudo tee /etc/resolv.conf
```

### 验证

在其他服务器上测试：

```bash
# 即使指定 8.8.8.8，也会被劫持到本机 CoreDNS
dig @8.8.8.8 example.com
nslookup example.com 8.8.8.8

# 正常查询
dig example.com
```

## 配置说明

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `DNS_PORT` | DNS 监听端口 | `53` |
| `UPSTREAM_DNS` | 上游 DNS | `223.5.5.5 223.6.6.6 119.29.29.29 8.8.8.8 1.1.1.1` |
| `FORCE_DNS` | 是否启用 DNS 劫持 | `true` |
| `ENABLE_NAT` | 是否启用 NAT 网关 | `true` |
| `WAN_IFACE` | 外网网卡（留空自动检测） | 自动检测 |

## 自定义本地域名

编辑 `install.sh` 中的 `LOCAL_RECORDS`：

```bash
LOCAL_RECORDS=(
  "git.local 192.168.1.10"
  "nas.local 192.168.1.20"
)
```

## 管理命令

```bash
# CoreDNS 状态
systemctl status coredns
journalctl -u coredns -f

# 查看 nftables 劫持规则
nft list table inet dns_force

# 查看完整 nftables 规则
nft list ruleset

# 查看 IP 转发
cat /proc/sys/net/ipv4/ip_forward

# 重启 CoreDNS
systemctl restart coredns
```

## 一键卸载

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/uninstall.sh -o uninstall.sh
chmod +x uninstall.sh
sudo ./uninstall.sh
```

## 注意事项

- **网关模式**：其他服务器必须把网关指向本机，DNS 劫持才会生效
- **单网卡**：单网卡也能用，但需要其他服务器和本机在同一网段
- **云服务器**：安全组需放行 UDP/TCP 53
- **DoH/DoT**：DNS 劫持只对标准 53 端口有效，DoH(443)/DoT(853) 无法劫持
- **备份**：安装前建议备份现有 nftables 规则：`sudo nft list ruleset > nftables.backup`

## 许可证

MIT
