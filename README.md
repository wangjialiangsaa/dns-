# DNS 解析服务器

一键把 Linux 服务器部署为自托管 DNS 解析服务器。默认使用安全的 `simple` 模式：其他服务器只需把 nameserver 指向本机即可使用。

底层组件：CoreDNS + nftables。支持 Ubuntu、Debian、CentOS、Rocky Linux、AlmaLinux、RHEL、Fedora 和 Amazon Linux。

## 主要特性

- CoreDNS 递归转发、缓存和本地 hosts 记录
- 默认白名单访问控制，同时支持指定公网客户端
- 安装前保存原系统状态，卸载时精准恢复
- nftables 使用独立 systemd 服务，不修改全局 `/etc/nftables.conf`
- CoreDNS 官方 SHA256 强制校验
- CoreDNS 以专用非登录用户运行，健康检查和指标只监听回环地址
- 客户端只修改一种 DNS 后端，并支持 `--restore` 一键恢复
- 端口冲突默认中止，不再强杀未知进程

## 一键安装

默认只允许常见私网段和本机访问：

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/install.sh -o install.sh && chmod +x install.sh && sudo ./install.sh
```

安装完成后会输出 `服务器IP:53`。云服务器还需在安全组放行 UDP/TCP 53，并建议限制来源地址。

### 放行指定公网客户端

```bash
ALLOW_IPS="1.2.3.4 5.6.7.8" sudo -E ./install.sh
```

支持单 IP 和 CIDR：

```bash
ALLOW_IPS="1.2.3.4 5.6.7.0/24" sudo -E ./install.sh
```

### 自动放行所有来源

带每源 IPv4 地址限速：

```bash
AUTO_ALLOW=true RATE_LIMIT=30 sudo -E ./install.sh
```

完全不限速开放：

```bash
AUTO_ALLOW=true RATE_LIMIT=0 sudo -E ./install.sh
```

也可不创建 nftables ACL：

```bash
RESTRICT_DNS=false sudo -E ./install.sh
```

> 公网开放递归 DNS 可能被用于反射放大攻击。即使脚本不限速，也应优先使用云安全组限制来源。

## 客户端接入

假设 DNS 服务器地址为 `10.0.0.10`：

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/client-setup.sh -o client-setup.sh && chmod +x client-setup.sh && sudo ./client-setup.sh 10.0.0.10
```

主备 DNS：

```bash
sudo ./client-setup.sh 10.0.0.10 10.0.0.11
```

脚本会先验证 DNS 可达性，然后只选择一种配置后端：NetworkManager、systemd-resolved 或 `/etc/resolv.conf`。配置失败会自动恢复。

恢复客户端原配置：

```bash
sudo ./client-setup.sh --restore
```

验证：

```bash
dig @10.0.0.10 example.com
```

## gateway 模式（高风险，可选）

仅当客户端与 DNS 服务器位于可直连网段，并确实需要修改默认网关、劫持标准 53 端口时使用：

```bash
MODE=gateway ENABLE_GATEWAY=true GATEWAY_NETS="10.0.0.0/24" sudo -E ./install.sh
```

客户端必须显式双重确认：

```bash
sudo ./client-setup.sh 10.0.0.10 --gateway --confirm-gateway
```

gateway 规则只处理 `GATEWAY_NETS`，不会劫持本机上游 DNS。DoH（443）和 DoT（853）不受标准 DNS 劫持影响。

## 端口冲突

`systemd-resolved` 的本地 Stub 可由脚本安全处理并在卸载时恢复。其他服务占用 DNS 端口时，默认中止安装：

```bash
ss -lntup | grep :53
```

只有明确确认冲突服务可以停止时才使用：

```bash
FORCE_STOP_CONFLICT=true sudo -E ./install.sh
```

脚本仅会停止可识别的 `named`、`dnsmasq`、`unbound` 或 systemd-resolved 服务，不会强杀未知进程；卸载时会尝试重新启动被停止的服务。

## 配置变量

| 变量 | 说明 | 默认值 |
|---|---|---|
| `MODE` | `simple` 或 `gateway` | `simple` |
| `DNS_PORT` | DNS 监听端口 | `53` |
| `LISTEN_ADDR` | DNS 监听地址 | `0.0.0.0` |
| `UPSTREAM_DNS` | 上游 DNS，空格分隔 | 阿里、腾讯及公共 DNS |
| `CACHE_TTL` | 缓存秒数 | `300` |
| `COREDNS_VERSION` | 固定版本或 `latest` | `1.14.6` |
| `MIRROR_PREFIX` | CoreDNS 下载镜像前缀 | 空 |
| `ALLOW_NETS` | 允许访问的 IPv4 网段 | 私网三段和 127/8 |
| `ALLOW_IPS` | 额外允许的 IPv4/CIDR | 空 |
| `RESTRICT_DNS` | 是否启用白名单 ACL | `true` |
| `AUTO_ALLOW` | 是否自动放行其他 IPv4 来源 | `false` |
| `RATE_LIMIT` | 自动放行时每源 IP 每秒包数，0 为不限 | `30` |
| `FORCE_STOP_CONFLICT` | 是否停止可识别的端口冲突服务 | `false` |
| `ENABLE_GATEWAY` | gateway 模式显式确认 | `false` |
| `GATEWAY_NETS` | gateway 允许劫持/NAT 的源网段 | `ALLOW_NETS` |
| `ENABLE_NAT` | gateway 是否启用 masquerade | `true` |
| `WAN_IFACE` | gateway 外网接口 | 自动检测 |

当前实现只处理 IPv4。

## 管理命令

```bash
systemctl status coredns
journalctl -u coredns -f
systemctl restart coredns
nft list table inet dns_force
curl -s http://127.0.0.1:8080/health
```

安装状态和首次安装前快照保存在：

```text
/var/lib/coredns-installer/
```

请勿在需要恢复前手动删除该目录。

## 一键卸载与恢复

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/uninstall.sh -o uninstall.sh && chmod +x uninstall.sh && sudo ./uninstall.sh
```

免确认：

```bash
sudo ./uninstall.sh -y
```

新版安装会恢复首次安装前的 CoreDNS 二进制与配置、systemd 单元、同名 nftables 表、systemd-resolved、`resolv.conf`、IPv4 转发值和本脚本新增的防火墙端口。若恢复失败，状态快照会保留供人工处理。

旧版安装没有状态快照时，卸载脚本采用保守兼容模式，不修改无法确认归属的宿主网络设置。

## 许可证

MIT
