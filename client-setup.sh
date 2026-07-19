#!/usr/bin/env bash
# DNS 客户端安全配置脚本：只修改一种 DNS 后端，支持 --restore。
set -Eeuo pipefail

STATE_DIR="/var/lib/dns-client-setup"
STATE_FILE="${STATE_DIR}/state.env"
BACKUP_DIR="${STATE_DIR}/original"
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log_info(){ echo -e "${G}[INFO]${N} $*" >&2; }
log_warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
log_error(){ echo -e "${R}[ERROR]${N} $*" >&2; }
die(){ log_error "$*"; exit 1; }

[[ ${EUID} -eq 0 ]] || die "请用 root 或 sudo 运行"

state_set(){
    local key="$1" value="$2" tmp
    mkdir -p "${STATE_DIR}"; chmod 700 "${STATE_DIR}"
    tmp=$(mktemp "${STATE_DIR}/state.XXXXXX")
    [[ -f "${STATE_FILE}" ]] && grep -vE "^${key}=" "${STATE_FILE}" > "${tmp}" || true
    printf '%s=%q\n' "${key}" "${value}" >> "${tmp}"
    chmod 600 "${tmp}"; mv "${tmp}" "${STATE_FILE}"
}

is_ipv4(){
    local ip="$1" a b c d
    IFS=. read -r a b c d <<< "${ip}"
    [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    [[ ${#a} -le 3 && ${#b} -le 3 && ${#c} -le 3 && ${#d} -le 3 ]] || return 1
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}

restore_client(){
    [[ -f "${STATE_FILE}" ]] || { log_error "未找到可恢复状态: ${STATE_FILE}"; return 1; }
    [[ "$(stat -c %u "${STATE_FILE}" 2>/dev/null || echo -1)" == "0" ]] || { log_error "状态文件不是 root 所有，拒绝加载"; return 1; }
    [[ "$(stat -c %a "${STATE_FILE}" 2>/dev/null || echo 000)" == "600" ]] || { log_error "状态文件权限必须为 600"; return 1; }
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "2" ]] || { log_error "不支持的客户端状态版本"; return 1; }

    case "${DNS_BACKEND:-none}" in
        none) ;;
        networkmanager)
            [[ -n "${NM_CONNECTION:-}" ]] || { log_error "NetworkManager 状态缺少连接名称"; return 1; }
            ;;
        resolved)
            if [[ "${RESOLVED_DROPIN_EXISTED:-0}" == "1" && ! -e "${BACKUP_DIR}/dns-custom.conf" ]]; then
                log_error "缺少 systemd-resolved 配置快照"
                return 1
            fi
            ;;
        resolvconf)
            case "${RESOLV_CONF_TYPE:-missing}" in
                symlink) [[ -n "${RESOLV_CONF_TARGET:-}" ]] || { log_error "resolv.conf 符号链接目标缺失"; return 1; } ;;
                file) [[ -e "${BACKUP_DIR}/resolv.conf" ]] || { log_error "缺少 resolv.conf 快照"; return 1; } ;;
                missing) ;;
                *) log_error "resolv.conf 快照类型无效"; return 1 ;;
            esac
            ;;
        *) log_error "状态文件中的 DNS_BACKEND 无效"; return 1 ;;
    esac
    if [[ "${GATEWAY_CHANGED:-0}" == "1" && -z "${OLD_DEFAULT_ROUTE:-}" && -z "${GATEWAY_TARGET:-}" ]]; then
        log_error "网关状态缺少原路由和脚本网关标识，拒绝修改当前默认路由"
        return 1
    fi

    local failed=0 current_defaults gateway_target
    local -a route_args=()
    log_info "恢复 DNS 配置（后端: ${DNS_BACKEND:-none}）"

    if [[ "${GATEWAY_CHANGED:-0}" == "1" ]]; then
        if [[ -n "${OLD_DEFAULT_ROUTE:-}" ]]; then
            read -r -a route_args <<< "${OLD_DEFAULT_ROUTE#default }"
            if ! ip route replace default "${route_args[@]}"; then
                log_error "默认路由恢复失败"
                failed=1
            else
                state_set GATEWAY_CHANGED "0"
                log_info "已恢复默认路由: ${OLD_DEFAULT_ROUTE}"
            fi
        else
            current_defaults=$(ip -4 route show default || true)
            gateway_target="${GATEWAY_TARGET:-}"
            if [[ -z "${current_defaults}" ]]; then
                state_set GATEWAY_CHANGED "0"
                log_info "脚本新增的默认路由已不存在，无需重复删除"
            elif [[ -n "${gateway_target}" && "${current_defaults}" == *" via ${gateway_target}"* ]]; then
                if ! ip route del default via "${gateway_target}" 2>/dev/null; then
                    log_error "无法删除脚本新增的默认路由"
                    failed=1
                else
                    state_set GATEWAY_CHANGED "0"
                fi
            elif [[ -z "${gateway_target}" ]]; then
                if ! ip route del default 2>/dev/null; then
                    log_error "无法删除旧状态记录的默认路由"
                    failed=1
                else
                    state_set GATEWAY_CHANGED "0"
                fi
            else
                state_set GATEWAY_CHANGED "0"
                log_warn "当前默认路由已不是脚本设置的网关 ${gateway_target}，保留现状"
            fi
        fi
    fi

    case "${DNS_BACKEND:-none}" in
        none) ;;
        networkmanager)
            if ! command -v nmcli >/dev/null 2>&1; then
                log_error "缺少 nmcli，无法恢复 NetworkManager"
                failed=1
            else
                if ! nmcli con mod "${NM_CONNECTION}" \
                    ipv4.dns "${NM_IPV4_DNS:-}" ipv4.ignore-auto-dns "${NM_IPV4_IGNORE_AUTO:-no}" \
                    ipv6.dns "${NM_IPV6_DNS:-}" ipv6.ignore-auto-dns "${NM_IPV6_IGNORE_AUTO:-no}"; then
                    log_error "NetworkManager DNS 参数恢复失败"
                    failed=1
                elif ! nmcli con up "${NM_CONNECTION}" >/dev/null; then
                    log_error "NetworkManager 连接恢复激活失败"
                    failed=1
                fi
            fi
            ;;
        resolved)
            rm -f /etc/systemd/resolved.conf.d/dns-custom.conf
            if [[ "${RESOLVED_DROPIN_EXISTED:-0}" == "1" ]]; then
                if [[ ! -e "${BACKUP_DIR}/dns-custom.conf" ]] || ! cp -a "${BACKUP_DIR}/dns-custom.conf" /etc/systemd/resolved.conf.d/dns-custom.conf; then
                    log_error "systemd-resolved 配置快照恢复失败"
                    failed=1
                fi
            fi
            if ! systemctl restart systemd-resolved; then
                log_error "systemd-resolved 重启失败"
                failed=1
            fi
            if [[ "${RESOLVED_DIR_EXISTED:-1}" == "0" ]]; then rmdir /etc/systemd/resolved.conf.d 2>/dev/null || true; fi
            ;;
        resolvconf)
            rm -f /etc/resolv.conf
            case "${RESOLV_CONF_TYPE:-missing}" in
                symlink) ln -s "${RESOLV_CONF_TARGET}" /etc/resolv.conf || failed=1 ;;
                file)
                    if [[ ! -e "${BACKUP_DIR}/resolv.conf" ]] || ! cp -a "${BACKUP_DIR}/resolv.conf" /etc/resolv.conf; then
                        log_error "resolv.conf 快照恢复失败"
                        failed=1
                    fi
                    ;;
                missing) ;;
                *) log_error "resolv.conf 快照类型无效"; failed=1 ;;
            esac
            ;;
        *) log_error "状态文件中的 DNS_BACKEND 无效"; failed=1 ;;
    esac

    if [[ ${failed} -eq 0 ]]; then
        rm -rf "${STATE_DIR}"
        log_info "客户端配置已恢复"
        return 0
    fi
    log_error "恢复不完整，状态和快照保留在 ${STATE_DIR}"
    return 1
}

usage(){
    cat >&2 <<EOF
用法:
  sudo $0 <DNS服务器IP> [备用IP ...]
  sudo $0 <DNS服务器IP> [备用IP ...] --gateway --confirm-gateway
  sudo $0 --restore
EOF
}

if [[ "${1:-}" == "--restore" ]]; then
    [[ $# -eq 1 ]] || die "--restore 不能与其他参数同时使用"
    restore_client
    exit $?
fi

USE_GATEWAY=0
CONFIRM_GATEWAY=0
DNS_IPS=()
for arg in "$@"; do
    case "${arg}" in
        --gateway|-g) USE_GATEWAY=1 ;;
        --confirm-gateway) CONFIRM_GATEWAY=1 ;;
        --help|-h) usage; exit 0 ;;
        --*) die "未知参数: ${arg}" ;;
        *) DNS_IPS+=("${arg}") ;;
    esac
done
[[ ${#DNS_IPS[@]} -ge 1 ]] || { usage; exit 1; }
for ip in "${DNS_IPS[@]}"; do is_ipv4 "${ip}" || die "无效 IPv4 地址: ${ip}"; done
PRIMARY_DNS="${DNS_IPS[0]}"

preflight_dns(){
    local ip="$1" answer
    ip route get "${ip}" >/dev/null 2>&1 || die "DNS 服务器不可路由: ${ip}"
    if command -v dig >/dev/null 2>&1; then
        answer=$(dig @"${ip}" +short +time=3 +tries=1 example.com A) || die "DNS 服务器未通过解析测试: ${ip}"
        [[ -n "${answer//[[:space:]]/}" ]] || die "DNS 服务器未返回有效 A 记录: ${ip}"
    elif command -v nc >/dev/null 2>&1; then
        nc -z -w3 "${ip}" 53 >/dev/null 2>&1 || log_warn "TCP 53 探测失败，请确认 UDP 53 可用"
    else
        log_warn "系统没有 dig/nc，仅完成路由可达性检查"
    fi
}

init_state(){
    local route_output old_default
    route_output=$(ip -4 route show default || true)
    old_default="${route_output%%$'\n'*}"
    mkdir -p "${BACKUP_DIR}"; chmod 700 "${STATE_DIR}" "${BACKUP_DIR}"
    : > "${STATE_FILE}"; chmod 600 "${STATE_FILE}"
    state_set STATE_VERSION "2"
    state_set GATEWAY_CHANGED "0"
    state_set OLD_DEFAULT_ROUTE "${old_default}"
}

configure_networkmanager(){
    local conn values default_iface device_output
    default_iface=$(ip -4 route show default | awk '{print $5; exit}')
    [[ -n "${default_iface}" ]] || return 1
    device_output=$(nmcli -g GENERAL.CONNECTION device show "${default_iface}" 2>/dev/null || true)
    conn="${device_output%%$'\n'*}"
    [[ -n "${conn}" && "${conn}" != "--" ]] || return 1
    values=$(nmcli -g ipv4.dns,ipv4.ignore-auto-dns,ipv6.dns,ipv6.ignore-auto-dns connection show "${conn}") || return 1
    state_set NM_CONNECTION "${conn}"
    state_set NM_IPV4_DNS "$(sed -n '1p' <<< "${values}")"
    state_set NM_IPV4_IGNORE_AUTO "$(sed -n '2p' <<< "${values}")"
    state_set NM_IPV6_DNS "$(sed -n '3p' <<< "${values}")"
    state_set NM_IPV6_IGNORE_AUTO "$(sed -n '4p' <<< "${values}")"
    state_set DNS_BACKEND "networkmanager"
    nmcli con mod "${conn}" ipv4.dns "${DNS_IPS[*]}" ipv4.ignore-auto-dns yes
    nmcli con up "${conn}" >/dev/null
    log_info "已通过 NetworkManager 配置 DNS（未修改 IPv6 DNS）"
}

configure_resolved(){
    local dir_existed=0
    [[ -d /etc/systemd/resolved.conf.d ]] && dir_existed=1
    if [[ -e /etc/systemd/resolved.conf.d/dns-custom.conf ]]; then
        cp -a /etc/systemd/resolved.conf.d/dns-custom.conf "${BACKUP_DIR}/dns-custom.conf"
        state_set RESOLVED_DROPIN_EXISTED "1"
    else
        state_set RESOLVED_DROPIN_EXISTED "0"
    fi
    state_set RESOLVED_DIR_EXISTED "${dir_existed}"
    state_set DNS_BACKEND "resolved"
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/dns-custom.conf <<EOF
[Resolve]
DNS=${DNS_IPS[*]}
Domains=~.
EOF
    systemctl restart systemd-resolved
    log_info "已通过 systemd-resolved 配置 DNS"
}

configure_resolvconf(){
    local tmp resolv_type resolv_target=""
    if [[ -L /etc/resolv.conf ]]; then
        resolv_type="symlink"
        resolv_target=$(readlink /etc/resolv.conf)
    elif [[ -f /etc/resolv.conf ]]; then
        resolv_type="file"
        cp -a /etc/resolv.conf "${BACKUP_DIR}/resolv.conf"
    else
        resolv_type="missing"
    fi
    tmp=$(mktemp)
    {
        echo "# Managed by dns client-setup.sh"
        for ip in "${DNS_IPS[@]}"; do echo "nameserver ${ip}"; done
        [[ -f /etc/resolv.conf ]] && grep -E '^[[:space:]]*(search|domain|options)[[:space:]]' /etc/resolv.conf || true
    } > "${tmp}"
    state_set RESOLV_CONF_TYPE "${resolv_type}"
    [[ "${resolv_type}" == "symlink" ]] && state_set RESOLV_CONF_TARGET "${resolv_target}"
    state_set DNS_BACKEND "resolvconf"
    rm -f /etc/resolv.conf
    if ! install -m 0644 "${tmp}" /etc/resolv.conf; then
        rm -f "${tmp}"
        return 1
    fi
    rm -f "${tmp}"
    log_info "已直接配置 /etc/resolv.conf"
}

rollback_on_exit(){
    local status=$?
    [[ ${CONFIG_COMMITTED:-0} -eq 1 || ! -f "${STATE_FILE}" ]] && return "${status}"
    trap - EXIT
    log_error "配置未完成，正在自动恢复原设置"
    restore_client || log_error "自动恢复失败，请检查 ${STATE_FILE}"
    exit "${status}"
}

for ip in "${DNS_IPS[@]}"; do preflight_dns "${ip}"; done
if [[ ${USE_GATEWAY} -eq 1 ]]; then
    [[ ${CONFIRM_GATEWAY} -eq 1 ]] || die "修改默认网关有断网风险；确认后追加 --confirm-gateway"
    route_output=$(ip -4 route get "${PRIMARY_DNS}") || die "无法读取到 ${PRIMARY_DNS} 的路由"
    route_to_dns="${route_output%%$'\n'*}"
    [[ "${route_to_dns}" != *" via "* ]] || die "${PRIMARY_DNS} 不在直连网段，不能作为默认网关"
fi

[[ ! -e "${STATE_DIR}" ]] || die "检测到既有客户端配置或未完成恢复。请先执行 sudo $0 --restore"
CONFIG_COMMITTED=0
trap rollback_on_exit EXIT
init_state
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    configure_networkmanager || die "NetworkManager 活跃但没有可配置连接"
elif systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    configure_resolved
else
    configure_resolvconf
fi

if [[ ${USE_GATEWAY} -eq 1 ]]; then
    state_set GATEWAY_TARGET "${PRIMARY_DNS}"
    state_set GATEWAY_CHANGED "1"
    ip route replace default via "${PRIMARY_DNS}"
    ip route get 1.1.1.1 >/dev/null 2>&1 || die "新网关无法路由公网"
    if command -v ping >/dev/null 2>&1; then ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || die "新网关连通性验证失败"; fi
fi

if command -v getent >/dev/null 2>&1; then getent ahostsv4 example.com >/dev/null || die "系统 DNS 解析验证失败"; fi
CONFIG_COMMITTED=1
trap - EXIT
log_info "客户端接入完成；恢复命令: sudo $0 --restore"
