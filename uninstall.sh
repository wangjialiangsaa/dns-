#!/usr/bin/env bash
# DNS 服务端精准卸载：优先按 install.sh 保存的首次安装状态恢复。
set -Eeuo pipefail

SERVICE_NAME="coredns"
NFT_SERVICE_NAME="coredns-nftables"
APP_DIR="/etc/coredns"
COREDNS_BIN="/usr/local/bin/coredns"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NFT_SERVICE_FILE="/etc/systemd/system/${NFT_SERVICE_NAME}.service"
NFT_RULES_FILE="${APP_DIR}/nftables.nft"
INFO_FILE="${APP_DIR}/install-info.txt"
STATE_DIR="/var/lib/coredns-installer"
STATE_FILE="${STATE_DIR}/state.env"
BACKUP_DIR="${STATE_DIR}/original"
TX_DIR="${STATE_DIR}/transaction"
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/disable-stub.conf"
SYSCTL_DROPIN="/etc/sysctl.d/99-dns-gateway.conf"
DNS_PORT="${DNS_PORT:-53}"
NFT_TABLE="${NFT_TABLE:-dns_force}"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
log_info(){ echo -e "${G}[INFO]${N} $*" >&2; }
log_warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
log_error(){ echo -e "${R}[ERROR]${N} $*" >&2; }
log_step(){ echo -e "${C}[STEP]${N} $*" >&2; }
log_ok(){ echo -e "${G}[ OK ]${N} $*" >&2; }
die(){ log_error "$*"; exit 1; }

require_root(){ [[ ${EUID} -eq 0 ]] || die "请使用 root 或 sudo 运行"; }

confirm(){
    if [[ "${FORCE:-}" == "1" || "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then return; fi
    echo -n "确认卸载 DNS 解析服务器并恢复安装前状态? [y/N] "
    read -r answer
    [[ "${answer}" =~ ^[yY]$ ]] || { log_info "已取消"; exit 0; }
}

load_state(){
    if [[ -f "${STATE_FILE}" ]]; then
        [[ ! -e "${TX_DIR}" ]] || die "检测到未完成安装事务 ${TX_DIR}；请先按事务快照恢复，拒绝直接卸载"
        [[ "$(stat -c %u "${STATE_FILE}" 2>/dev/null || echo -1)" == "0" ]] || die "状态文件不是 root 所有，拒绝加载"
        [[ "$(stat -c %a "${STATE_FILE}" 2>/dev/null || echo 000)" == "600" ]] || die "状态文件权限必须为 600"
        # 仅加载本安装脚本生成、权限为 600 的 root 状态文件。
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
        [[ "${STATE_VERSION:-}" == "2" ]] || die "不支持的状态文件版本"
        DNS_PORT="${DNS_PORT:-53}"
        NFT_TABLE="${NFT_TABLE_NAME:-${NFT_TABLE:-dns_force}}"
        log_info "已加载安装状态: ${STATE_FILE}"
        return
    fi

    LEGACY_INSTALL=1
    log_warn "未找到新版状态文件，将执行保守兼容卸载"
    log_warn "不会修改 IP 转发、systemd-resolved、UFW 转发策略或 firewalld masquerade"
    if [[ -f "${APP_DIR}/Corefile" ]]; then
        local detected_port
        detected_port=$(grep -m1 -oE '^\.:[0-9]+' "${APP_DIR}/Corefile" 2>/dev/null | cut -d: -f2 || true)
        [[ -n "${detected_port}" ]] && DNS_PORT="${detected_port}"
    fi
}

ufw_rule_exists(){
    local status
    status=$(ufw status 2>/dev/null || true)
    grep -Eq "(^|[[:space:]])${DNS_PORT}/$1([[:space:]]|$).*ALLOW" <<< "${status}"
}

restore_firewall(){
    local failed=0 firewalld_changed=0
    log_step "撤销本脚本新增的防火墙端口"
    if [[ "${UFW_UDP_ADDED:-0}" == "1" ]]; then
        if ! command -v ufw >/dev/null 2>&1; then
            failed=1
        elif ufw_rule_exists udp && ! ufw --force delete allow "${DNS_PORT}/udp" >/dev/null 2>&1; then
            failed=1
        fi
    fi
    if [[ "${UFW_TCP_ADDED:-0}" == "1" ]]; then
        if ! command -v ufw >/dev/null 2>&1; then
            failed=1
        elif ufw_rule_exists tcp && ! ufw --force delete allow "${DNS_PORT}/tcp" >/dev/null 2>&1; then
            failed=1
        fi
    fi
    if [[ "${FIREWALLD_UDP_ADDED:-0}" == "1" ]]; then
        if ! command -v firewall-cmd >/dev/null 2>&1; then
            failed=1
        elif firewall-cmd --quiet --permanent --query-port="${DNS_PORT}/udp"; then
            firewall-cmd --permanent --remove-port="${DNS_PORT}/udp" >/dev/null 2>&1 && firewalld_changed=1 || failed=1
        fi
    fi
    if [[ "${FIREWALLD_TCP_ADDED:-0}" == "1" ]]; then
        if ! command -v firewall-cmd >/dev/null 2>&1; then
            failed=1
        elif firewall-cmd --quiet --permanent --query-port="${DNS_PORT}/tcp"; then
            firewall-cmd --permanent --remove-port="${DNS_PORT}/tcp" >/dev/null 2>&1 && firewalld_changed=1 || failed=1
        fi
    fi
    if [[ ${firewalld_changed} -eq 1 ]] && ! firewall-cmd --reload >/dev/null 2>&1; then failed=1; fi
    if [[ ${failed} -ne 0 ]]; then log_error "防火墙规则恢复不完整"; return 1; fi
    return 0
}

restore_resolved(){
    local failed=0
    [[ "${RESOLVED_STUB_CHANGED:-0}" == "1" ]] || return 0
    rm -f "${RESOLVED_DROPIN}"
    if [[ "${RESOLVED_DROPIN_EXISTED:-0}" == "1" ]]; then
        if [[ ! -e "${BACKUP_DIR}/disable-stub.conf" ]] || ! cp -a "${BACKUP_DIR}/disable-stub.conf" "${RESOLVED_DROPIN}"; then failed=1; fi
    fi

    rm -f /etc/resolv.conf
    case "${RESOLV_CONF_TYPE:-missing}" in
        symlink) ln -s "${RESOLV_CONF_TARGET}" /etc/resolv.conf || failed=1 ;;
        file)
            if [[ ! -e "${BACKUP_DIR}/resolv.conf" ]] || ! cp -a "${BACKUP_DIR}/resolv.conf" /etc/resolv.conf; then failed=1; fi
            ;;
        missing) ;;
        *) log_error "未知 resolv.conf 快照类型"; failed=1 ;;
    esac

    if [[ "${RESOLVED_WAS_ACTIVE:-0}" == "1" ]] && ! systemctl restart systemd-resolved >/dev/null 2>&1; then failed=1; fi
    if [[ ${failed} -ne 0 ]]; then log_error "systemd-resolved 或 resolv.conf 恢复不完整"; return 1; fi
    log_ok "已恢复 systemd-resolved 与 resolv.conf"
    return 0
}

restore_ip_forward(){
    local failed=0
    [[ "${IP_FORWARD_CHANGED:-0}" == "1" ]] || return 0
    rm -f "${SYSCTL_DROPIN}"
    if [[ "${SYSCTL_DROPIN_EXISTED:-0}" == "1" ]]; then
        if [[ ! -e "${BACKUP_DIR}/99-dns-gateway.conf" ]] || ! cp -a "${BACKUP_DIR}/99-dns-gateway.conf" "${SYSCTL_DROPIN}"; then failed=1; fi
    fi
    if ! sysctl -w "net.ipv4.ip_forward=${IP_FORWARD_BEFORE:-0}" >/dev/null 2>&1; then failed=1; fi
    if [[ ${failed} -ne 0 ]]; then log_error "IPv4 转发设置恢复不完整"; return 1; fi
    log_ok "已恢复 net.ipv4.ip_forward=${IP_FORWARD_BEFORE:-0}"
    return 0
}

restore_nftables(){
    if ! command -v nft >/dev/null 2>&1; then
        [[ "${MANAGED_NFT_CREATED:-0}" == "0" && "${NFT_TABLE_EXISTED:-0}" == "0" ]] && return 0
        log_error "缺少 nft 命令，无法恢复 nftables"
        return 1
    fi
    if [[ "${NFT_TABLE_EXISTED:-0}" == "1" ]]; then
        [[ -s "${BACKUP_DIR}/nft-table.nft" ]] || { log_error "缺少原 nftables 表快照"; return 1; }
        if ! nft -c -f "${BACKUP_DIR}/nft-table.nft"; then
            log_error "原 nftables 表快照语法无效，拒绝替换当前规则"
            return 1
        fi
    fi
    if [[ "${MANAGED_NFT_CREATED:-0}" == "1" ]]; then nft delete table inet "${NFT_TABLE}" 2>/dev/null || true; fi
    if [[ "${NFT_TABLE_EXISTED:-0}" == "1" ]]; then
        nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
        if ! nft -f "${BACKUP_DIR}/nft-table.nft"; then
            log_error "原 nftables 表恢复失败，快照保留在 ${BACKUP_DIR}/nft-table.nft"
            return 1
        fi
        log_ok "已恢复原 nftables 表 inet ${NFT_TABLE}"
    fi
    return 0
}

restore_one_file(){
    local target="$1" existed="$2" backup_name="$3"
    if [[ "${existed}" == "1" ]]; then
        [[ -e "${BACKUP_DIR}/${backup_name}" || -L "${BACKUP_DIR}/${backup_name}" ]] || { log_error "缺少文件快照: ${backup_name}"; return 1; }
        mkdir -p "$(dirname "${target}")"
        rm -f "${target}"
        cp -a "${BACKUP_DIR}/${backup_name}" "${target}"
    else
        rm -f "${target}"
    fi
}

restore_files(){
    local failed=0
    log_step "恢复安装前 CoreDNS 文件"
    restore_one_file "${COREDNS_BIN}" "${BIN_EXISTED:-0}" coredns.bin || failed=1
    restore_one_file "${SERVICE_FILE}" "${SERVICE_EXISTED:-0}" coredns.service || failed=1
    restore_one_file "${NFT_SERVICE_FILE}" "${NFT_SERVICE_EXISTED:-0}" coredns-nftables.service || failed=1
    restore_one_file "${COREFILE}" "${COREFILE_EXISTED:-0}" Corefile || failed=1
    restore_one_file "${HOSTS_FILE}" "${HOSTS_EXISTED:-0}" hosts || failed=1
    restore_one_file "${NFT_RULES_FILE}" "${NFT_RULES_EXISTED:-0}" nftables.nft || failed=1
    restore_one_file "${INFO_FILE}" "${INFO_FILE_EXISTED:-0}" install-info.txt || failed=1

    if [[ "${APP_DIR_EXISTED:-0}" == "1" ]]; then
        chown "${APP_DIR_UID:-0}:${APP_DIR_GID:-0}" "${APP_DIR}" 2>/dev/null || failed=1
        chmod "${APP_DIR_MODE:-755}" "${APP_DIR}" 2>/dev/null || failed=1
    else
        rmdir "${APP_DIR}" 2>/dev/null || [[ ! -e "${APP_DIR}" ]] || failed=1
    fi
    if [[ ${failed} -ne 0 ]]; then log_error "CoreDNS 文件恢复不完整"; return 1; fi
    return 0
}

restore_services(){
    local failed=0 unit
    systemctl daemon-reload >/dev/null 2>&1 || failed=1
    if [[ "${SERVICE_EXISTED:-0}" == "1" ]]; then
        if [[ "${SERVICE_WAS_ENABLED:-0}" == "1" ]]; then systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || failed=1; else systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || failed=1; fi
        if [[ "${SERVICE_WAS_ACTIVE:-0}" == "1" ]]; then systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || failed=1; fi
    else
        systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
    if [[ "${NFT_SERVICE_EXISTED:-0}" == "1" ]]; then
        if [[ "${NFT_SERVICE_WAS_ENABLED:-0}" == "1" ]]; then systemctl enable "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || failed=1; else systemctl disable "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || failed=1; fi
        if [[ "${NFT_SERVICE_WAS_ACTIVE:-0}" == "1" ]]; then systemctl restart "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || failed=1; fi
    else
        systemctl disable "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
    for unit in ${STOPPED_UNITS:-}; do systemctl start "${unit}" >/dev/null 2>&1 || failed=1; done
    if [[ ${failed} -ne 0 ]]; then log_error "原 systemd 服务状态恢复不完整"; return 1; fi
    return 0
}

validate_restore_snapshots(){
    local failed=0
    local pair existed name
    for pair in \
        "${BIN_EXISTED:-0}:coredns.bin" \
        "${SERVICE_EXISTED:-0}:coredns.service" \
        "${NFT_SERVICE_EXISTED:-0}:coredns-nftables.service" \
        "${COREFILE_EXISTED:-0}:Corefile" \
        "${HOSTS_EXISTED:-0}:hosts" \
        "${NFT_RULES_EXISTED:-0}:nftables.nft" \
        "${INFO_FILE_EXISTED:-0}:install-info.txt"; do
        existed=${pair%%:*}
        name=${pair#*:}
        if [[ "${existed}" == "1" && ! -e "${BACKUP_DIR}/${name}" && ! -L "${BACKUP_DIR}/${name}" ]]; then
            log_error "缺少必要快照: ${BACKUP_DIR}/${name}"
            failed=1
        fi
    done
    if [[ "${RESOLVED_STUB_CHANGED:-0}" == "1" ]]; then
        if [[ "${RESOLVED_DROPIN_EXISTED:-0}" == "1" && ! -e "${BACKUP_DIR}/disable-stub.conf" ]]; then log_error "缺少 resolved 配置快照"; failed=1; fi
        if [[ "${RESOLV_CONF_TYPE:-missing}" == "file" && ! -e "${BACKUP_DIR}/resolv.conf" ]]; then log_error "缺少 resolv.conf 快照"; failed=1; fi
    fi
    if [[ "${IP_FORWARD_CHANGED:-0}" == "1" && "${SYSCTL_DROPIN_EXISTED:-0}" == "1" && ! -e "${BACKUP_DIR}/99-dns-gateway.conf" ]]; then
        log_error "缺少 sysctl 配置快照"
        failed=1
    fi
    if [[ "${NFT_TABLE_EXISTED:-0}" == "1" && ! -s "${BACKUP_DIR}/nft-table.nft" ]]; then
        log_error "缺少原 nftables 表快照"
        failed=1
    fi
    [[ ${failed} -eq 0 ]]
}

legacy_uninstall(){
    local service_managed=0 nft_service_managed=0

    if [[ -f "${SERVICE_FILE}" ]] \
        && grep -Fq "ExecStart=${COREDNS_BIN} -conf ${APP_DIR}/Corefile" "${SERVICE_FILE}"; then
        service_managed=1
        systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
        rm -f "${SERVICE_FILE}"
    else
        log_warn "无法确认 ${SERVICE_FILE} 归属，已保留"
    fi

    if [[ -f "${NFT_SERVICE_FILE}" ]] \
        && grep -Fq "ExecStart=" "${NFT_SERVICE_FILE}" \
        && grep -Fq -- "-f ${NFT_RULES_FILE}" "${NFT_SERVICE_FILE}"; then
        nft_service_managed=1
        systemctl disable --now "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || true
        rm -f "${NFT_SERVICE_FILE}"
    else
        log_warn "无法确认 ${NFT_SERVICE_FILE} 归属，已保留"
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    [[ ${service_managed} -eq 1 ]] && log_info "已移除可确认归属的 CoreDNS systemd 单元"
    [[ ${nft_service_managed} -eq 1 ]] && log_info "已移除可确认归属的 nftables systemd 单元"
    log_warn "旧版没有状态快照；已保留 CoreDNS 二进制、配置目录和 nftables 表，避免误删宿主资源"
}

main(){
    require_root
    confirm "${1:-}"
    load_state

    if [[ "${LEGACY_INSTALL:-0}" == "1" ]]; then
        legacy_uninstall
        log_ok "兼容卸载完成；未改动未记录的宿主网络设置"
        return
    fi

    validate_restore_snapshots || die "恢复所需快照不完整；未修改系统，状态保留在 ${STATE_DIR}"

    local failed=0
    log_step "停止本脚本管理的服务"
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl stop "${NFT_SERVICE_NAME}" >/dev/null 2>&1 || true

    restore_firewall || failed=1
    restore_resolved || failed=1
    restore_ip_forward || failed=1
    restore_nftables || failed=1
    restore_files || failed=1
    restore_services || failed=1

    if [[ ${failed} -eq 0 && "${USER_CREATED:-0}" == "1" ]] && id coredns >/dev/null 2>&1; then
        userdel coredns >/dev/null 2>&1 || { log_error "coredns 用户删除失败"; failed=1; }
    fi
    if [[ ${failed} -eq 0 && "${GROUP_CREATED:-0}" == "1" ]] && getent group coredns >/dev/null 2>&1; then
        groupdel coredns >/dev/null 2>&1 || { log_error "coredns 用户组删除失败"; failed=1; }
    fi

    if [[ ${failed} -ne 0 ]]; then
        log_error "卸载恢复不完整，状态和快照保留在 ${STATE_DIR}"
        return 1
    fi

    rm -rf "${STATE_DIR}"
    log_ok "卸载完成，已按首次安装快照恢复宿主状态"
}

main "$@"
