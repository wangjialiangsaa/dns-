#!/bin/bash
# ============================================================
# 一键部署 DNS 解析服务器 (CoreDNS)
# 目标: 让其他服务器把本机设置为 DNS 解析服务器
# 支持: Ubuntu / Debian / CentOS 8+ / Rocky / Alma
# ============================================================

set -euo pipefail

SERVICE_NAME="coredns"
APP_DIR="/etc/coredns"
COREDNS_BIN="/usr/local/bin/coredns"
COREDNS_VERSION="${COREDNS_VERSION:-1.11.3}"
DNS_PORT="${DNS_PORT:-53}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
UPSTREAM_DNS="${UPSTREAM_DNS:-223.5.5.5 223.6.6.6 119.29.29.29 8.8.8.8 1.1.1.1}"

# 本地域名记录，可按需修改。格式: "域名 IP"
LOCAL_RECORDS=(
    # "git.local 192.168.1.10"
    # "nas.local 192.168.1.20"
)

COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[0;31m"
COLOR_CYAN="\033[0;36m"
COLOR_RESET="\033[0m"

log_info()  { echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $1"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"; }
log_step()  { echo -e "${COLOR_CYAN}[STEP]${COLOR_RESET} $1"; }

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        log_error "请使用 root 或 sudo 运行"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_NAME="${PRETTY_NAME}"
    else
        log_error "无法识别操作系统"
        exit 1
    fi
    log_info "检测到系统: ${OS_NAME}"
}

detect_arch() {
    local machine
    machine=$(uname -m)
    case "${machine}" in
        x86_64|amd64) COREDNS_ARCH="amd64" ;;
        aarch64|arm64) COREDNS_ARCH="arm64" ;;
        armv7l|armv6l) COREDNS_ARCH="arm" ;;
        *)
            log_error "暂不支持 CPU 架构: ${machine}"
            exit 1
            ;;
    esac
    log_info "检测到架构: ${machine} -> ${COREDNS_ARCH}"
}

install_dependencies() {
    log_step "安装依赖..."
    case "${OS_ID}" in
        ubuntu|debian)
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar ca-certificates dnsutils
            ;;
        centos|rocky|almalinux|rhel)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y curl tar ca-certificates bind-utils
            else
                yum install -y curl tar ca-certificates bind-utils
            fi
            ;;
        *)
            log_error "不支持的系统: ${OS_ID}"
            exit 1
            ;;
    esac
}

install_coredns() {
    if command -v coredns >/dev/null 2>&1; then
        log_info "CoreDNS 已存在: $(command -v coredns)"
        coredns -version || true
        return
    fi

    log_step "下载并安装 CoreDNS ${COREDNS_VERSION}..."
    local tmpdir archive url
    tmpdir=$(mktemp -d)
    archive="${tmpdir}/coredns.tgz"
    url="https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}/coredns_${COREDNS_VERSION}_linux_${COREDNS_ARCH}.tgz"

    curl -fL --connect-timeout 15 --retry 3 -o "${archive}" "${url}"
    tar -xzf "${archive}" -C "${tmpdir}"
    install -m 0755 "${tmpdir}/coredns" "${COREDNS_BIN}"
    rm -rf "${tmpdir}"
    "${COREDNS_BIN}" -version || true
}

write_coredns_config() {
    log_step "生成 DNS 配置..."
    mkdir -p "${APP_DIR}"

    if [ -f "${APP_DIR}/Corefile" ]; then
        cp "${APP_DIR}/Corefile" "${APP_DIR}/Corefile.bak.$(date +%F_%H%M%S)"
    fi

    : > "${APP_DIR}/hosts"
    for record in "${LOCAL_RECORDS[@]}"; do
        local domain ip
        domain=$(echo "${record}" | awk '{print $1}')
        ip=$(echo "${record}" | awk '{print $2}')
        if [ -n "${domain}" ] && [ -n "${ip}" ]; then
            echo "${ip} ${domain}" >> "${APP_DIR}/hosts"
            log_info "本地解析: ${domain} -> ${ip}"
        fi
    done

    cat > "${APP_DIR}/Corefile" <<EOF
.:${DNS_PORT} {
    bind ${LISTEN_ADDR}
    errors
    log
    health :8080
    ready :8181

    hosts ${APP_DIR}/hosts {
        fallthrough
    }

    cache 300
    forward . ${UPSTREAM_DNS} {
        policy sequential
        health_check 5s
    }
    reload
}
EOF
}

write_systemd_service() {
    log_step "生成 systemd 服务..."
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=CoreDNS DNS Server
Documentation=https://coredns.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${COREDNS_BIN} -conf ${APP_DIR}/Corefile
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
}

open_firewall() {
    log_step "尝试放行 DNS 端口 ${DNS_PORT}..."
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${DNS_PORT}"/udp || true
        ufw allow "${DNS_PORT}"/tcp || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${DNS_PORT}"/udp 2>/dev/null || true
        firewall-cmd --permanent --add-port="${DNS_PORT}"/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
}

get_server_ip() {
    local ip
    ip=$(curl -fsS --connect-timeout 3 https://api.ipify.org 2>/dev/null || true)
    if [ -z "${ip}" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1 || true)
    fi
    if [ -z "${ip}" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    echo "${ip:-127.0.0.1}"
}

verify() {
    log_step "检查服务状态..."
    sleep 2
    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_error "CoreDNS 启动失败，请执行: journalctl -u ${SERVICE_NAME} -e"
        exit 1
    fi

    local server_ip endpoint
    server_ip=$(get_server_ip)
    endpoint="${server_ip}:${DNS_PORT}"

    if command -v dig >/dev/null 2>&1; then
        dig @"${server_ip}" +short +time=3 example.com >/dev/null 2>&1 && log_info "DNS 解析测试通过" || log_warn "DNS 解析测试未通过，请检查安全组/防火墙"
    fi

    echo ""
    log_info "=================================================="
    log_info "  DNS 解析服务器部署完成"
    log_info "=================================================="
    log_info "  DNS 地址: ${endpoint}"
    log_info "  其他服务器 nameserver: ${server_ip}"
    log_info "  上游 DNS: ${UPSTREAM_DNS}"
    log_info "  配置文件: ${APP_DIR}/Corefile"
    log_info "=================================================="
    echo ""
    echo "其他服务器配置示例:"
    echo "  echo 'nameserver ${server_ip}' | sudo tee /etc/resolv.conf"
    echo ""
    echo "${endpoint}"
}

main() {
    echo ""
    log_info "##################################################"
    log_info "#  DNS 解析服务器一键安装脚本"
    log_info "##################################################"
    echo ""

    require_root
    detect_os
    detect_arch
    install_dependencies
    install_coredns
    write_coredns_config
    write_systemd_service
    open_firewall
    verify
}

main "$@"
