#!/bin/bash
# ============================================================
# DNS 解析服务器一键卸载脚本 (CoreDNS + nftables)
# ============================================================

set -euo pipefail

SERVICE_NAME="coredns"
APP_DIR="/etc/coredns"
COREDNS_BIN="/usr/local/bin/coredns"
DNS_PORT="${DNS_PORT:-53}"
NFT_TABLE="dns_force"

COLOR_GREEN="\033[0;32m"
COLOR_RED="\033[0;31m"
COLOR_RESET="\033[0m"

log_info()  { echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $1"; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"; }

if [ "${EUID}" -ne 0 ]; then
    log_error "请使用 root 或 sudo 运行"
    exit 1
fi

echo -n "确认卸载 DNS 解析服务器吗？[y/N] "
read -r confirm
if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
    log_info "已取消卸载"
    exit 0
fi

# 停止 CoreDNS
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload 2>/dev/null || true

# 删除 nftables 劫持表
if command -v nft >/dev/null 2>&1; then
    nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
    nft list ruleset > /etc/nftables.conf 2>/dev/null || true
    systemctl reload nftables 2>/dev/null || systemctl restart nftables 2>/dev/null || true
    log_info "nftables DNS 劫持表已删除"
fi

# 禁用 IP 转发
sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
if [ -f /etc/sysctl.conf ] && grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
    sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=0/' /etc/sysctl.conf
fi

# 删除文件
rm -rf "${APP_DIR}"
rm -f "${COREDNS_BIN}"

# 恢复防火墙
if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${DNS_PORT}"/udp 2>/dev/null || true
    ufw delete allow "${DNS_PORT}"/tcp 2>/dev/null || true
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw 2>/dev/null || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${DNS_PORT}"/udp 2>/dev/null || true
    firewall-cmd --permanent --remove-port="${DNS_PORT}"/tcp 2>/dev/null || true
    firewall-cmd --permanent --remove-masquerade 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
fi

log_info "DNS 解析服务器已卸载"
