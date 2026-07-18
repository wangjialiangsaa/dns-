#!/usr/bin/env bash
# ============================================================
# DNS 解析服务器一键卸载 (CoreDNS + nftables)
# 同时清理 gateway(劫持+NAT) 与 simple(ACL) 两种模式的残留。
#
# 用法:
#   sudo ./uninstall.sh          # 交互确认
#   sudo ./uninstall.sh -y       # 免确认
#   FORCE=1 sudo -E ./uninstall.sh
# ============================================================
set -euo pipefail

SERVICE_NAME="coredns"
APP_DIR="/etc/coredns"
COREDNS_BIN="/usr/local/bin/coredns"
COREFILE="${APP_DIR}/Corefile"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/disable-stub.conf"
SYSCTL_DROPIN="/etc/sysctl.d/99-dns-gateway.conf"
DNS_PORT="${DNS_PORT:-53}"

# 可能存在的 nftables 表名（新旧/两种模式都清）
NFT_TABLES="${NFT_TABLE:-} dns_force dns_gateway"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
log_info(){ echo -e "${G}[INFO]${N} $*" >&2; }
log_warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
log_error(){ echo -e "${R}[ERROR]${N} $*" >&2; }
log_step(){ echo -e "${C}[STEP]${N} $*" >&2; }
log_ok(){ echo -e "${G}[ OK ]${N} $*" >&2; }
die(){ log_error "$*"; exit 1; }

require_root(){ [[ ${EUID} -eq 0 ]] || die "请使用 root 或 sudo 运行"; }

confirm(){
    if [[ "${FORCE:-}" == "1" || "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
        return
    fi
    echo -n "确认卸载 DNS 解析服务器? [y/N] "
    read -r c
    [[ "${c}" == "y" || "${c}" == "Y" ]] || { log_info "已取消"; exit 0; }
}

load_dns_port(){
    if [[ -f "${COREFILE}" ]]; then
        local p
        p=$(grep -oE '^\.:[0-9]+' "${COREFILE}" 2>/dev/null | head -1 | cut -d: -f2) || true
        [[ -n "${p}" ]] && DNS_PORT="${p}"
    fi
}

main(){
    echo "" >&2
    log_info "##################################################"
    log_info "#  DNS 解析服务器卸载 (CoreDNS + nftables)"
    log_info "##################################################"
    echo "" >&2
    require_root
    confirm "${1:-}"
    load_dns_port

    log_step "停止并禁用服务..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null || true
    log_ok "systemd 已清理"

    log_step "删除 CoreDNS 文件..."
    rm -f "${COREDNS_BIN}"
    rm -rf "${APP_DIR}"
    log_ok "CoreDNS 文件已清理"

    if command -v nft >/dev/null 2>&1; then
        log_step "清理 nftables 表..."
        local t
        for t in ${NFT_TABLES}; do
            [[ -z "${t}" ]] && continue
            nft delete table inet "${t}" 2>/dev/null || true
            rm -f "/etc/nftables.d/${t}.nft" 2>/dev/null || true
            if [[ -f /etc/nftables.conf ]]; then
                sed -i "\|nftables.d/${t}.nft|d" /etc/nftables.conf 2>/dev/null || true
            fi
        done
        systemctl reload nftables 2>/dev/null || systemctl restart nftables 2>/dev/null || true
        log_ok "nftables 表已清理"
    fi

    log_step "关闭 IPv4 转发..."
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    rm -f "${SYSCTL_DROPIN}" 2>/dev/null || true
    if [[ -f /etc/sysctl.conf ]] && grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=0/' /etc/sysctl.conf
    fi
    log_ok "IPv4 转发已关闭"

    log_step "恢复防火墙放行..."
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${DNS_PORT}"/udp 2>/dev/null || true
        ufw delete allow "${DNS_PORT}"/tcp 2>/dev/null || true
        sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw 2>/dev/null || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${DNS_PORT}/udp" 2>/dev/null || true
        firewall-cmd --permanent --remove-port="${DNS_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --permanent --remove-masquerade 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi

    if [[ -f "${RESOLVED_DROPIN}" ]]; then
        log_step "恢复 systemd-resolved Stub..."
        rm -f "${RESOLVED_DROPIN}"
        systemctl restart systemd-resolved 2>/dev/null || true
        log_ok "已移除 ${RESOLVED_DROPIN}"
    fi

    echo "" >&2
    log_ok "卸载完成"
    log_warn "如客户端曾用 --gateway 改过默认网关，请到客户端手动回滚: ip route replace default via <原网关>"
    echo "" >&2
}

main "$@"
