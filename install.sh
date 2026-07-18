#!/usr/bin/env bash
# ============================================================
# 一键部署 DNS 解析服务器 (CoreDNS + nftables)
#
# 让其他服务器把本机当作 DNS 解析服务器使用：
# 它们只需把 nameserver 指向本机 IP 即可（在客户端 /etc/resolv.conf 或
# 用配套的 client-setup.sh 一键配置）。
#
# 两种模式:
#   MODE=simple (默认) —— 仅 DNS 模式【推荐，最常用】
#       CoreDNS 解析/缓存 + nftables 访问控制(ACL)。其他服务器把
#       nameserver 指向本机即可解析。默认只放行内网网段，公网客户端
#       请用 ALLOW_IPS 把它们的 IP 加进白名单。
#   MODE=gateway —— 强制劫持模式【进阶，需要改客户端网关】
#       在 simple 基础上再用 nftables 劫持所有经过本机的 53 流量 + NAT。
#       其他服务器把默认网关指向本机后，即使写死 8.8.8.8 也会被劫持到本机。
#
# 支持: Ubuntu / Debian / CentOS 8+ / Rocky / Alma / Fedora
#
# 用法:
#   sudo ./install.sh                                  # 默认 simple 模式
#   ALLOW_IPS="1.2.3.4 5.6.7.8" sudo -E ./install.sh   # 放行指定公网客户端
#   RESTRICT_DNS=false sudo -E ./install.sh            # 完全开放(慎用，见下方安全提示)
#   MODE=gateway sudo -E ./install.sh                  # 强制劫持模式
#   DNS_PORT=53 UPSTREAM_DNS="1.1.1.1 8.8.8.8" sudo -E ./install.sh
# ============================================================

set -euo pipefail

# ===================== 可配置项（均可用环境变量覆盖） =====================
# 部署模式: simple(仅DNS+ACL，默认) | gateway(强制劫持+NAT)
MODE="${MODE:-simple}"

SERVICE_NAME="coredns"
APP_DIR="/etc/coredns"
COREDNS_BIN="/usr/local/bin/coredns"
COREFILE="${APP_DIR}/Corefile"
HOSTS_FILE="${APP_DIR}/hosts"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INFO_FILE="${APP_DIR}/install-info.txt"

COREDNS_VERSION="${COREDNS_VERSION:-latest}"
DNS_PORT="${DNS_PORT:-53}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
UPSTREAM_DNS="${UPSTREAM_DNS:-223.5.5.5 223.6.6.6 119.29.29.29 8.8.8.8 1.1.1.1}"
CACHE_TTL="${CACHE_TTL:-300}"
MIRROR_PREFIX="${MIRROR_PREFIX:-}"
NFT_TABLE="${NFT_TABLE:-dns_force}"

# gateway 模式相关
ENABLE_NAT="${ENABLE_NAT:-true}"        # 是否启用 NAT 网关（让本机充当其他服务器的出口）
WAN_IFACE="${WAN_IFACE:-}"              # 外网网卡（留空自动检测）

# simple 模式相关
# 允许查询本 DNS 的源网段（写入 nftables ACL），默认放行常见内网段
ALLOW_NETS="${ALLOW_NETS:-192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 127.0.0.0/8}"
# 额外放行的具体客户端 IP（公网服务器写这里，空格分隔，可带 /32 或纯 IP）
ALLOW_IPS="${ALLOW_IPS:-}"
RESTRICT_DNS="${RESTRICT_DNS:-true}"    # true=仅允许 ALLOW_NETS/ALLOW_IPS 查询；false=对所有来源开放

# 本地域名记录，格式: "域名 IP"
LOCAL_RECORDS=(
    # "git.local 192.168.1.10"
    # "nas.local 192.168.1.20"
)

# ===================== 日志（全部输出到 stderr，避免污染 $(...)） =====================
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
log_info(){ echo -e "${G}[INFO]${N} $*" >&2; }
log_warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
log_error(){ echo -e "${R}[ERROR]${N} $*" >&2; }
log_step(){ echo -e "${C}[STEP]${N} $*" >&2; }
log_ok(){ echo -e "${G}[ OK ]${N} $*" >&2; }
die(){ log_error "$*"; exit 1; }

require_root(){ [[ ${EUID} -eq 0 ]] || die "请使用 root 或 sudo 运行"; }

validate_mode(){
    case "${MODE}" in
        gateway|simple) ;;
        *) die "MODE 只能是 gateway 或 simple，当前: ${MODE}" ;;
    esac
    log_info "部署模式: ${MODE}"
}

detect_os(){
    [[ -f /etc/os-release ]] || die "无法识别操作系统"
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID}"
    log_info "系统: ${PRETTY_NAME:-$ID}"
}

detect_arch(){
    case "$(uname -m)" in
        x86_64|amd64) COREDNS_ARCH=amd64 ;;
        aarch64|arm64) COREDNS_ARCH=arm64 ;;
        armv7l|armv6l) COREDNS_ARCH=arm ;;
        *) die "暂不支持 CPU 架构: $(uname -m)" ;;
    esac
    log_info "架构: $(uname -m) -> ${COREDNS_ARCH}"
}

detect_wan_iface(){
    [[ "${MODE}" == "gateway" ]] || return 0
    if [[ -z "${WAN_IFACE}" ]]; then
        WAN_IFACE=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
    fi
    if [[ -z "${WAN_IFACE}" ]]; then
        log_warn "未检测到默认外网网卡，NAT 功能可能不完整"
    else
        log_info "外网网卡: ${WAN_IFACE}"
    fi
}

install_dependencies(){
    log_step "安装依赖..."
    case "${OS_ID}" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y -qq
            apt-get install -y -qq curl tar ca-certificates nftables iproute2 dnsutils >/dev/null
            ;;
        centos|rocky|almalinux|rhel|fedora|amzn)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y -q curl tar ca-certificates nftables iproute bind-utils >/dev/null
            else
                yum install -y -q curl tar ca-certificates nftables iproute bind-utils >/dev/null
            fi
            ;;
        *) die "不支持的系统: ${OS_ID}" ;;
    esac
    command -v curl >/dev/null || die "缺少 curl"
    command -v ip >/dev/null || die "缺少 iproute2"
    log_ok "依赖就绪"
}

# ---------- 释放 53 端口（关闭 systemd-resolved stub、停占用进程） ----------
disable_resolved_stub(){
    systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
    if ss -lntup 2>/dev/null | grep -qE ':53\b.*systemd-resolve'; then
        log_step "关闭 systemd-resolved Stub 监听 (释放 53)..."
        mkdir -p /etc/systemd/resolved.conf.d
        printf '%s\n' '[Resolve]' 'DNSStubListener=no' > /etc/systemd/resolved.conf.d/disable-stub.conf
        systemctl restart systemd-resolved 2>/dev/null || true
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
        log_ok "已禁用 DNSStubListener"
    fi
}

free_dns_port(){
    local port="${DNS_PORT}"
    [[ "${port}" == "53" ]] && disable_resolved_stub

    command -v ss >/dev/null 2>&1 || { log_warn "未找到 ss，跳过端口释放检测"; return 0; }

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        log_info "端口 ${port} 已由 coredns 使用，稍后重启服务接管"
        return 0
    fi

    local pids pid comm unit
    pids=$(ss -lntup 2>/dev/null \
        | awk -v p=":${port}" '$0 ~ p {print}' \
        | grep -oE 'pid=[0-9]+' | sed 's/pid=//' | sort -u)
    [[ -z "${pids}" ]] && { log_ok "端口 ${port} 空闲"; return 0; }

    for pid in ${pids}; do
        [[ -z "${pid}" ]] && continue
        comm=$(ps -o comm= -p "${pid}" 2>/dev/null | tr -d ' ')
        [[ "${comm}" == "coredns" ]] && continue
        unit=$(ps -o unit= -p "${pid}" 2>/dev/null | tr -d ' ' || true)
        log_warn "端口 ${port} 被占用: pid=${pid} comm=${comm}${unit:+ unit=${unit}}"
        if [[ -n "${unit}" && "${unit}" != "-" && "${unit}" != "init.scope" && ! "${unit}" =~ \.scope$ ]]; then
            systemctl stop "${unit}" 2>/dev/null || true
            systemctl disable "${unit}" 2>/dev/null || true
        fi
        case "${comm}" in
            systemd-resolve|systemd-resolved) disable_resolved_stub ;;
            named|bind|bind9|dnsmasq|unbound)
                systemctl stop "${comm}" 2>/dev/null || true
                systemctl disable "${comm}" 2>/dev/null || true
                ;;
        esac
        if kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
            sleep 1
            kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null || true
        fi
    done

    sleep 1
    if ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$"; then
        if ss -lntup 2>/dev/null | grep -E "[:.]${port}(\s|$)" | grep -q coredns; then
            log_info "端口 ${port} 现由 coredns 持有"
            return 0
        fi
        die "仍未能释放端口 ${port}，请手动检查: ss -lntup | grep :${port}"
    fi
    log_ok "端口 ${port} 已释放"
}

# ---------- 安装 CoreDNS（支持 latest 解析 + SHA256 校验 + 镜像回退） ----------
resolve_coredns_version(){
    if [[ "${COREDNS_VERSION}" != "latest" ]]; then
        echo "${COREDNS_VERSION}"
        return
    fi
    log_info "获取 CoreDNS 最新版本..."
    local ver=""
    ver=$(curl -fsSL --connect-timeout 10 \
        https://api.github.com/repos/coredns/coredns/releases/latest 2>/dev/null \
        | grep -oE '"tag_name":[[:space:]]*"v[^"]+"' | head -1 \
        | sed -E 's/.*"v([0-9]+\.[0-9]+\.[0-9]+).*/\1/') || true
    ver=$(printf '%s' "${ver}" | tr -d '[:space:]' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -z "${ver}" ]]; then
        log_warn "无法获取最新版，回退 1.11.3"
        ver="1.11.3"
    fi
    echo "${ver}"
}

verify_checksum(){
    local file="$1" sidecar_url="$2" asset_name="$3"
    local expected actual sidecar
    sidecar=$(curl -fsSL --connect-timeout 10 "${sidecar_url}" 2>/dev/null) || true
    expected=$(printf '%s' "${sidecar}" | grep -oE '[0-9a-fA-F]{64}' | head -1 || true)
    if [[ -z "${expected}" ]]; then
        log_warn "未能获取 ${asset_name} 官方 SHA256，跳过校验（建议手动核对）"
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "${file}" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "${file}" | awk '{print $1}')
    else
        log_warn "系统无 sha256sum/shasum，跳过校验"
        return 0
    fi
    expected="${expected,,}"; actual="${actual,,}"
    [[ "${expected}" == "${actual}" ]] || die "SHA256 校验失败: ${asset_name}（文件可能被篡改或下载不完整）"
    log_ok "SHA256 校验通过: ${asset_name}"
}

install_coredns(){
    local version url tmpdir archive asset cur
    version=$(resolve_coredns_version)
    COREDNS_VERSION="${version}"
    log_step "安装 CoreDNS v${version}..."

    if [[ -x "${COREDNS_BIN}" ]]; then
        cur=$("${COREDNS_BIN}" -version 2>/dev/null | head -1 || true)
        if echo "${cur}" | grep -qE "v?${version}"; then
            log_ok "已是 v${version}，跳过下载"
            return
        fi
        log_info "将升级到 v${version}（当前: ${cur:-未知}）"
    fi

    asset="coredns_${version}_linux_${COREDNS_ARCH}.tgz"
    url="${MIRROR_PREFIX}https://github.com/coredns/coredns/releases/download/v${version}/${asset}"
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" RETURN
    archive="${tmpdir}/coredns.tgz"

    if ! curl -fL --connect-timeout 15 --retry 3 -o "${archive}" "${url}"; then
        log_warn "主链接失败，尝试镜像加速..."
        curl -fL --connect-timeout 15 --retry 3 -o "${archive}" \
            "https://ghfast.top/https://github.com/coredns/coredns/releases/download/v${version}/${asset}" \
            || die "下载 CoreDNS 失败"
    fi

    verify_checksum "${archive}" \
        "https://github.com/coredns/coredns/releases/download/v${version}/${asset}.sha256" \
        "${asset}"

    tar -xzf "${archive}" -C "${tmpdir}"
    install -m 0755 "${tmpdir}/coredns" "${COREDNS_BIN}"
    log_ok "CoreDNS: $("${COREDNS_BIN}" -version | head -1)"
}

write_coredns_config(){
    log_step "生成 CoreDNS 配置..."
    mkdir -p "${APP_DIR}"
    [[ -f "${COREFILE}" ]] && cp -a "${COREFILE}" "${COREFILE}.bak.$(date +%F_%H%M%S)" || true

    : > "${HOSTS_FILE}"
    local record domain ip
    for record in "${LOCAL_RECORDS[@]+"${LOCAL_RECORDS[@]}"}"; do
        [[ -z "${record// }" ]] && continue
        domain=$(echo "${record}" | awk '{print $1}')
        ip=$(echo "${record}" | awk '{print $2}')
        if [[ -n "${domain}" && -n "${ip}" ]]; then
            echo "${ip} ${domain}" >> "${HOSTS_FILE}"
            log_info "本地域名: ${domain} -> ${ip}"
        fi
    done

    cat > "${COREFILE}" <<EOF
.:${DNS_PORT} {
    bind ${LISTEN_ADDR}
    errors
    log
    health :8080
    ready :8181
    prometheus :9153

    hosts ${HOSTS_FILE} {
        fallthrough
    }

    cache ${CACHE_TTL} {
        prefetch 10 1m 20%
    }

    forward . ${UPSTREAM_DNS} {
        policy sequential
        health_check 5s
    }
    reload
}
EOF
    chmod 644 "${COREFILE}" "${HOSTS_FILE}"
    log_ok "配置: ${COREFILE}"
}

write_systemd_service(){
    log_step "配置 systemd 服务..."
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=CoreDNS DNS Server
Documentation=https://coredns.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${COREDNS_BIN} -conf ${COREFILE}
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
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    log_ok "systemd 服务已配置"
}

get_server_ip(){
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [[ -n "${ip}" ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "${ip}" ]] || ip=$(curl -fsS --connect-timeout 3 https://api.ipify.org 2>/dev/null || true)
    echo "${ip:-127.0.0.1}"
}

enable_ip_forward(){
    log_step "启用 IPv4 转发..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    mkdir -p /etc/sysctl.d
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-dns-gateway.conf
    log_ok "IPv4 转发已启用"
}

# ---------- gateway 模式: 劫持所有 53 流量 + NAT ----------
setup_gateway_nft(){
    log_step "配置 nftables (DNS 劫持 + NAT)..."
    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl start nftables >/dev/null 2>&1 || true
    nft delete table inet "${NFT_TABLE}" 2>/dev/null || true

    local server_ip
    server_ip=$(get_server_ip)

    # 说明:
    #  - prerouting DNAT: 劫持"转发经过本机"的其他服务器的 53 请求 -> 本机 CoreDNS
    #  - output   DNAT: 劫持"本机自身"发往外部 DNS 的 53 请求 -> 本机 CoreDNS
    #                   （排除发往本机自身的，避免回环）
    #  - forward       : 放行已建立连接 + 内网发起的连接
    #  - postrouting   : masquerade 做 NAT 出口
    local rules="add table inet ${NFT_TABLE}\n"
    rules+="add chain inet ${NFT_TABLE} prerouting { type nat hook prerouting priority -100; policy accept; }\n"
    rules+="add chain inet ${NFT_TABLE} output { type nat hook output priority -100; policy accept; }\n"

    # DNS 劫持（prerouting，针对转发流量）
    rules+="add rule inet ${NFT_TABLE} prerouting ip daddr ${server_ip} udp dport ${DNS_PORT} accept\n"
    rules+="add rule inet ${NFT_TABLE} prerouting ip daddr ${server_ip} tcp dport ${DNS_PORT} accept\n"
    rules+="add rule inet ${NFT_TABLE} prerouting udp dport 53 dnat ip to ${server_ip}:${DNS_PORT}\n"
    rules+="add rule inet ${NFT_TABLE} prerouting tcp dport 53 dnat ip to ${server_ip}:${DNS_PORT}\n"

    # DNS 劫持（output，针对本机自身；排除本机->本机避免回环）
    rules+="add rule inet ${NFT_TABLE} output ip daddr ${server_ip} accept\n"
    rules+="add rule inet ${NFT_TABLE} output ip daddr 127.0.0.0/8 accept\n"
    rules+="add rule inet ${NFT_TABLE} output udp dport 53 dnat ip to ${server_ip}:${DNS_PORT}\n"
    rules+="add rule inet ${NFT_TABLE} output tcp dport 53 dnat ip to ${server_ip}:${DNS_PORT}\n"

    if [[ "${ENABLE_NAT}" == "true" && -n "${WAN_IFACE}" ]]; then
        rules+="add chain inet ${NFT_TABLE} forward { type filter hook forward priority 0; policy accept; }\n"
        rules+="add chain inet ${NFT_TABLE} postrouting { type nat hook postrouting priority 100; policy accept; }\n"
        rules+="add rule inet ${NFT_TABLE} forward ct state established,related accept\n"
        rules+="add rule inet ${NFT_TABLE} forward iifname != \"${WAN_IFACE}\" accept\n"
        rules+="add rule inet ${NFT_TABLE} postrouting oifname \"${WAN_IFACE}\" masquerade\n"
    fi

    # shellcheck disable=SC2059
    printf "%b" "${rules}" | nft -f - || die "nftables 规则应用失败"

    persist_nft
    log_ok "DNS 劫持已配置：所有 53 请求 -> ${server_ip}:${DNS_PORT}"
    [[ "${ENABLE_NAT}" == "true" && -n "${WAN_IFACE}" ]] && log_ok "NAT 网关已启用 (${WAN_IFACE})"
}

# ---------- simple 模式: 仅 DNS 访问控制 ----------
setup_simple_acl(){
    if [[ "${RESTRICT_DNS}" != "true" ]]; then
        log_info "RESTRICT_DNS=false，跳过 nftables ACL"
        return
    fi
    command -v nft >/dev/null 2>&1 || { log_warn "未安装 nftables，跳过 DNS ACL"; return; }

    log_step "配置 DNS 访问控制 (nftables ACL)..."
    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl start nftables >/dev/null 2>&1 || true
    nft delete table inet "${NFT_TABLE}" 2>/dev/null || true

    local rules net cip
    rules="add table inet ${NFT_TABLE}\n"
    rules+="add chain inet ${NFT_TABLE} input { type filter hook input priority -10; policy accept; }\n"
    rules+="add rule inet ${NFT_TABLE} input iifname \"lo\" accept\n"
    for net in ${ALLOW_NETS}; do
        [[ -z "${net// }" ]] && continue
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${net} udp dport ${DNS_PORT} accept\n"
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${net} tcp dport ${DNS_PORT} accept\n"
    done
    for cip in ${ALLOW_IPS}; do
        [[ -z "${cip// }" ]] && continue
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${cip} udp dport ${DNS_PORT} accept\n"
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${cip} tcp dport ${DNS_PORT} accept\n"
        log_info "放行客户端 IP: ${cip}"
    done
    rules+="add rule inet ${NFT_TABLE} input udp dport ${DNS_PORT} drop\n"
    rules+="add rule inet ${NFT_TABLE} input tcp dport ${DNS_PORT} drop\n"

    # shellcheck disable=SC2059
    printf "%b" "${rules}" | nft -f - || die "nftables 规则应用失败"

    persist_nft
    log_ok "DNS 仅允许来自网段: ${ALLOW_NETS}${ALLOW_IPS:+ ；IP: ${ALLOW_IPS}}"
}

# ---------- 持久化 nftables 规则 ----------
persist_nft(){
    local persist="/etc/nftables.d/${NFT_TABLE}.nft"
    mkdir -p /etc/nftables.d 2>/dev/null || true
    nft list table inet "${NFT_TABLE}" > "${persist}" 2>/dev/null || true
    if [[ -f /etc/nftables.conf ]]; then
        if ! grep -qF "nftables.d/${NFT_TABLE}.nft" /etc/nftables.conf 2>/dev/null; then
            echo "include \"${persist}\"" >> /etc/nftables.conf
        fi
    else
        cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset
include "${persist}"
EOF
    fi
    systemctl enable nftables >/dev/null 2>&1 || true
}

configure_firewall(){
    log_step "配置系统防火墙放行 DNS ${DNS_PORT}..."
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${DNS_PORT}"/udp comment 'CoreDNS' >/dev/null 2>&1 || true
        ufw allow "${DNS_PORT}"/tcp comment 'CoreDNS' >/dev/null 2>&1 || true
        if [[ "${MODE}" == "gateway" ]]; then
            sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${DNS_PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${DNS_PORT}/tcp" >/dev/null 2>&1 || true
        [[ "${MODE}" == "gateway" ]] && firewall-cmd --permanent --add-masquerade >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    log_ok "防火墙已放行 ${DNS_PORT}"
}

start_coredns(){
    log_step "启动 CoreDNS..."
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_ok "CoreDNS 已启动"
    else
        journalctl -u "${SERVICE_NAME}" -n 40 --no-pager || true
        die "CoreDNS 启动失败，请查看: journalctl -u ${SERVICE_NAME} -e"
    fi
}

verify(){
    local server_ip endpoint
    server_ip=$(get_server_ip)
    endpoint="${server_ip}:${DNS_PORT}"

    cat > "${INFO_FILE}" <<EOF
======== DNS 服务器安装信息 ========
时间: $(date '+%Y-%m-%d %H:%M:%S')
模式: ${MODE}
服务器 IP: ${server_ip}
CoreDNS: ${COREDNS_VERSION}
DNS 端口: ${DNS_PORT}
监听: ${LISTEN_ADDR}
上游 DNS: ${UPSTREAM_DNS}
缓存 TTL: ${CACHE_TTL}s
NFT_TABLE: ${NFT_TABLE}
EOF
    if [[ "${MODE}" == "gateway" ]]; then
        echo "NAT 网关: ${ENABLE_NAT} (${WAN_IFACE:-未检测})" >> "${INFO_FILE}"
    else
        echo "访问控制: RESTRICT_DNS=${RESTRICT_DNS} (${ALLOW_NETS})" >> "${INFO_FILE}"
    fi
    echo "===================================" >> "${INFO_FILE}"

    if command -v dig >/dev/null 2>&1; then
        if dig @"${server_ip}" -p "${DNS_PORT}" +short +time=3 +tries=1 example.com A >/dev/null 2>&1 \
            || dig @127.0.0.1 -p "${DNS_PORT}" +short +time=3 +tries=1 example.com A >/dev/null 2>&1; then
            log_ok "DNS 解析测试通过"
        else
            log_warn "DNS 解析测试未通过，请检查上游网络与安全组/防火墙"
        fi
    fi
    if command -v nft >/dev/null 2>&1; then
        nft list table inet "${NFT_TABLE}" >/dev/null 2>&1 \
            && log_ok "nftables 规则已生效" || log_warn "nftables 规则未检测到"
    fi

    echo "" >&2
    echo -e "${C}${B}==================================================${N}" >&2
    if [[ "${MODE}" == "gateway" ]]; then
        echo -e "${C}${B}  DNS 服务器部署完成（强制劫持 + NAT 网关）${N}" >&2
    else
        echo -e "${C}${B}  DNS 服务器部署完成（仅 DNS 解析/缓存）${N}" >&2
    fi
    echo -e "${C}${B}==================================================${N}" >&2
    log_info "DNS 地址:  ${endpoint}"
    log_info "上游 DNS:  ${UPSTREAM_DNS}"
    log_info "配置文件:  ${COREFILE}"
    log_info "信息文件:  ${INFO_FILE}"
    echo -e "${C}${B}==================================================${N}" >&2
    echo "" >&2

    if [[ "${MODE}" == "gateway" ]]; then
        log_info "其他服务器强制走本机 DNS（推荐用配套 client-setup.sh）:"
        echo -e "  ${B}sudo ./client-setup.sh ${server_ip} --gateway${N}" >&2
        echo "" >&2
        log_info "或手动设置网关 + DNS（硬强制）:"
        echo "  sudo ip route replace default via ${server_ip}" >&2
        echo "  echo 'nameserver ${server_ip}' | sudo tee /etc/resolv.conf" >&2
        echo "  # 即使客户端写死 8.8.8.8，53 请求也会被本机劫持" >&2
    else
        log_info "其他服务器把本机当 DNS 用（在客户端执行）:"
        echo -e "  ${B}sudo ./client-setup.sh ${server_ip}${N}" >&2
        echo "  或手动: echo 'nameserver ${server_ip}' | sudo tee /etc/resolv.conf" >&2
        echo "" >&2
        if [[ "${RESTRICT_DNS}" == "true" ]]; then
            log_warn "当前仅放行内网段与 ALLOW_IPS。若客户端是公网服务器，需先放行其公网 IP："
            echo "  ALLOW_IPS=\"客户端公网IP\" sudo -E ./install.sh   # 可空格分隔多个" >&2
            echo "  已放行网段: ${ALLOW_NETS}" >&2
            [[ -n "${ALLOW_IPS}" ]] && echo "  已放行IP:   ${ALLOW_IPS}" >&2
        else
            log_warn "RESTRICT_DNS=false：当前对所有来源开放，属于开放解析器，务必用安全组收紧来源！"
        fi
    fi
    echo "" >&2
    log_warn "云服务器安全组请放行 UDP/TCP ${DNS_PORT}"

    # 唯一写到 stdout 的内容：便于脚本捕获
    echo "${endpoint}"
}

main(){
    echo "" >&2
    log_info "##################################################"
    log_info "#  DNS 解析服务器一键安装 (CoreDNS + nftables)"
    log_info "##################################################"
    echo "" >&2

    require_root
    validate_mode
    detect_os
    detect_arch
    detect_wan_iface
    install_dependencies
    check_port_hint
    install_coredns
    write_coredns_config
    write_systemd_service

    if [[ "${MODE}" == "gateway" ]]; then
        enable_ip_forward
        setup_gateway_nft
    else
        setup_simple_acl
    fi

    configure_firewall
    free_dns_port
    start_coredns
    verify
}

check_port_hint(){
    command -v ss >/dev/null 2>&1 || return 0
    if ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${DNS_PORT}$"; then
        if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            log_warn "端口 ${DNS_PORT} 当前被占用，稍后将尝试释放"
        fi
    fi
}

main "$@"
