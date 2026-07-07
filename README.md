# dns解析

一键把 Linux 服务器部署成 **DNS 解析服务器**，让其他服务器把这台服务器设置为 DNS 服务器使用。

底层组件：**CoreDNS**。

## 功能

- 一键安装 CoreDNS
- 自动生成 DNS 转发/缓存配置
- 支持本地域名解析
- systemd 开机自启
- 自动尝试放行 53 UDP/TCP 端口
- 安装完成后输出 `服务器IP:53`

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

安装完成后会输出类似：

```text
DNS 地址: 1.2.3.4:53
其他服务器 nameserver: 1.2.3.4
```

## 其他服务器如何使用

假设 DNS 服务器 IP 是 `1.2.3.4`：

```bash
echo 'nameserver 1.2.3.4' | sudo tee /etc/resolv.conf
```

测试：

```bash
dig @1.2.3.4 example.com
nslookup example.com 1.2.3.4
```

> 注意：只设置 DNS 只会改变域名解析，不会改变普通网络流量出口。如果需要让其他服务器所有流量走这台服务器，还需要额外配置网关/NAT。

## 自定义上游 DNS

安装时可指定上游 DNS：

```bash
UPSTREAM_DNS="223.5.5.5 119.29.29.29" sudo ./install.sh
```

默认上游：

```text
223.5.5.5 223.6.6.6 119.29.29.29 8.8.8.8 1.1.1.1
```

## 指定监听端口

默认监听 53：

```bash
DNS_PORT=5353 sudo ./install.sh
```

如果不是 53，客户端测试时要指定端口，例如：

```bash
dig @1.2.3.4 -p 5353 example.com
```

## 添加本地域名解析

编辑 `install.sh` 中的 `LOCAL_RECORDS`：

```bash
LOCAL_RECORDS=(
  "git.local 192.168.1.10"
  "nas.local 192.168.1.20"
)
```

然后重新运行安装脚本。

## 管理命令

```bash
# 查看状态
systemctl status coredns

# 查看日志
journalctl -u coredns -f

# 重启
systemctl restart coredns

# 查看配置
cat /etc/coredns/Corefile
cat /etc/coredns/hosts
```

## 一键卸载

```bash
curl -fsSL https://raw.githubusercontent.com/wangjialiangsaa/dns-/main/uninstall.sh -o uninstall.sh
chmod +x uninstall.sh
sudo ./uninstall.sh
```

## 云服务器安全组

如果部署在云服务器，需要在安全组放行：

- UDP 53
- TCP 53

否则其他服务器可能无法访问 DNS 服务。

## 许可证

MIT
