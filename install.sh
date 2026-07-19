#!/usr/bin/env bash
# CoreDNS DNS 解析服务器安全安装脚本
# 默认 simple 模式；gateway 模式必须显式 ENABLE_GATEWAY=true。
set -Eeuo pipefail

MODE="${MODE:-simple}"
SERVICE_NAME="coredns"
APP_DIR="/etc/coredns"
COREDNS_BIN="/usr/local/bin/coredns"
COREFILE="${APP_DIR}/Corefile"
HOSTS_FILE="${APP_DIR}/hosts"
NFT_RULES_FILE="${APP_DIR}/nftables.nft"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NFT_SERVICE_NAME="coredns-nftables"
NFT_SERVICE_FILE="/etc/systemd/system/${NFT_SERVICE_NAME}.service"
INFO_FILE="${APP_DIR}/install-info.txt"
STATE_DIR="/var/lib/coredns-installer"
STATE_FILE="${STATE_DIR}/state.env"
BACKUP_DIR="${STATE_DIR}/original"
TX_DIR="${STATE_DIR}/transaction"
INSTALL_COMMITTED=0
TX_STOPPED_UNITS=""

COREDNS_VERSION="${COREDNS_VERSION:-1.14.6}"
DNS_PORT="${DNS_PORT:-53}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
UPSTREAM_DNS="${UPSTREAM_DNS:-223.5.5.5 223.6.6.6 119.29.29.29 8.8.8.8 1.1.1.1}"
CACHE_TTL="${CACHE_TTL:-300}"
MIRROR_PREFIX="${MIRROR_PREFIX:-}"
NFT_TABLE="${NFT_TABLE:-dns_force}"
ALLOW_NETS="${ALLOW_NETS:-192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 127.0.0.0/8}"
ALLOW_IPS="${ALLOW_IPS:-}"
RESTRICT_DNS="${RESTRICT_DNS:-true}"
AUTO_ALLOW="${AUTO_ALLOW:-false}"
RATE_LIMIT="${RATE_LIMIT:-30}"
FORCE_STOP_CONFLICT="${FORCE_STOP_CONFLICT:-false}"
ENABLE_GATEWAY="${ENABLE_GATEWAY:-false}"
ENABLE_NAT="${ENABLE_NAT:-true}"
WAN_IFACE="${WAN_IFACE:-}"
GATEWAY_NETS="${GATEWAY_NETS:-${ALLOW_NETS}}"

LOCAL_RECORDS=(
    # "git.local 192.168.1.10"
)

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
log_info(){ echo -e "${G}[INFO]${N} $*" >&2; }
log_warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
log_error(){ echo -e "${R}[ERROR]${N} $*" >&2; }
log_step(){ echo -e "${C}[STEP]${N} $*" >&2; }
log_ok(){ echo -e "${G}[ OK ]${N} $*" >&2; }
die(){ log_error "$*"; exit 1; }

require_root(){ [[ ${EUID} -eq 0 ]] || die "请使用 root 或 sudo 运行"; }

is_ipv4(){
    local ip="$1" a b c d
    IFS=. read -r a b c d <<< "${ip}"
    [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    [[ ${#a} -le 3 && ${#b} -le 3 && ${#c} -le 3 && ${#d} -le 3 ]] || return 1
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}

validate_cidr(){
    local value="$1" ip prefix
    ip="${value%/*}"
    prefix="${value#*/}"
    [[ "${value}" == */* ]] || prefix=32
    is_ipv4 "${ip}" || return 1
    [[ "${prefix}" =~ ^[0-9]+$ ]] && (( prefix >= 0 && prefix <= 32 ))
}

validate_bool(){
    [[ "$2" == "true" || "$2" == "false" ]] || die "$1 只能是 true 或 false"
}

validate_config(){
    case "${MODE}" in simple|gateway) ;; *) die "MODE 只能是 simple 或 gateway" ;; esac
    [[ "${DNS_PORT}" =~ ^[0-9]+$ ]] && (( DNS_PORT >= 1 && DNS_PORT <= 65535 )) || die "DNS_PORT 无效: ${DNS_PORT}"
    [[ "${CACHE_TTL}" =~ ^[0-9]+$ ]] || die "CACHE_TTL 必须是非负整数"
    [[ "${RATE_LIMIT}" =~ ^[0-9]+$ ]] || die "RATE_LIMIT 必须是非负整数"
    [[ "${NFT_TABLE}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "NFT_TABLE 名称无效"
    validate_bool RESTRICT_DNS "${RESTRICT_DNS}"
    validate_bool AUTO_ALLOW "${AUTO_ALLOW}"
    validate_bool FORCE_STOP_CONFLICT "${FORCE_STOP_CONFLICT}"
    validate_bool ENABLE_GATEWAY "${ENABLE_GATEWAY}"
    validate_bool ENABLE_NAT "${ENABLE_NAT}"
    local item
    for item in ${ALLOW_NETS} ${ALLOW_IPS}; do validate_cidr "${item}" || die "无效 IPv4/CIDR: ${item}"; done
    if [[ "${MODE}" == "gateway" ]]; then
        [[ "${ENABLE_GATEWAY}" == "true" ]] || die "gateway 会修改转发/NAT；确认后使用 MODE=gateway ENABLE_GATEWAY=true"
        [[ -n "${GATEWAY_NETS// }" ]] || die "gateway 必须设置 GATEWAY_NETS"
        for item in ${GATEWAY_NETS}; do validate_cidr "${item}" || die "无效 GATEWAY_NETS: ${item}"; done
    fi
    log_info "部署模式: ${MODE}"
}

state_set(){
    local key="$1" value="$2" tmp
    mkdir -p "${STATE_DIR}"; chmod 700 "${STATE_DIR}"
    tmp=$(mktemp "${STATE_DIR}/state.XXXXXX")
    if [[ -f "${STATE_FILE}" ]]; then grep -vE "^${key}=" "${STATE_FILE}" > "${tmp}" || true; fi
    printf '%s=%q\n' "${key}" "${value}" >> "${tmp}"
    chmod 600 "${tmp}"; mv "${tmp}" "${STATE_FILE}"
    printf -v "${key}" '%s' "${value}"
}

state_set_if_unset(){
    local key="$1" value="$2"
    [[ -v "${key}" ]] || state_set "${key}" "${value}"
}

backup_once(){
    local source="$1" name="$2"
    [[ -e "${source}" || -L "${source}" ]] || return 1
    mkdir -p "${BACKUP_DIR}"
    [[ -e "${BACKUP_DIR}/${name}" || -L "${BACKUP_DIR}/${name}" ]] || cp -a "${source}" "${BACKUP_DIR}/${name}"
}

tx_set(){
    local key="$1" value="$2"
    printf '%s=%q\n' "${key}" "${value}" >> "${TX_DIR}/state.env"
}

tx_backup(){
    local source="$1" name="$2"
    if [[ -e "${source}" || -L "${source}" ]]; then
        cp -a "${source}" "${TX_DIR}/${name}"
        tx_set "${name^^}_EXISTED" "1"
    else
        tx_set "${name^^}_EXISTED" "0"
    fi
}

begin_transaction(){
    local state_dir_existed=0 state_file_existed=0
    if [[ -e "${TX_DIR}" ]]; then
        die "检测到未完成事务 ${TX_DIR}；请先检查并恢复，拒绝覆盖快照"
    fi
    if [[ -d "${STATE_DIR}" && ! -f "${STATE_FILE}" ]]; then
        die "检测到缺少 state.env 的残留状态目录 ${STATE_DIR}；请人工核对后处理，拒绝覆盖"
    fi
    [[ -d "${STATE_DIR}" ]] && state_dir_existed=1
    [[ -f "${STATE_FILE}" ]] && state_file_existed=1
    mkdir -p "${STATE_DIR}"
    chmod 700 "${STATE_DIR}"
    mkdir -p "${TX_DIR}"
    chmod 700 "${TX_DIR}"
    : > "${TX_DIR}/state.env"
    chmod 600 "${TX_DIR}/state.env"

    tx_set TX_STATE_DIR_EXISTED "${state_dir_existed}"
    tx_set TX_STATE_FILE_EXISTED "${state_file_existed}"
    if [[ ${state_file_existed} -eq 1 ]]; then cp -a "${STATE_FILE}" "${TX_DIR}/installer_state"; fi
    tx_set TX_DNS_PORT "${DNS_PORT}"
    tx_set TX_NFT_TABLE "${NFT_TABLE}"
    tx_set TX_IP_FORWARD "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    tx_set TX_SERVICE_ACTIVE "$(systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null && echo 1 || echo 0)"
    tx_set TX_SERVICE_ENABLED "$(systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null && echo 1 || echo 0)"
    tx_set TX_NFT_SERVICE_ACTIVE "$(systemctl is-active --quiet "${NFT_SERVICE_NAME}" 2>/dev/null && echo 1 || echo 0)"
    tx_set TX_NFT_SERVICE_ENABLED "$(systemctl is-enabled --quiet "${NFT_SERVICE_NAME}" 2>/dev/null && echo 1 || echo 0)"
    tx_set TX_RESOLVED_ACTIVE "$(systemctl is-active --quiet systemd-resolved 2>/dev/null && echo 1 || echo 0)"
    tx_set TX_USER_EXISTED "$(id coredns >/dev/null 2>&1 && echo 1 || echo 0)"
    tx_set TX_GROUP_EXISTED "$(getent group coredns >/dev/null 2>&1 && echo 1 || echo 0)"

    if [[ -d "${APP_DIR}" ]]; then
        tx_set TX_APP_DIR_EXISTED 1
        tx_set TX_APP_DIR_MODE "$(stat -c %a "${APP_DIR}")"
        tx_set TX_APP_DIR_UID "$(stat -c %u "${APP_DIR}")"
        tx_set TX_APP_DIR_GID "$(stat -c %g "${APP_DIR}")"
    else
        tx_set TX_APP_DIR_EXISTED 0
    fi

    tx_backup "${COREDNS_BIN}" coredns_bin
    tx_backup "${SERVICE_FILE}" coredns_service
    tx_backup "${NFT_SERVICE_FILE}" nft_service
    tx_backup "${COREFILE}" corefile
    tx_backup "${HOSTS_FILE}" hosts
    tx_backup "${NFT_RULES_FILE}" nft_rules
    tx_backup "${INFO_FILE}" info_file
    tx_backup /etc/systemd/resolved.conf.d/disable-stub.conf resolved_dropin
    tx_backup /etc/sysctl.d/99-dns-gateway.conf sysctl_dropin

    if [[ -L /etc/resolv.conf ]]; then
        tx_set TX_RESOLV_TYPE symlink
        tx_set TX_RESOLV_TARGET "$(readlink /etc/resolv.conf)"
    elif [[ -f /etc/resolv.conf ]]; then
        tx_set TX_RESOLV_TYPE file
        cp -a /etc/resolv.conf "${TX_DIR}/resolv_conf"
    else
        tx_set TX_RESOLV_TYPE missing
    fi

    if command -v nft >/dev/null 2>&1 && nft list table inet "${NFT_TABLE}" >/dev/null 2>&1; then
        nft list table inet "${NFT_TABLE}" > "${TX_DIR}/nft_table.nft"
        tx_set TX_NFT_TABLE_EXISTED 1
    else
        tx_set TX_NFT_TABLE_EXISTED 0
    fi

    if command -v ufw >/dev/null 2>&1 && ufw_is_active; then
        tx_set TX_UFW_UDP_EXISTED "$(firewall_has_ufw_rule udp && echo 1 || echo 0)"
        tx_set TX_UFW_TCP_EXISTED "$(firewall_has_ufw_rule tcp && echo 1 || echo 0)"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        tx_set TX_FIREWALLD_UDP_EXISTED "$(firewall-cmd --quiet --permanent --query-port="${DNS_PORT}/udp" && echo 1 || echo 0)"
        tx_set TX_FIREWALLD_TCP_EXISTED "$(firewall-cmd --quiet --permanent --query-port="${DNS_PORT}/tcp" && echo 1 || echo 0)"
    fi
}

restore_tx_file(){
    local target="$1" name="$2" existed_var="${2^^}_EXISTED"
    if [[ "${!existed_var:-0}" == "1" ]]; then
        mkdir -p "$(dirname "${target}")"
        rm -f "${target}"
        cp -a "${TX_DIR}/${name}" "${target}"
    else
        rm -f "${target}"
    fi
}

rollback_transaction(){
    local original_status="$1" rollback_failed=0 unit required
    [[ -f "${TX_DIR}/state.env" ]] || return "${original_status}"
    trap - EXIT ERR
    # shellcheck disable=SC1090
    source "${TX_DIR}/state.env"
    for required in TX_STATE_DIR_EXISTED TX_STATE_FILE_EXISTED TX_DNS_PORT TX_NFT_TABLE TX_IP_FORWARD \
        TX_SERVICE_ACTIVE TX_SERVICE_ENABLED TX_NFT_SERVICE_ACTIVE TX_NFT_SERVICE_ENABLED \
        TX_RESOLVED_ACTIVE TX_USER_EXISTED TX_GROUP_EXISTED TX_APP_DIR_EXISTED TX_RESOLV_TYPE \
        TX_NFT_TABLE_EXISTED COREDNS_BIN_EXISTED COREDNS_SERVICE_EXISTED NFT_SERVICE_EXISTED \
        COREFILE_EXISTED HOSTS_EXISTED NFT_RULES_EXISTED INFO_FILE_EXISTED \
        RESOLVED_DROPIN_EXISTED SYSCTL_DROPIN_EXISTED; do
        if [[ ! -v "${required}" ]]; then
            log_error "事务快照缺少字段 ${required}，拒绝按默认值修改宿主机；快照保留在 ${TX_DIR}"
            return "${original_status}"
        fi
    done
    if [[ "${TX_APP_DIR_EXISTED}" == "1" ]]; then
        for required in TX_APP_DIR_MODE TX_APP_DIR_UID TX_APP_DIR_GID; do
            if [[ ! -v "${required}" ]]; then
                log_error "事务快照缺少字段 ${required}；快照保留在 ${TX_DIR}"
                return "${original_status}"
            fi
        done
    fi
    if [[ "${TX_STATE_FILE_EXISTED}" == "1" && ! -e "${TX_DIR}/installer_state" ]]; then
        log_error "事务快照缺少安装状态文件；快照保留在 ${TX_DIR}"
        return "${original_status}"
    fi
    if [[ "${TX_RESOLV_TYPE}" == "symlink" && ! -v TX_RESOLV_TARGET ]]; then
        log_error "事务快照缺少 resolv.conf 链接目标；快照保留在 ${TX_DIR}"
        return "${original_status}"
    fi
    if [[ "${TX_RESOLV_TYPE}" == "file" && ! -e "${TX_DIR}/resolv_conf" ]]; then
        log_error "事务快照缺少 resolv.conf 文件；快照保留在 ${TX_DIR}"
        return "${original_status}"
    fi
    if [[ "${TX_NFT_TABLE_EXISTED}" == "1" && ! -s "${TX_DIR}/nft_table.nft" ]]; then
        log_error "事务快照缺少 nftables 表；快照保留在 ${TX_DIR}"
        return "${original_status}"
    fi
    local pair existed name
    for pair in \
        "${COREDNS_BIN_EXISTED}:coredns_bin" \
        "${COREDNS_SERVICE_EXISTED}:coredns_service" \
        "${NFT_SERVICE_EXISTED}:nft_service" \
        "${COREFILE_EXISTED}:corefile" \
        "${HOSTS_EXISTED}:hosts" \
        "${NFT_RULES_EXISTED}:nft_rules" \
        "${INFO_FILE_EXISTED}:info_file" \
        "${RESOLVED_DROPIN_EXISTED}:resolved_dropin" \
        "${SYSCTL_DROPIN_EXISTED}:sysctl_dropin"; do
        existed=${pair%%:*}
        name=${pair#*:}
        if [[ "${existed}" == "1" && ! -e "${TX_DIR}/${name}" && ! -L "${TX_DIR}/${name}" ]]; then
            log_error "事务快照缺少文件 ${name}；快照保留在 ${TX_DIR}"
            return "${original_status}"
        fi
    done
    log_error "安装未完成，正在恢复到本次运行前状态"

    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl stop "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || true
    nft delete table inet "${TX_NFT_TABLE}" 2>/dev/null || true
    if [[ "${TX_NFT_TABLE_EXISTED:-0}" == "1" ]]; then
        nft -c -f "${TX_DIR}/nft_table.nft" >/dev/null 2>&1 && nft -f "${TX_DIR}/nft_table.nft" >/dev/null 2>&1 || rollback_failed=1
    fi

    restore_tx_file "${COREDNS_BIN}" coredns_bin || rollback_failed=1
    restore_tx_file "${SERVICE_FILE}" coredns_service || rollback_failed=1
    restore_tx_file "${NFT_SERVICE_FILE}" nft_service || rollback_failed=1
    restore_tx_file "${COREFILE}" corefile || rollback_failed=1
    restore_tx_file "${HOSTS_FILE}" hosts || rollback_failed=1
    restore_tx_file "${NFT_RULES_FILE}" nft_rules || rollback_failed=1
    restore_tx_file "${INFO_FILE}" info_file || rollback_failed=1
    restore_tx_file /etc/systemd/resolved.conf.d/disable-stub.conf resolved_dropin || rollback_failed=1
    restore_tx_file /etc/sysctl.d/99-dns-gateway.conf sysctl_dropin || rollback_failed=1

    rm -f /etc/resolv.conf
    case "${TX_RESOLV_TYPE:-missing}" in
        symlink) ln -s "${TX_RESOLV_TARGET}" /etc/resolv.conf || rollback_failed=1 ;;
        file) cp -a "${TX_DIR}/resolv_conf" /etc/resolv.conf || rollback_failed=1 ;;
        missing) ;;
        *) rollback_failed=1 ;;
    esac
    if [[ "${TX_RESOLVED_ACTIVE:-0}" == "1" ]]; then
        systemctl restart systemd-resolved >/dev/null 2>&1 || rollback_failed=1
    else
        systemctl stop systemd-resolved >/dev/null 2>&1 || true
    fi
    sysctl -w "net.ipv4.ip_forward=${TX_IP_FORWARD:-0}" >/dev/null 2>&1 || rollback_failed=1

    if [[ "${TX_UFW_UDP_EXISTED:-1}" == "0" ]]; then
        if ! command -v ufw >/dev/null 2>&1; then
            rollback_failed=1
        elif firewall_has_ufw_rule udp && ! ufw --force delete allow "${TX_DNS_PORT}/udp" >/dev/null 2>&1; then
            rollback_failed=1
        fi
    fi
    if [[ "${TX_UFW_TCP_EXISTED:-1}" == "0" ]]; then
        if ! command -v ufw >/dev/null 2>&1; then
            rollback_failed=1
        elif firewall_has_ufw_rule tcp && ! ufw --force delete allow "${TX_DNS_PORT}/tcp" >/dev/null 2>&1; then
            rollback_failed=1
        fi
    fi
    local firewalld_changed=0
    if [[ "${TX_FIREWALLD_UDP_EXISTED:-1}" == "0" ]]; then
        if ! command -v firewall-cmd >/dev/null 2>&1; then
            rollback_failed=1
        elif firewall-cmd --quiet --permanent --query-port="${TX_DNS_PORT}/udp"; then
            firewall-cmd --permanent --remove-port="${TX_DNS_PORT}/udp" >/dev/null 2>&1 && firewalld_changed=1 || rollback_failed=1
        fi
    fi
    if [[ "${TX_FIREWALLD_TCP_EXISTED:-1}" == "0" ]]; then
        if ! command -v firewall-cmd >/dev/null 2>&1; then
            rollback_failed=1
        elif firewall-cmd --quiet --permanent --query-port="${TX_DNS_PORT}/tcp"; then
            firewall-cmd --permanent --remove-port="${TX_DNS_PORT}/tcp" >/dev/null 2>&1 && firewalld_changed=1 || rollback_failed=1
        fi
    fi
    if [[ ${firewalld_changed} -eq 1 ]]; then firewall-cmd --reload >/dev/null 2>&1 || rollback_failed=1; fi

    systemctl daemon-reload >/dev/null 2>&1 || rollback_failed=1
    if [[ "${COREDNS_SERVICE_EXISTED:-0}" == "1" ]]; then
        if [[ "${TX_SERVICE_ENABLED:-0}" == "1" ]]; then
            systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || rollback_failed=1
        else
            systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || rollback_failed=1
        fi
    else
        systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
    if [[ "${NFT_SERVICE_EXISTED:-0}" == "1" ]]; then
        if [[ "${TX_NFT_SERVICE_ENABLED:-0}" == "1" ]]; then
            systemctl enable "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || rollback_failed=1
        else
            systemctl disable "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || rollback_failed=1
        fi
    else
        systemctl disable "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
    if [[ "${NFT_SERVICE_EXISTED:-0}" == "1" && "${TX_NFT_SERVICE_ACTIVE:-0}" == "1" ]]; then
        systemctl restart "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || rollback_failed=1
    else
        systemctl stop "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
    if [[ "${COREDNS_SERVICE_EXISTED:-0}" == "1" && "${TX_SERVICE_ACTIVE:-0}" == "1" ]]; then
        systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || rollback_failed=1
    else
        systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
    for unit in ${TX_STOPPED_UNITS:-}; do systemctl start "${unit}" >/dev/null 2>&1 || rollback_failed=1; done

    if [[ "${TX_USER_EXISTED:-1}" == "0" ]] && id coredns >/dev/null 2>&1; then
        userdel coredns >/dev/null 2>&1 || rollback_failed=1
    fi
    if [[ "${TX_GROUP_EXISTED:-1}" == "0" ]] && getent group coredns >/dev/null 2>&1; then
        groupdel coredns >/dev/null 2>&1 || rollback_failed=1
    fi
    if [[ "${TX_APP_DIR_EXISTED:-0}" == "1" ]]; then
        chown "${TX_APP_DIR_UID}:${TX_APP_DIR_GID}" "${APP_DIR}" 2>/dev/null || rollback_failed=1
        chmod "${TX_APP_DIR_MODE}" "${APP_DIR}" 2>/dev/null || rollback_failed=1
    else
        rmdir "${APP_DIR}" 2>/dev/null || [[ ! -e "${APP_DIR}" ]] || rollback_failed=1
    fi

    if [[ "${TX_STATE_FILE_EXISTED:-0}" == "1" ]]; then
        cp -a "${TX_DIR}/installer_state" "${STATE_FILE}" || rollback_failed=1
    else
        rm -f "${STATE_FILE}"
    fi

    if [[ ${rollback_failed} -eq 0 ]]; then
        rm -rf "${TX_DIR}"
        if [[ "${TX_STATE_DIR_EXISTED:-1}" == "0" ]]; then
            rm -rf "${BACKUP_DIR}"
            rmdir "${STATE_DIR}" 2>/dev/null || true
        fi
        log_ok "已恢复到本次运行前状态"
    else
        log_error "自动恢复不完整，事务快照保留在 ${TX_DIR}"
    fi
    return "${original_status}"
}

restore_gateway_state_for_simple(){
    [[ "${IP_FORWARD_CHANGED:-0}" == "1" ]] || return 0
    log_step "恢复 gateway 模式修改的 IPv4 转发设置..."
    rm -f /etc/sysctl.d/99-dns-gateway.conf
    if [[ "${SYSCTL_DROPIN_EXISTED:-0}" == "1" ]]; then
        [[ -e "${BACKUP_DIR}/99-dns-gateway.conf" ]] || die "缺少原 sysctl 配置快照，拒绝切换到 simple"
        cp -a "${BACKUP_DIR}/99-dns-gateway.conf" /etc/sysctl.d/99-dns-gateway.conf
    fi
    sysctl -w "net.ipv4.ip_forward=${IP_FORWARD_BEFORE:-0}" >/dev/null || die "恢复 IPv4 转发值失败"
    state_set IP_FORWARD_CHANGED "0"
    log_ok "已恢复 gateway 模式前的 IPv4 转发设置"
}

on_install_exit(){
    local status=$?
    [[ ${INSTALL_COMMITTED:-0} -eq 1 || ! -f "${TX_DIR}/state.env" ]] && return "${status}"
    rollback_transaction "${status}"
}

init_state(){
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(stat -c %u "${STATE_FILE}" 2>/dev/null || echo -1)" == "0" ]] || die "状态文件不是 root 所有，拒绝加载"
        [[ "$(stat -c %a "${STATE_FILE}" 2>/dev/null || echo 000)" == "600" ]] || die "状态文件权限必须为 600"
        local requested_mode="${MODE}" requested_port="${DNS_PORT}" requested_table="${NFT_TABLE}"
        local requested_listen="${LISTEN_ADDR}" requested_upstream="${UPSTREAM_DNS}" requested_cache="${CACHE_TTL}"
        local requested_restrict="${RESTRICT_DNS}" requested_auto="${AUTO_ALLOW}" requested_rate="${RATE_LIMIT}"
        local requested_allow_nets="${ALLOW_NETS}" requested_allow_ips="${ALLOW_IPS}"
        local requested_gateway="${ENABLE_GATEWAY}" requested_nat="${ENABLE_NAT}" requested_wan="${WAN_IFACE}" requested_gateway_nets="${GATEWAY_NETS}"
        local requested_force="${FORCE_STOP_CONFLICT}" requested_version="${COREDNS_VERSION}" requested_mirror="${MIRROR_PREFIX}"
        # 状态文件只提供首次安装快照；加载后立即恢复本次调用参数，避免旧状态覆盖环境变量。
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
        [[ "${STATE_VERSION:-}" == "2" ]] || die "不支持的安装状态版本"
        PREVIOUS_MODE="${MODE:-}"
        local installed_port="${INSTALL_DNS_PORT:-${DNS_PORT:-53}}"
        MODE="${requested_mode}"; DNS_PORT="${requested_port}"; NFT_TABLE="${requested_table}"
        LISTEN_ADDR="${requested_listen}"; UPSTREAM_DNS="${requested_upstream}"; CACHE_TTL="${requested_cache}"
        RESTRICT_DNS="${requested_restrict}"; AUTO_ALLOW="${requested_auto}"; RATE_LIMIT="${requested_rate}"
        ALLOW_NETS="${requested_allow_nets}"; ALLOW_IPS="${requested_allow_ips}"
        ENABLE_GATEWAY="${requested_gateway}"; ENABLE_NAT="${requested_nat}"; WAN_IFACE="${requested_wan}"; GATEWAY_NETS="${requested_gateway_nets}"
        FORCE_STOP_CONFLICT="${requested_force}"; COREDNS_VERSION="${requested_version}"; MIRROR_PREFIX="${requested_mirror}"
        if [[ -n "${NFT_TABLE_NAME:-}" && "${NFT_TABLE_NAME}" != "${NFT_TABLE}" ]]; then
            die "首次安装使用的 NFT_TABLE=${NFT_TABLE_NAME}，重装时不能改为 ${NFT_TABLE}；请先卸载恢复"
        fi
        if [[ "${installed_port}" != "${DNS_PORT}" ]]; then
            die "当前安装使用 DNS_PORT=${installed_port}，重装时不能改为 ${DNS_PORT}；请先卸载恢复"
        fi
        log_info "检测到既有安装状态，将保留首次安装前快照"
        return
    fi
    if command -v nft >/dev/null 2>&1 && nft list table inet "${NFT_TABLE}" >/dev/null 2>&1; then
        die "检测到宿主机已有 nftables 表 inet ${NFT_TABLE}；请设置其他 NFT_TABLE，拒绝覆盖既有规则"
    fi
    mkdir -p "${BACKUP_DIR}"; chmod 700 "${STATE_DIR}" "${BACKUP_DIR}"
    : > "${STATE_FILE}"; chmod 600 "${STATE_FILE}"
    state_set STATE_VERSION "2"
    state_set NFT_TABLE_NAME "${NFT_TABLE}"
    state_set INSTALL_DNS_PORT "${DNS_PORT}"
    state_set MANAGED_NFT_CREATED "0"
    state_set STOPPED_UNITS ""
    state_set APP_DIR_EXISTED "$([[ -d "${APP_DIR}" ]] && echo 1 || echo 0)"
    if [[ -d "${APP_DIR}" ]]; then
        state_set APP_DIR_MODE "$(stat -c %a "${APP_DIR}")"
        state_set APP_DIR_UID "$(stat -c %u "${APP_DIR}")"
        state_set APP_DIR_GID "$(stat -c %g "${APP_DIR}")"
    fi
    state_set BIN_EXISTED "$([[ -e "${COREDNS_BIN}" ]] && echo 1 || echo 0)"
    state_set COREFILE_EXISTED "$([[ -e "${COREFILE}" ]] && echo 1 || echo 0)"
    state_set HOSTS_EXISTED "$([[ -e "${HOSTS_FILE}" ]] && echo 1 || echo 0)"
    state_set SERVICE_EXISTED "$([[ -e "${SERVICE_FILE}" ]] && echo 1 || echo 0)"
    state_set NFT_SERVICE_EXISTED "$([[ -e "${NFT_SERVICE_FILE}" ]] && echo 1 || echo 0)"
    state_set SERVICE_WAS_ACTIVE "$(systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null && echo 1 || echo 0)"
    state_set SERVICE_WAS_ENABLED "$(systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null && echo 1 || echo 0)"
    state_set NFT_SERVICE_WAS_ACTIVE "$(systemctl is-active --quiet "${NFT_SERVICE_NAME}" 2>/dev/null && echo 1 || echo 0)"
    state_set NFT_SERVICE_WAS_ENABLED "$(systemctl is-enabled --quiet "${NFT_SERVICE_NAME}" 2>/dev/null && echo 1 || echo 0)"
    state_set USER_EXISTED "$(id coredns >/dev/null 2>&1 && echo 1 || echo 0)"
    state_set GROUP_EXISTED "$(getent group coredns >/dev/null 2>&1 && echo 1 || echo 0)"
    state_set NFT_RULES_EXISTED "$([[ -e "${NFT_RULES_FILE}" ]] && echo 1 || echo 0)"
    state_set INFO_FILE_EXISTED "$([[ -e "${INFO_FILE}" ]] && echo 1 || echo 0)"
    state_set IP_FORWARD_BEFORE "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    state_set RESOLVED_WAS_ACTIVE "$(systemctl is-active --quiet systemd-resolved 2>/dev/null && echo 1 || echo 0)"
    state_set RESOLVED_DROPIN_EXISTED "$([[ -e /etc/systemd/resolved.conf.d/disable-stub.conf ]] && echo 1 || echo 0)"
    state_set SYSCTL_DROPIN_EXISTED "$([[ -e /etc/sysctl.d/99-dns-gateway.conf ]] && echo 1 || echo 0)"
    if [[ -L /etc/resolv.conf ]]; then
        state_set RESOLV_CONF_TYPE "symlink"; state_set RESOLV_CONF_TARGET "$(readlink /etc/resolv.conf)"
    elif [[ -f /etc/resolv.conf ]]; then
        state_set RESOLV_CONF_TYPE "file"; backup_once /etc/resolv.conf resolv.conf || true
    else
        state_set RESOLV_CONF_TYPE "missing"
    fi
    backup_once "${COREDNS_BIN}" coredns.bin || true
    backup_once "${SERVICE_FILE}" coredns.service || true
    backup_once "${NFT_SERVICE_FILE}" coredns-nftables.service || true
    backup_once "${COREFILE}" Corefile || true
    backup_once "${HOSTS_FILE}" hosts || true
    backup_once "${NFT_RULES_FILE}" nftables.nft || true
    backup_once "${INFO_FILE}" install-info.txt || true
    backup_once /etc/systemd/resolved.conf.d/disable-stub.conf disable-stub.conf || true
    backup_once /etc/sysctl.d/99-dns-gateway.conf 99-dns-gateway.conf || true
    if command -v nft >/dev/null 2>&1 && nft list table inet "${NFT_TABLE}" >/dev/null 2>&1; then
        nft list table inet "${NFT_TABLE}" > "${BACKUP_DIR}/nft-table.nft"
        state_set NFT_TABLE_EXISTED "1"
    else
        state_set NFT_TABLE_EXISTED "0"
    fi
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
    command -v nft >/dev/null || die "缺少 nftables"
    log_ok "依赖就绪"
}

resolve_coredns_version(){
    if [[ "${COREDNS_VERSION}" != "latest" ]]; then
        [[ "${COREDNS_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "COREDNS_VERSION 格式无效"
        echo "${COREDNS_VERSION}"; return
    fi
    local release_json tag ver
    release_json=$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/coredns/coredns/releases/latest) \
        || die "无法获取 CoreDNS 最新版本"
    tag=$(grep -m1 -oE '"tag_name":[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"' <<< "${release_json}" || true)
    ver=$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "${tag}" || true)
    [[ -n "${ver}" ]] || die "无法解析 CoreDNS 最新版本；请显式设置 COREDNS_VERSION"
    echo "${ver}"
}

verify_checksum(){
    local file="$1" sidecar_url="$2" asset="$3" expected actual sidecar
    sidecar=$(curl -fsSL --connect-timeout 15 --retry 3 "${sidecar_url}") || die "无法下载官方校验文件: ${asset}.sha256"
    expected=$(grep -m1 -oE '[0-9a-fA-F]{64}' <<< "${sidecar}" || true)
    [[ -n "${expected}" ]] || die "官方校验文件格式无效: ${asset}.sha256"
    command -v sha256sum >/dev/null 2>&1 || die "系统缺少 sha256sum，拒绝跳过完整性校验"
    actual=$(sha256sum "${file}" | awk '{print $1}')
    [[ "${expected,,}" == "${actual,,}" ]] || die "SHA256 校验失败: ${asset}"
    log_ok "SHA256 校验通过: ${asset}"
}

install_coredns(){
    local version asset official_url url tmpdir archive cur version_output
    version=$(resolve_coredns_version); COREDNS_VERSION="${version}"
    version_output=$("${COREDNS_BIN}" -version 2>/dev/null || true)
    cur="${version_output%%$'\n'*}"
    if [[ "${cur}" == *"${version}"* ]]; then log_ok "CoreDNS 已是 v${version}"; return; fi
    asset="coredns_${version}_linux_${COREDNS_ARCH}.tgz"
    official_url="https://github.com/coredns/coredns/releases/download/v${version}/${asset}"
    url="${MIRROR_PREFIX}${official_url}"
    tmpdir=$(mktemp -d); archive="${tmpdir}/${asset}"
    log_step "下载 CoreDNS v${version}..."
    if ! curl -fL --connect-timeout 15 --retry 3 -o "${archive}" "${url}"; then
        rm -r "${tmpdir}"; die "下载 CoreDNS 失败"
    fi
    verify_checksum "${archive}" "${official_url}.sha256" "${asset}"
    tar -tzf "${archive}" > "${tmpdir}/archive.list" || { rm -r "${tmpdir}"; die "无法读取 CoreDNS 压缩包"; }
    grep -Eq '(^|/)coredns$' "${tmpdir}/archive.list" || { rm -r "${tmpdir}"; die "压缩包不含 coredns"; }
    tar -xzf "${archive}" -C "${tmpdir}"
    [[ -f "${tmpdir}/coredns" ]] || { rm -r "${tmpdir}"; die "解压后未找到 coredns"; }
    install -o root -g root -m 0755 "${tmpdir}/coredns" "${COREDNS_BIN}"
    rm -r "${tmpdir}"
    cur=$("${COREDNS_BIN}" -version 2>/dev/null || true)
    cur=${cur%%$'\n'*}
    log_ok "CoreDNS: ${cur}"
}

prepare_coredns_user(){
    local shell=/usr/sbin/nologin
    [[ -x "${shell}" ]] || shell=/sbin/nologin
    if ! getent group coredns >/dev/null 2>&1; then
        groupadd --system coredns
        state_set_if_unset GROUP_CREATED "1"
    else
        state_set_if_unset GROUP_CREATED "0"
    fi
    if ! id coredns >/dev/null 2>&1; then
        useradd --system --gid coredns --home-dir /nonexistent --shell "${shell}" coredns
        state_set_if_unset USER_CREATED "1"
    else
        state_set_if_unset USER_CREATED "0"
    fi
}

disable_resolved_stub(){
    local listeners
    [[ "${DNS_PORT}" == "53" ]] || return 0
    systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
    listeners=$(ss -H -lntup 2>/dev/null || true)
    grep -qE ':53([^0-9]|$).*systemd-resolve' <<< "${listeners}" || return 0
    log_step "安全释放 systemd-resolved 的 53 端口..."
    mkdir -p /etc/systemd/resolved.conf.d
    printf '%s\n' '[Resolve]' 'DNSStubListener=no' > /etc/systemd/resolved.conf.d/disable-stub.conf
    systemctl restart systemd-resolved
    [[ -e /run/systemd/resolve/resolv.conf ]] && ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf
    state_set RESOLVED_STUB_CHANGED "1"
}

free_dns_port(){
    disable_resolved_stub
    command -v ss >/dev/null 2>&1 || die "缺少 ss，无法安全检查端口"
    local lines pids pid comm unit stopped=""
    lines=$(ss -H -lntup 2>/dev/null | awk -v p=":${DNS_PORT}" '$0 ~ p {print}' || true)
    [[ -z "${lines}" ]] && { log_ok "端口 ${DNS_PORT} 空闲"; return; }
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null && grep -q coredns <<< "${lines}"; then
        log_info "端口 ${DNS_PORT} 已由现有 CoreDNS 使用"; return
    fi
    pids=$(printf '%s\n' "${lines}" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)
    [[ -n "${pids}" ]] || die "端口 ${DNS_PORT} 被占用且无法识别进程，请执行: ss -lntup | grep :${DNS_PORT}"
    [[ "${FORCE_STOP_CONFLICT}" == "true" ]] || die "端口 ${DNS_PORT} 被占用。默认不会停止现有服务；确认后使用 FORCE_STOP_CONFLICT=true"
    for pid in ${pids}; do
        comm=$(ps -o comm= -p "${pid}" 2>/dev/null | tr -d ' ' || true)
        unit=$(ps -o unit= -p "${pid}" 2>/dev/null | tr -d ' ' || true)
        case "${comm}" in
            named|dnsmasq|unbound|systemd-resolve|systemd-resolved)
                [[ -n "${unit}" && "${unit}" != "-" && "${unit}" == *.service ]] || die "无法确定 ${comm} 的 systemd 单元，拒绝强杀"
                log_warn "停止冲突服务 ${unit}（卸载时会尝试恢复）"
                systemctl stop "${unit}"
                stopped="${stopped} ${unit}"
                TX_STOPPED_UNITS="${TX_STOPPED_UNITS} ${unit}"
                tx_set TX_STOPPED_UNITS "${TX_STOPPED_UNITS# }"
                if [[ " ${STOPPED_UNITS:-} " != *" ${unit} "* ]]; then
                    state_set STOPPED_UNITS "${STOPPED_UNITS:+${STOPPED_UNITS} }${unit}"
                fi
                ;;
            *) die "未知进程占用端口: pid=${pid} comm=${comm}；拒绝自动终止" ;;
        esac
    done
    ss -H -lntu 2>/dev/null | awk -v p=":${DNS_PORT}" '$0 ~ p {found=1} END{exit found?0:1}' \
        && die "端口 ${DNS_PORT} 仍被占用" || true
}

write_coredns_config(){
    log_step "生成 CoreDNS 配置..."
    mkdir -p "${APP_DIR}"
    : > "${HOSTS_FILE}"
    local record domain ip
    for record in "${LOCAL_RECORDS[@]+"${LOCAL_RECORDS[@]}"}"; do
        [[ -z "${record// }" ]] && continue
        domain=${record%% *}; ip=${record##* }
        is_ipv4 "${ip}" || die "本地域名记录 IP 无效: ${record}"
        printf '%s %s\n' "${ip}" "${domain}" >> "${HOSTS_FILE}"
    done
    cat > "${COREFILE}" <<EOF
.:${DNS_PORT} {
    bind ${LISTEN_ADDR}
    errors
    log
    health 127.0.0.1:8080
    ready 127.0.0.1:8181
    prometheus 127.0.0.1:9153
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
    chown root:coredns "${APP_DIR}"
    chown root:coredns "${COREFILE}" "${HOSTS_FILE}"
    chmod 750 "${APP_DIR}"
    chmod 640 "${COREFILE}" "${HOSTS_FILE}"
    state_set APP_DIR_MANAGED "1"
}

write_systemd_service(){
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=CoreDNS DNS Server
After=network-online.target ${NFT_SERVICE_NAME}.service
Wants=network-online.target

[Service]
Type=simple
User=coredns
Group=coredns
ExecStart=${COREDNS_BIN} -conf ${COREFILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null
}

write_nft_service(){
    local nft_bin
    nft_bin=$(command -v nft)
    cat > "${NFT_SERVICE_FILE}" <<EOF
[Unit]
Description=CoreDNS managed nftables rules
Before=${SERVICE_NAME}.service
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-${nft_bin} delete table inet ${NFT_TABLE}
ExecStart=${nft_bin} -f ${NFT_RULES_FILE}
ExecStop=-${nft_bin} delete table inet ${NFT_TABLE}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${NFT_SERVICE_NAME}" >/dev/null
}

apply_nft_rules(){
    local rules="$1"
    printf '%b' "${rules}" > "${NFT_RULES_FILE}"
    chmod 640 "${NFT_RULES_FILE}"; chown root:coredns "${NFT_RULES_FILE}"
    nft -c -f "${NFT_RULES_FILE}" || die "nftables 规则语法检查失败"
    nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
    nft -f "${NFT_RULES_FILE}" || die "nftables 规则应用失败；退出时将按本次事务快照恢复"
    write_nft_service
    systemctl restart "${NFT_SERVICE_NAME}" || die "nftables 服务启动失败；退出时将按本次事务快照恢复"
    state_set MANAGED_NFT_CREATED "1"
}

setup_simple_acl(){
    if [[ "${RESTRICT_DNS}" != "true" && "${AUTO_ALLOW}" != "true" ]]; then
        log_warn "DNS 对所有来源开放；请务必在云安全组限制来源"
        if [[ "${MANAGED_NFT_CREATED:-0}" == "1" ]]; then
            systemctl disable --now "${NFT_SERVICE_NAME}" 2>/dev/null || true
            nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
            rm -f "${NFT_SERVICE_FILE}" "${NFT_RULES_FILE}"
            systemctl daemon-reload
            state_set MANAGED_NFT_CREATED "0"
        fi
        return
    fi
    local rules net cip
    rules="add table inet ${NFT_TABLE}\n"
    rules+="add chain inet ${NFT_TABLE} input { type filter hook input priority -10; policy accept; }\n"
    rules+="add rule inet ${NFT_TABLE} input iifname \"lo\" accept\n"
    for net in ${ALLOW_NETS}; do
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${net} udp dport ${DNS_PORT} accept\n"
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${net} tcp dport ${DNS_PORT} accept\n"
    done
    for cip in ${ALLOW_IPS}; do
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${cip} udp dport ${DNS_PORT} accept\n"
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${cip} tcp dport ${DNS_PORT} accept\n"
    done
    if [[ "${AUTO_ALLOW}" == "true" ]]; then
        if (( RATE_LIMIT > 0 )); then
            rules+="add rule inet ${NFT_TABLE} input udp dport ${DNS_PORT} meter dns_rate_u { ip saddr limit rate over ${RATE_LIMIT}/second } drop\n"
            rules+="add rule inet ${NFT_TABLE} input tcp dport ${DNS_PORT} meter dns_rate_t { ip saddr limit rate over ${RATE_LIMIT}/second } drop\n"
        fi
        rules+="add rule inet ${NFT_TABLE} input udp dport ${DNS_PORT} accept\n"
        rules+="add rule inet ${NFT_TABLE} input tcp dport ${DNS_PORT} accept\n"
    else
        rules+="add rule inet ${NFT_TABLE} input udp dport ${DNS_PORT} drop\n"
        rules+="add rule inet ${NFT_TABLE} input tcp dport ${DNS_PORT} drop\n"
    fi
    apply_nft_rules "${rules}"
}

detect_wan_iface(){
    [[ -n "${WAN_IFACE}" ]] || WAN_IFACE=$(ip -4 route show default | awk '{print $5; exit}')
    [[ -n "${WAN_IFACE}" ]] || die "无法检测 WAN_IFACE"
    ip link show "${WAN_IFACE}" >/dev/null 2>&1 || die "WAN_IFACE 不存在: ${WAN_IFACE}"
}

enable_ip_forward(){
    local before
    before=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    if [[ "${IP_FORWARD_CHANGED:-0}" == "1" ]]; then
        [[ "${before}" == "1" ]] || sysctl -w net.ipv4.ip_forward=1 >/dev/null
        printf '%s\n' 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-dns-gateway.conf
        return
    fi
    if [[ "${before}" != "1" ]]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        printf '%s\n' 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-dns-gateway.conf
        state_set IP_FORWARD_CHANGED "1"
    else
        state_set_if_unset IP_FORWARD_CHANGED "0"
    fi
}

setup_gateway_nft(){
    detect_wan_iface
    local server_ip rules net cip
    server_ip=$(get_server_ip)
    rules="add table inet ${NFT_TABLE}\n"
    rules+="add chain inet ${NFT_TABLE} input { type filter hook input priority -10; policy accept; }\n"
    rules+="add chain inet ${NFT_TABLE} prerouting { type nat hook prerouting priority -100; policy accept; }\n"
    rules+="add chain inet ${NFT_TABLE} postrouting { type nat hook postrouting priority 100; policy accept; }\n"
    rules+="add rule inet ${NFT_TABLE} input iifname \"lo\" accept\n"
    for net in ${GATEWAY_NETS}; do
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${net} udp dport ${DNS_PORT} accept\n"
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${net} tcp dport ${DNS_PORT} accept\n"
        rules+="add rule inet ${NFT_TABLE} prerouting ip saddr ${net} ip daddr ${server_ip} udp dport ${DNS_PORT} accept\n"
        rules+="add rule inet ${NFT_TABLE} prerouting ip saddr ${net} ip daddr ${server_ip} tcp dport ${DNS_PORT} accept\n"
        rules+="add rule inet ${NFT_TABLE} prerouting ip saddr ${net} udp dport 53 dnat ip to ${server_ip}:${DNS_PORT}\n"
        rules+="add rule inet ${NFT_TABLE} prerouting ip saddr ${net} tcp dport 53 dnat ip to ${server_ip}:${DNS_PORT}\n"
        [[ "${ENABLE_NAT}" == "true" ]] && rules+="add rule inet ${NFT_TABLE} postrouting ip saddr ${net} oifname \"${WAN_IFACE}\" masquerade\n"
    done
    for cip in ${ALLOW_IPS}; do
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${cip} udp dport ${DNS_PORT} accept\n"
        rules+="add rule inet ${NFT_TABLE} input ip saddr ${cip} tcp dport ${DNS_PORT} accept\n"
    done
    rules+="add rule inet ${NFT_TABLE} input udp dport ${DNS_PORT} drop\n"
    rules+="add rule inet ${NFT_TABLE} input tcp dport ${DNS_PORT} drop\n"
    apply_nft_rules "${rules}"
    log_warn "gateway 仅处理并允许 GATEWAY_NETS: ${GATEWAY_NETS}；不会劫持本机上游 DNS"
}

ufw_status_output(){ ufw status 2>/dev/null || true; }
ufw_is_active(){
    local status first_line
    status=$(ufw_status_output)
    first_line="${status%%$'\n'*}"
    [[ "${first_line,,}" == *active* ]]
}
firewall_has_ufw_rule(){
    local status
    status=$(ufw_status_output)
    grep -Eq "(^|[[:space:]])${DNS_PORT}/$1([[:space:]]|$).*ALLOW" <<< "${status}"
}
configure_firewall(){
    state_set DNS_PORT "${DNS_PORT}"
    if command -v ufw >/dev/null 2>&1 && ufw_is_active; then
        local existed
        existed=$(firewall_has_ufw_rule udp && echo 1 || echo 0); state_set UFW_UDP_EXISTED "${existed}"
        [[ "${existed}" == 1 ]] || { ufw allow "${DNS_PORT}/udp" comment 'CoreDNS managed' >/dev/null; state_set UFW_UDP_ADDED "1"; }
        existed=$(firewall_has_ufw_rule tcp && echo 1 || echo 0); state_set UFW_TCP_EXISTED "${existed}"
        [[ "${existed}" == 1 ]] || { ufw allow "${DNS_PORT}/tcp" comment 'CoreDNS managed' >/dev/null; state_set UFW_TCP_ADDED "1"; }
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        local existed
        existed=$(firewall-cmd --quiet --permanent --query-port="${DNS_PORT}/udp" && echo 1 || echo 0); state_set FIREWALLD_UDP_EXISTED "${existed}"
        [[ "${existed}" == 1 ]] || { firewall-cmd --permanent --add-port="${DNS_PORT}/udp" >/dev/null; state_set FIREWALLD_UDP_ADDED "1"; }
        existed=$(firewall-cmd --quiet --permanent --query-port="${DNS_PORT}/tcp" && echo 1 || echo 0); state_set FIREWALLD_TCP_EXISTED "${existed}"
        [[ "${existed}" == 1 ]] || { firewall-cmd --permanent --add-port="${DNS_PORT}/tcp" >/dev/null; state_set FIREWALLD_TCP_ADDED "1"; }
        firewall-cmd --reload >/dev/null
    fi
}

get_server_ip(){
    local ip route_output host_output
    route_output=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
    ip=$(awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' <<< "${route_output}")
    if [[ -z "${ip}" ]]; then
        host_output=$(hostname -I 2>/dev/null || true)
        ip=${host_output%%[[:space:]]*}
    fi
    echo "${ip:-127.0.0.1}"
}

start_and_verify(){
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    systemctl is-active --quiet "${SERVICE_NAME}" || { journalctl -u "${SERVICE_NAME}" -n 40 --no-pager || true; die "CoreDNS 启动失败"; }
    local server_ip endpoint answer
    server_ip=$(get_server_ip); endpoint="${server_ip}:${DNS_PORT}"
    if command -v dig >/dev/null 2>&1; then
        answer=$(dig @127.0.0.1 -p "${DNS_PORT}" +short +time=3 +tries=1 example.com A) || die "本机 DNS 解析验证失败"
        [[ -n "${answer//[[:space:]]/}" ]] || die "本机 DNS 未返回有效 A 记录"
    fi
    cat > "${INFO_FILE}" <<EOF
模式=${MODE}
服务器IP=${server_ip}
DNS端口=${DNS_PORT}
CoreDNS版本=${COREDNS_VERSION}
NFT表=${NFT_TABLE}
状态文件=${STATE_FILE}
EOF
    chmod 640 "${INFO_FILE}"; chown root:coredns "${INFO_FILE}"
    log_ok "部署完成，DNS 地址: ${endpoint}"
    [[ "${RESTRICT_DNS}" == "false" || "${AUTO_ALLOW}" == "true" ]] && log_warn "当前允许公网来源，请在云安全组限制 UDP/TCP ${DNS_PORT} 的来源"
    echo "${endpoint}"
}

main(){
    require_root
    validate_config
    detect_os
    detect_arch
    install_dependencies
    begin_transaction
    trap on_install_exit EXIT
    init_state
    free_dns_port
    prepare_coredns_user
    install_coredns
    write_coredns_config
    write_systemd_service
    if [[ "${MODE}" == "gateway" ]]; then
        enable_ip_forward
        setup_gateway_nft
    else
        [[ "${PREVIOUS_MODE:-}" == "gateway" ]] && restore_gateway_state_for_simple
        setup_simple_acl
    fi
    configure_firewall
    state_set MODE "${MODE}"
    start_and_verify
    INSTALL_COMMITTED=1
    trap - EXIT
    rm -rf "${TX_DIR}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
