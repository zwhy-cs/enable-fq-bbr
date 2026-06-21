#!/usr/bin/env bash

set -euo pipefail

# 显式声明 PATH 保证在 crontab (@reboot) 等极简环境变量下命令能被正确找到
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

readonly SCRIPT_VERSION="1.4.1"
readonly SCRIPT_NAME="端口带宽限速"
readonly SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
readonly CONFIG_DIR="/etc/port-bandwidth-limit"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly LOCK_FILE="$CONFIG_DIR/.lock"
readonly MAX_BURST_BYTES=$((4 * 1024 * 1024))

readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

# 说明：
# - 本脚本只处理 IPv4。
# - 本脚本只处理出口方向 egress 限速。
# - 本脚本会接管目标网卡的 root qdisc；若检测到未由本脚本管理的自定义 root qdisc，会拒绝覆盖。

# ==================== 系统检测与依赖 ====================

detect_system() {
    if [ -f /etc/lsb-release ] && grep -qi "Ubuntu" /etc/lsb-release 2>/dev/null; then
        echo "ubuntu"
        return
    fi
    if [ -f /etc/debian_version ]; then
        echo "debian"
        return
    fi
    echo "unknown"
}

install_missing_tools() {
    local missing_tools=("$@")
    local system_type
    system_type="$(detect_system)"
    local pkg_cmd

    case "$system_type" in
        ubuntu) pkg_cmd="apt" ;;
        debian) pkg_cmd="apt-get" ;;
        *)
            echo -e "${RED}不支持的系统类型: $system_type${NC}" >&2
            echo "支持的系统: Ubuntu, Debian" >&2
            echo "请手动安装: ${missing_tools[*]}" >&2
            exit 1
            ;;
    esac

    echo -e "${YELLOW}检测到缺少工具: ${missing_tools[*]}${NC}"
    echo "正在自动安装..."

    "$pkg_cmd" update -qq
    for tool in "${missing_tools[@]}"; do
        case "$tool" in
            nft) "$pkg_cmd" install -y nftables ;;
            tc|ip|ss) "$pkg_cmd" install -y iproute2 ;;
            jq) "$pkg_cmd" install -y jq ;;
            flock) "$pkg_cmd" install -y util-linux ;;
            *) "$pkg_cmd" install -y "$tool" ;;
        esac
    done

    echo -e "${GREEN}依赖工具安装完成${NC}"
}

check_dependencies() {
    local silent_mode=${1:-false}
    local missing_tools=()
    local required_tools=("nft" "tc" "jq" "ip" "ss" "flock")

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        if [ "${PBL_AUTO_INSTALL_DEPS:-false}" = "true" ]; then
            install_missing_tools "${missing_tools[@]}"
        else
            echo -e "${RED}缺少依赖工具: ${missing_tools[*]}${NC}" >&2
            echo "请先手动安装依赖，或使用 PBL_AUTO_INSTALL_DEPS=true 允许脚本自动安装。" >&2
            echo "Debian/Ubuntu 示例: apt-get update && apt-get install -y nftables iproute2 jq util-linux" >&2
            exit 1
        fi
    fi

    local still_missing=()
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            still_missing+=("$tool")
        fi
    done

    if [ ${#still_missing[@]} -gt 0 ]; then
        echo -e "${RED}安装失败，仍缺少工具: ${still_missing[*]}${NC}" >&2
        echo "请手动安装后重试" >&2
        exit 1
    fi

    if [ "$silent_mode" != "true" ]; then
        echo -e "${GREEN}依赖检查通过${NC}"
    fi
}

check_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要 root 权限运行${NC}" >&2
        exit 1
    fi
}

acquire_lock() {
    mkdir -p "$CONFIG_DIR"
    exec 9>"$LOCK_FILE"
    flock -x 9
}

# ==================== 网络接口 ====================

get_network_interfaces() {
    ip -o link show up | awk -F': ' '{print $2}' | cut -d'@' -f1 | awk '$1 != "lo" && $1 != ""'
}

get_default_interface() {
    local configured_interface
    configured_interface="$(jq -r '.tc.interface // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    if [ -n "$configured_interface" ]; then
        echo "$configured_interface"
        return
    fi

    local default_interface
    default_interface="$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)"
    if [ -n "$default_interface" ]; then
        echo "$default_interface"
        return
    fi

    local first_interface
    first_interface="$(get_network_interfaces | head -n1 || true)"
    if [ -n "$first_interface" ]; then
        echo "$first_interface"
        return
    fi

    echo "eth0"
}

get_configured_runtime_interfaces() {
    jq -r '
      [
        (.tc.interface // ""),
        (.tc.managed_interfaces[]? // ""),
        (.limits[]?.interface // "")
      ] |
      .[] |
      select(. != "")
    ' "$CONFIG_FILE" 2>/dev/null | sort -u
}

interface_is_managed() {
    local interface="$1"
    jq -e --arg iface "$interface" '(.tc.managed_interfaces // []) | index($iface) != null' "$CONFIG_FILE" >/dev/null 2>&1
}

remember_managed_interface() {
    local interface="$1"
    update_config --arg iface "$interface" '.tc.managed_interfaces = (((.tc.managed_interfaces // []) + [$iface]) | unique)'
}

forget_managed_interface() {
    local interface="$1"
    update_config --arg iface "$interface" '.tc.managed_interfaces = ((.tc.managed_interfaces // []) | map(select(. != $iface)))'
}

set_interface() {
    local interface="$1"
    if ! ip link show dev "$interface" >/dev/null 2>&1; then
        echo -e "${RED}错误：网卡不存在: $interface${NC}" >&2
        return 1
    fi

    local old_interfaces=()
    mapfile -t old_interfaces < <(get_configured_runtime_interfaces)

    local backup_file
    backup_file="$(backup_config)" || return 1

    if ! update_config --arg iface "$interface" '.tc.interface = $iface | .limits |= with_entries(.value.interface = $iface)' ||
       ! rebuild_all_limits; then
        echo -e "${RED}错误：切换网卡失败，正在回滚配置${NC}" >&2
        rollback_config_and_runtime "$backup_file"
        return 1
    fi

    local old_interface
    for old_interface in "${old_interfaces[@]}"; do
        if [ "$old_interface" != "$interface" ] && ip link show dev "$old_interface" >/dev/null 2>&1; then
            reset_tc_root "$old_interface"
            forget_managed_interface "$old_interface" || true
        fi
    done

    cleanup_config_backup "$backup_file"
    echo -e "${GREEN}默认限速网卡已设置为: $interface${NC}"
}

# ==================== 端口与带宽工具函数 ====================

is_port_range() {
    local port=$1
    [[ "$port" =~ ^[0-9]+-[0-9]+$ ]]
}

to_dec() {
    local value="$1"
    echo $((10#$value))
}

port_start() {
    local port="$1"
    if is_port_range "$port"; then
        to_dec "${port%-*}"
    else
        to_dec "$port"
    fi
}

port_end() {
    local port="$1"
    if is_port_range "$port"; then
        to_dec "${port#*-}"
    else
        to_dec "$port"
    fi
}

validate_port_or_range() {
    local port="$1"

    if ! [[ "$port" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
        echo -e "${RED}错误：端口格式无效: $port${NC}" >&2
        return 1
    fi

    local start_port end_port
    start_port="$(port_start "$port")"
    end_port="$(port_end "$port")"

    if [ "$start_port" -lt 1 ] || [ "$end_port" -gt 65535 ] || [ "$start_port" -gt "$end_port" ]; then
        echo -e "${RED}错误：端口范围无效，必须在 1-65535 内且起始端口不能大于结束端口${NC}" >&2
        return 1
    fi

    return 0
}

ports_overlap() {
    local a="$1"
    local b="$2"
    local a_start a_end b_start b_end
    a_start="$(port_start "$a")"
    a_end="$(port_end "$a")"
    b_start="$(port_start "$b")"
    b_end="$(port_end "$b")"

    [ "$a_start" -le "$b_end" ] && [ "$b_start" -le "$a_end" ]
}

check_port_overlap() {
    local new_port="$1"
    local existing_ports
    mapfile -t existing_ports < <(get_limited_ports)

    for existing_port in "${existing_ports[@]}"; do
        if ! validate_port_or_range "$existing_port" >/dev/null 2>&1; then
            echo -e "${RED}错误：配置中存在无效端口规则: $existing_port${NC}" >&2
            return 1
        fi
        if [ "$existing_port" = "$new_port" ]; then
            continue
        fi
        if ports_overlap "$new_port" "$existing_port"; then
            echo -e "${RED}错误：端口 $new_port 与已有规则 $existing_port 重叠${NC}" >&2
            echo "请先删除或调整已有规则，避免同一流量被多条规则竞争匹配。" >&2
            return 1
        fi
    done

    return 0
}

validate_bandwidth() {
    local input="$1"
    local lower_input
    lower_input="$(echo "$input" | tr '[:upper:]' '[:lower:]')"

    if [[ "$lower_input" =~ ^[1-9][0-9]*(kbps|mbps|gbps)$ ]]; then
        return 0
    fi
    return 1
}

convert_bandwidth_to_tc() {
    local rate="$1"
    local lower
    lower="$(echo "$rate" | tr '[:upper:]' '[:lower:]')"

    case "$lower" in
        *kbps) echo "${lower%kbps}kbit" ;;
        *mbps) echo "${lower%mbps}mbit" ;;
        *gbps) echo "${lower%gbps}gbit" ;;
        *) return 1 ;;
    esac
}

parse_tc_rate_to_kbps() {
    local rate="$1"
    local lower
    lower="$(echo "$rate" | tr '[:upper:]' '[:lower:]')"

    if [[ "$lower" =~ ^([1-9][0-9]*)gbit$ ]]; then
        echo $((BASH_REMATCH[1] * 1000000))
        return
    fi
    if [[ "$lower" =~ ^([1-9][0-9]*)mbit$ ]]; then
        echo $((BASH_REMATCH[1] * 1000))
        return
    fi
    if [[ "$lower" =~ ^([1-9][0-9]*)kbit$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi

    echo "0"
}

calculate_tc_burst() {
    local rate_kbps="$1"
    local rate_bytes_per_sec=$((rate_kbps * 1000 / 8))
    local burst_by_formula=$((rate_bytes_per_sec / 20))
    # 【优化】为兼容现代网卡的 TSO/GSO（TCP/Generic Segmentation Offload）超大包，
    # 最小 burst 大小设为 64KB (65536 字节)。如果设得过小（如原版的 2 * 1500 = 3000 字节），
    # 在低速限速场景下，超大包会因为超过桶大小而被丢弃，导致网络吞吐极差甚至卡死。
    local min_burst=65536
    local burst_bytes

    if [ "$burst_by_formula" -gt "$min_burst" ]; then
        burst_bytes="$burst_by_formula"
    else
        burst_bytes="$min_burst"
    fi

    if [ "$burst_bytes" -gt "$MAX_BURST_BYTES" ]; then
        echo "$MAX_BURST_BYTES"
    else
        echo "$burst_bytes"
    fi
}

format_tc_burst() {
    # 使用原始字节数，避免整数单位换算导致低速场景 burst 被截断。
    echo "$1"
}

generate_tc_class_id() {
    local class_minor="$1"
    printf '1:%x\n' "$class_minor"
}

# ==================== 配置管理 ====================

init_config() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<'JSON'
{
  "nftables": {
    "table_name": "port_bw_limit",
    "family": "ip"
  },
  "tc": {
    "interface": "",
    "root_rate": "10000mbit",
    "default_class": "1:30",
    "managed_interfaces": []
  },
  "meta": {
    "next_class_minor": 4096,
    "next_mark": 1000
  },
  "limits": {}
}
JSON
    fi

    migrate_config
}

update_config() {
    local tmp_file
    tmp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
    if jq "$@" "$CONFIG_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$CONFIG_FILE"
    else
        rm -f "$tmp_file"
        return 1
    fi
}

backup_config() {
    local backup_file
    backup_file="$(mktemp "${CONFIG_FILE}.bak.XXXXXX")"
    cp -p "$CONFIG_FILE" "$backup_file"
    echo "$backup_file"
}

restore_config() {
    local backup_file="$1"
    cp -p "$backup_file" "$CONFIG_FILE"
}

cleanup_config_backup() {
    local backup_file="$1"
    rm -f "$backup_file"
}

rollback_config_and_runtime() {
    local backup_file="$1"

    restore_config "$backup_file"
    if ! rebuild_all_limits >/dev/null 2>&1; then
        echo -e "${YELLOW}警告：配置已回滚，但旧运行时规则恢复失败，请检查 tc/nft 状态${NC}" >&2
    fi
    cleanup_config_backup "$backup_file"
}

migrate_config() {
    local tmp_file
    tmp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
    if jq '
      .nftables = (if (.nftables | type) == "object" then .nftables else {} end) |
      .nftables.table_name = (.nftables.table_name // "port_bw_limit") |
      .nftables.family = "ip" |
      .tc = (if (.tc | type) == "object" then .tc else {} end) |
      .tc.interface = (.tc.interface // "") |
      .tc.root_rate = (.tc.root_rate // "10000mbit") |
      .tc.default_class = (.tc.default_class // "1:30") |
      .tc.managed_interfaces = (if (.tc.managed_interfaces | type) == "array" then (.tc.managed_interfaces | map(select(type == "string")) | unique) else [] end) |
      .meta = (if (.meta | type) == "object" then .meta else {} end) |
      .meta.next_class_minor = (.meta.next_class_minor // 4096) |
      .meta.next_mark = (.meta.next_mark // 1000) |
      .limits = (if (.limits | type) == "object" then .limits else {} end) |
      .limits |= with_entries(.value.updated_at = (.value.updated_at // .value.created_at // ""))
    ' "$CONFIG_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$CONFIG_FILE"
    else
        rm -f "$tmp_file"
        return 1
    fi
    ensure_rule_ids || return 1
}

get_limited_ports() {
    jq -r '.limits | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -V
}

limit_exists() {
    local port="$1"
    jq -e --arg port "$port" '.limits | has($port)' "$CONFIG_FILE" >/dev/null 2>&1
}

get_limit_value() {
    local port="$1"
    local field="$2"
    jq -r --arg port "$port" --arg field "$field" '.limits[$port][$field] // empty' "$CONFIG_FILE"
}

find_unused_class_minor() {
    declare -A used_map
    local minor
    while read -r minor; do
        if [ -n "$minor" ]; then
            used_map["$minor"]=1
        fi
    done < <(jq -r '.limits[]?.class_minor | select(. != null)' "$CONFIG_FILE" 2>/dev/null)

    local class_minor=4096
    while [ -n "${used_map[$class_minor]}" ]; do
        class_minor=$((class_minor + 1))
    done

    if [ "$class_minor" -gt 65535 ]; then
        echo -e "${RED}错误：TC class_minor 资源已耗尽${NC}" >&2
        return 1
    fi

    echo "$class_minor"
}

find_unused_mark_id() {
    declare -A used_map
    local mark
    while read -r mark; do
        if [ -n "$mark" ]; then
            used_map["$mark"]=1
        fi
    done < <(jq -r '.limits[]?.mark_id | select(. != null)' "$CONFIG_FILE" 2>/dev/null)

    local mark_id=1000
    while [ -n "${used_map[$mark_id]}" ]; do
        mark_id=$((mark_id + 1))
    done

    if [ "$mark_id" -gt 65535 ]; then
        echo -e "${RED}错误：mark_id 资源已耗尽${NC}" >&2
        return 1
    fi

    echo "$mark_id"
}

ensure_rule_ids() {
    local ports
    mapfile -t ports < <(jq -r '.limits | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -V)

    local changed
    changed=false

    for port in "${ports[@]}"; do
        local class_minor mark_id
        class_minor="$(get_limit_value "$port" "class_minor")"
        mark_id="$(get_limit_value "$port" "mark_id")"

        if [ -z "$class_minor" ]; then
            class_minor="$(find_unused_class_minor)" || return 1
            update_config --arg port "$port" --argjson class_minor "$class_minor" '.limits[$port].class_minor = $class_minor' || return 1
            changed=true
        fi

        if [ -z "$mark_id" ]; then
            mark_id="$(find_unused_mark_id)" || return 1
            update_config --arg port "$port" --argjson mark_id "$mark_id" '.limits[$port].mark_id = $mark_id' || return 1
            changed=true
        fi
    done

    if [ "$changed" = "true" ]; then
        update_config '
          .meta.next_class_minor = (([.limits[]?.class_minor // empty] | max // 4095) + 1) |
          .meta.next_mark = (([.limits[]?.mark_id // empty] | max // 999) + 1)
        ' || return 1
    fi
}

allocate_ids_for_new_rule() {
    local port="$1"
    local class_minor mark_id
    class_minor="$(find_unused_class_minor)" || return 1
    mark_id="$(find_unused_mark_id)" || return 1

    update_config \
        --arg port "$port" \
        --argjson class_minor "$class_minor" \
        --argjson mark_id "$mark_id" \
        '.limits[$port].class_minor = $class_minor | .limits[$port].mark_id = $mark_id' || return 1
}

# ==================== nftables + TC 核心 ====================

validate_nft_identifier() {
    local identifier="$1"
    [[ "$identifier" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

is_positive_int() {
    local value="$1"
    [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

validate_runtime_config() {
    local table_name
    table_name="$(jq -r '.nftables.table_name' "$CONFIG_FILE")"

    if ! validate_nft_identifier "$table_name"; then
        echo -e "${RED}错误：nftables 表名无效: $table_name${NC}" >&2
        return 1
    fi

    local root_rate root_rate_kbps
    root_rate="$(jq -r '.tc.root_rate' "$CONFIG_FILE")"
    root_rate_kbps="$(parse_tc_rate_to_kbps "$root_rate")"
    if [ "$root_rate_kbps" -le 0 ]; then
        echo -e "${RED}错误：root_rate 无效: $root_rate${NC}" >&2
        return 1
    fi

    local port tc_rate tc_rate_kbps class_minor mark_id
    while IFS= read -r port; do
        validate_port_or_range "$port" || return 1

        tc_rate="$(get_limit_value "$port" "tc_rate")"
        tc_rate_kbps="$(parse_tc_rate_to_kbps "$tc_rate")"
        if [ "$tc_rate_kbps" -le 0 ]; then
            echo -e "${RED}错误：端口 $port 的 tc_rate 无效: $tc_rate${NC}" >&2
            return 1
        fi
        if [ "$tc_rate_kbps" -gt "$root_rate_kbps" ]; then
            echo -e "${RED}错误：端口 $port 的限速 $tc_rate 高于根速率 $root_rate${NC}" >&2
            return 1
        fi

        class_minor="$(get_limit_value "$port" "class_minor")"
        mark_id="$(get_limit_value "$port" "mark_id")"

        if ! is_positive_int "$class_minor" || [ "$class_minor" -lt 4096 ] || [ "$class_minor" -gt 65535 ]; then
            echo -e "${RED}错误：端口 $port 的 class_minor 无效: $class_minor${NC}" >&2
            return 1
        fi

        if ! is_positive_int "$mark_id" || [ "$mark_id" -lt 1000 ] || [ "$mark_id" -gt 65535 ]; then
            echo -e "${RED}错误：端口 $port 的 mark_id 无效: $mark_id${NC}" >&2
            return 1
        fi
    done < <(get_limited_ports)

    if ! jq -e '([.limits[]?.class_minor | tonumber] | length == (unique | length))' "$CONFIG_FILE" >/dev/null; then
        echo -e "${RED}错误：配置中存在重复 class_minor${NC}" >&2
        return 1
    fi

    if ! jq -e '([.limits[]?.mark_id | tonumber] | length == (unique | length))' "$CONFIG_FILE" >/dev/null; then
        echo -e "${RED}错误：配置中存在重复 mark_id${NC}" >&2
        return 1
    fi

    return 0
}

reset_tc_root() {
    local interface="$1"
    if interface_is_managed "$interface" && root_qdisc_has_script_shape "$interface"; then
        tc qdisc del dev "$interface" root 2>/dev/null || true
    fi
}

reset_current_script_qdisc() {
    local interface="$1"
    if root_qdisc_has_script_shape "$interface"; then
        tc qdisc del dev "$interface" root 2>/dev/null || true
    fi
}

root_qdisc_has_script_shape() {
    local interface="$1"

    tc qdisc show dev "$interface" 2>/dev/null |
        awk '
            $1 == "qdisc" && $2 == "htb" && $3 == "1:" && $0 ~ /(^| )root( |$)/ && $0 ~ /(^| )default (0x)?30( |$)/ {
                found = 1
            }
            END { exit(found ? 0 : 1) }
        '
}

get_root_qdisc_kind() {
    local interface="$1"

    tc qdisc show dev "$interface" 2>/dev/null |
        awk '$1 == "qdisc" && $0 ~ /(^| )root( |$)/ { print $2; exit }'
}

ensure_root_qdisc_replace_allowed() {
    local interface="$1"
    local kind

    if interface_is_managed "$interface"; then
        return 0
    fi

    kind="$(get_root_qdisc_kind "$interface")"
    case "$kind" in
        ""|noqueue|fq_codel|pfifo_fast|mq|multiq|fq)
            return 0
            ;;
        *)
            echo -e "${RED}错误：检测到未由本脚本管理的 root qdisc: ${kind:-unknown}${NC}" >&2
            echo "为避免覆盖已有 tc 策略，请先手动确认并清理该网卡 root qdisc，或换用未配置 tc 的网卡。" >&2
            return 1
            ;;
    esac
}

reset_nft_table() {
    local table_name
    table_name="$(jq -r '.nftables.table_name' "$CONFIG_FILE")"
    nft delete table ip "$table_name" 2>/dev/null || true
}

reset_runtime_rules() {
    local interface="$1"
    reset_tc_root "$interface"
    reset_nft_table
}

init_nftables() {
    local table_name
    table_name="$(jq -r '.nftables.table_name' "$CONFIG_FILE")"

    nft add table ip "$table_name" || return 1
    nft "add chain ip $table_name output { type filter hook output priority -150; policy accept; }" || return 1
    nft "add chain ip $table_name forward { type filter hook forward priority -150; policy accept; }" || return 1
}

add_nftables_mark_rules() {
    local port="$1"
    local mark_id="$2"
    local table_name
    table_name="$(jq -r '.nftables.table_name' "$CONFIG_FILE")"
    # 只标记本地发出的 sport，防止限制外部访问的 dport
    nft add rule ip "$table_name" output tcp sport "$port" meta mark 0 meta mark set "$mark_id" comment "\"pbl:$port:tcp:sport\"" || return 1
    nft add rule ip "$table_name" output udp sport "$port" meta mark 0 meta mark set "$mark_id" comment "\"pbl:$port:udp:sport\"" || return 1
    nft add rule ip "$table_name" forward tcp sport "$port" meta mark 0 meta mark set "$mark_id" comment "\"pbl:$port:tcp:sport\"" || return 1
    nft add rule ip "$table_name" forward udp sport "$port" meta mark 0 meta mark set "$mark_id" comment "\"pbl:$port:udp:sport\"" || return 1
}

setup_tc_base() {
    local interface="$1"
    local root_rate root_rate_kbps root_burst
    root_rate="$(jq -r '.tc.root_rate' "$CONFIG_FILE")"
    root_rate_kbps="$(parse_tc_rate_to_kbps "$root_rate")"
    root_burst="$(calculate_tc_burst "$root_rate_kbps")"

    # 先清理已有的 root qdisc，防止某些不支持 in-place change/replace 的 qdisc（如 fq）报错
    tc qdisc del dev "$interface" root 2>/dev/null || true

    tc qdisc replace dev "$interface" root handle 1: htb default 30 || return 1
    RUNTIME_TC_TOUCHED=true
    tc class add dev "$interface" parent 1: classid 1:1 htb rate "$root_rate" ceil "$root_rate" burst "$root_burst" || return 1
    tc class add dev "$interface" parent 1:1 classid 1:30 htb rate "$root_rate" ceil "$root_rate" burst "$root_burst" || return 1
}

add_tc_limit_for_rule() {
    local interface="$1"
    local port="$2"
    local tc_rate class_minor mark_id class_id qdisc_handle rate_kbps burst_bytes burst_size
    tc_rate="$(get_limit_value "$port" "tc_rate")"
    class_minor="$(get_limit_value "$port" "class_minor")"
    mark_id="$(get_limit_value "$port" "mark_id")"
    class_id="$(generate_tc_class_id "$class_minor")"
    qdisc_handle="$(printf '%x' "$class_minor")"
    rate_kbps="$(parse_tc_rate_to_kbps "$tc_rate")"
    burst_bytes="$(calculate_tc_burst "$rate_kbps")"
    burst_size="$(format_tc_burst "$burst_bytes")"
    # 创建 HTB Class
    tc class add dev "$interface" parent 1:1 classid "$class_id" htb rate "$tc_rate" ceil "$tc_rate" burst "$burst_size" || return 1
    
    # 【优化】为该 Class 附加 fq_codel 保证连接公平性，避免丢包和高延迟
    tc qdisc add dev "$interface" parent "$class_id" handle "${qdisc_handle}:" fq_codel || return 1
    # 添加 TC 过滤器。本脚本只在 nftables ip 表中标记 IPv4 流量。
    tc filter add dev "$interface" protocol ip parent 1:0 prio 10 handle "$mark_id" fw flowid "$class_id" || return 1
}

tc_class_exists() {
    local interface="$1"
    local class_id="$2"

    tc class show dev "$interface" 2>/dev/null | awk -v class_id="$class_id" '$3 == class_id { found = 1 } END { exit(found ? 0 : 1) }'
}

tc_filter_exists() {
    local interface="$1"
    local mark_id="$2"
    local class_id="$3"
    local mark_hex mark_hex_padded
    mark_hex="$(printf '0x%x' "$mark_id")"
    mark_hex_padded="$(printf '0x%08x' "$mark_id")"

    tc filter show dev "$interface" parent 1: 2>/dev/null |
        awk -v mark_dec="$mark_id" \
            -v mark_hex="$mark_hex" \
            -v mark_hex_padded="$mark_hex_padded" \
            -v class_id="$class_id" '
            {
                line = tolower($0)
                handle_ok = (line ~ ("handle " tolower(mark_hex) "([^0-9a-f]|$)") || line ~ ("handle " tolower(mark_hex_padded) "([^0-9a-f]|$)") || line ~ ("handle " mark_dec "([^0-9]|$)"))
                class_ok = line ~ ("classid " class_id "([^0-9a-f:]|$)")
                if (handle_ok && class_ok) {
                    found = 1
                }
            }
            END { exit(found ? 0 : 1) }
        '
}

tc_leaf_qdisc_exists() {
    local interface="$1"
    local class_id="$2"
    local qdisc_handle="${class_id#*:}:"

    tc qdisc show dev "$interface" 2>/dev/null |
        awk -v qdisc_handle="$qdisc_handle" -v class_id="$class_id" '
            $1 == "qdisc" && $2 == "fq_codel" && $3 == qdisc_handle && $0 ~ ("(^| )parent " class_id "( |$)") {
                found = 1
            }
            END { exit(found ? 0 : 1) }
        '
}

nft_mark_rule_exists() {
    local chain="$1"
    local proto="$2"
    local port="$3"
    local mark_id="$4"
    local table_name mark_hex mark_hex_padded
    table_name="$(jq -r '.nftables.table_name' "$CONFIG_FILE")"
    mark_hex="$(printf '0x%x' "$mark_id")"
    mark_hex_padded="$(printf '0x%08x' "$mark_id")"

    nft list chain ip "$table_name" "$chain" 2>/dev/null |
        awk -v proto="$proto" \
            -v port="$port" \
            -v mark_dec="$mark_id" \
            -v mark_hex="$mark_hex" \
            -v mark_hex_padded="$mark_hex_padded" '
            {
                line = $0
                lower = tolower($0)
                has_mark = (lower ~ ("meta mark set " tolower(mark_hex) "([^0-9a-f]|$)") || lower ~ ("meta mark set " tolower(mark_hex_padded) "([^0-9a-f]|$)") || line ~ ("meta mark set " mark_dec "([^0-9]|$)"))
                sport_ok = line ~ (proto " sport " port "([^0-9-]|$)")
                if (sport_ok && has_mark) {
                    found = 1
                }
            }
            END { exit(found ? 0 : 1) }
        '
}

nft_rules_exist() {
    local port="$1"
    local mark_id="$2"

    nft_mark_rule_exists output tcp "$port" "$mark_id" &&
        nft_mark_rule_exists output udp "$port" "$mark_id" &&
        nft_mark_rule_exists forward tcp "$port" "$mark_id" &&
        nft_mark_rule_exists forward udp "$port" "$mark_id"
}

runtime_rule_status() {
    local interface="$1"
    local port="$2"
    local class_id="$3"
    local mark_id="$4"
    local ok_count=0

    if tc_class_exists "$interface" "$class_id"; then
        ok_count=$((ok_count + 1))
    fi
    if tc_filter_exists "$interface" "$mark_id" "$class_id"; then
        ok_count=$((ok_count + 1))
    fi
    if tc_leaf_qdisc_exists "$interface" "$class_id"; then
        ok_count=$((ok_count + 1))
    fi
    if nft_rules_exist "$port" "$mark_id"; then
        ok_count=$((ok_count + 1))
    fi

    if [ "$ok_count" -eq 4 ]; then
        echo "running"
    elif [ "$ok_count" -gt 0 ]; then
        echo "partial"
    else
        echo "missing"
    fi
}

apply_runtime_rules() {
    local interface="$1"
    shift

    RUNTIME_TC_TOUCHED=false
    ensure_root_qdisc_replace_allowed "$interface" || return 1
    reset_nft_table
    setup_tc_base "$interface" || return 1

    local port
    for port in "$@"; do
        add_tc_limit_for_rule "$interface" "$port" || return 1
    done

    init_nftables || return 1

    for port in "$@"; do
        local mark_id
        mark_id="$(get_limit_value "$port" "mark_id")"
        add_nftables_mark_rules "$port" "$mark_id" || return 1
    done
}

rebuild_all_limits() {
    ensure_rule_ids || return 1
    validate_runtime_config || return 1

    local interface
    interface="$(get_default_interface)"

    local ports
    mapfile -t ports < <(get_limited_ports)

    if [ ${#ports[@]} -eq 0 ]; then
        reset_nft_table
        if ip link show dev "$interface" >/dev/null 2>&1; then
            reset_tc_root "$interface"
        fi
        forget_managed_interface "$interface" || return 1
        return 0
    fi

    if ! ip link show dev "$interface" >/dev/null 2>&1; then
        echo -e "${RED}错误：网卡不存在: $interface${NC}" >&2
        return 1
    fi

    if ! apply_runtime_rules "$interface" "${ports[@]}"; then
        echo -e "${RED}错误：运行时规则重建失败，已清理本脚本创建的部分规则${NC}" >&2
        reset_nft_table
        if [ "${RUNTIME_TC_TOUCHED:-false}" = "true" ]; then
            reset_current_script_qdisc "$interface"
        fi
        return 1
    fi

    if ! remember_managed_interface "$interface"; then
        echo -e "${RED}错误：运行时规则已应用，但接管状态写入失败，正在清理运行时规则${NC}" >&2
        reset_nft_table
        if [ "${RUNTIME_TC_TOUCHED:-false}" = "true" ]; then
            reset_current_script_qdisc "$interface"
        fi
        return 1
    fi
}

# ==================== 展示函数 ====================

show_current_ports() {
    echo -e "${GREEN}当前系统端口使用情况:${NC}"
    printf "%-15s %-9s\n" "程序名" "端口"
    echo "────────────────────────────────────────────────────────"

    declare -A program_ports=()
    while read -r line; do
        if [[ "$line" =~ LISTEN|UNCONN ]]; then
            local local_addr port program
            local_addr="$(echo "$line" | awk '{print $5}')"
            port="$(echo "$local_addr" | grep -o ':[0-9]*$' | cut -d':' -f2 || true)"
            program="$(echo "$line" | awk '{print $7}' | cut -d'"' -f2 2>/dev/null || true)"
            if [ -n "$port" ] && [ -n "$program" ] && [ "$program" != "-" ]; then
                if [ -z "${program_ports[$program]:-}" ]; then
                    program_ports[$program]="$port"
                elif [[ ! "|${program_ports[$program]}|" =~ \|$port\| ]]; then
                    program_ports[$program]="${program_ports[$program]}|$port"
                fi
            fi
        fi
    done < <(ss -tulnp 2>/dev/null || true)

    if [ ${#program_ports[@]} -gt 0 ]; then
        local program
        for program in $(printf '%s\n' "${!program_ports[@]}" | sort); do
            printf "%-15s %-9s\n" "$program" "${program_ports[$program]}"
        done
    else
        echo "无活跃端口"
    fi

    echo "────────────────────────────────────────────────────────"
}

list_limits() {
    local ports
    mapfile -t ports < <(get_limited_ports)

    local interface root_rate
    interface="$(get_default_interface)"
    root_rate="$(jq -r '.tc.root_rate' "$CONFIG_FILE")"

    echo "模式: IPv4 出口方向 egress 限速"
    echo "网卡: $interface"
    echo "根速率: $root_rate"
    echo "────────────────────────────────────────────────────────"

    if ! validate_runtime_config; then
        echo -e "${RED}配置无效，请修复 $CONFIG_FILE 后重试${NC}"
        return 1
    fi

    if [ ${#ports[@]} -eq 0 ]; then
        echo "当前没有限速规则"
        return
    fi

    for port in "${ports[@]}"; do
        local rate created updated tc_rate class_minor mark_id class_id port_type
        rate="$(get_limit_value "$port" "rate")"
        created="$(get_limit_value "$port" "created_at")"
        updated="$(get_limit_value "$port" "updated_at")"
        tc_rate="$(get_limit_value "$port" "tc_rate")"
        class_minor="$(get_limit_value "$port" "class_minor")"
        mark_id="$(get_limit_value "$port" "mark_id")"
        class_id="$(generate_tc_class_id "$class_minor")"
        port_type="单端口"
        if is_port_range "$port"; then
            port_type="端口段"
        fi

        echo -e "端口: ${GREEN}$port${NC} | 类型: $port_type | 限速: ${YELLOW}$rate${NC}"
        echo "  TC速率: $tc_rate | classid: $class_id | mark: $mark_id | 创建时间: $created | 更新时间: $updated"

        case "$(runtime_rule_status "$interface" "$port" "$class_id" "$mark_id")" in
            running) echo -e "  状态: ${GREEN}运行中${NC}" ;;
            partial) echo -e "  状态: ${YELLOW}部分运行（tc/nft 规则不完整，建议执行 --restore）${NC}" ;;
            *) echo -e "  状态: ${RED}未运行${NC}" ;;
        esac
        echo
    done
}

# ==================== 业务逻辑 ====================

save_limit_to_config() {
    local port="$1"
    local input_rate="$2"
    local tc_rate
    tc_rate="$(convert_bandwidth_to_tc "$input_rate")"

    local existed
    if limit_exists "$port"; then
        existed=true
    else
        existed=false
    fi

    if [ "$existed" != "true" ]; then
        update_config --arg port "$port" '.limits[$port] = {}' || return 1
        allocate_ids_for_new_rule "$port" || return 1
        update_config --arg port "$port" --arg created "$(date -Iseconds)" '.limits[$port].created_at = $created' || return 1
    fi

    update_config \
        --arg rate "$input_rate" \
        --arg tc_rate "$tc_rate" \
        --arg iface "$(get_default_interface)" \
        --arg updated "$(date -Iseconds)" \
        --arg port "$port" \
        '.limits[$port].rate = $rate | .limits[$port].tc_rate = $tc_rate | .limits[$port].interface = $iface | .limits[$port].updated_at = $updated' || return 1
}

get_max_limit_rate_kbps() {
    local max_rate=0
    local port tc_rate rate_kbps

    while IFS= read -r port; do
        tc_rate="$(get_limit_value "$port" "tc_rate")"
        rate_kbps="$(parse_tc_rate_to_kbps "$tc_rate")"
        if [ "$rate_kbps" -gt "$max_rate" ]; then
            max_rate="$rate_kbps"
        fi
    done < <(get_limited_ports)

    echo "$max_rate"
}

set_root_rate() {
    local input_rate="$1"

    if ! validate_bandwidth "$input_rate"; then
        echo -e "${RED}错误：根速率格式无效: $input_rate${NC}" >&2
        echo "格式示例: 1000Mbps, 10Gbps" >&2
        return 1
    fi

    local tc_rate
    tc_rate="$(convert_bandwidth_to_tc "$input_rate")"
    local root_rate_kbps max_limit_kbps
    root_rate_kbps="$(parse_tc_rate_to_kbps "$tc_rate")"
    max_limit_kbps="$(get_max_limit_rate_kbps)"

    if [ "$max_limit_kbps" -gt 0 ] && [ "$root_rate_kbps" -lt "$max_limit_kbps" ]; then
        echo -e "${RED}错误：根速率不能低于现有限速规则的最大速率${NC}" >&2
        return 1
    fi

    local backup_file
    backup_file="$(backup_config)" || return 1

    if ! update_config --arg rate "$tc_rate" '.tc.root_rate = $rate'; then
        cleanup_config_backup "$backup_file"
        return 1
    fi

    if [ "$(jq -r '.limits | length' "$CONFIG_FILE")" -gt 0 ] && ! rebuild_all_limits; then
        echo -e "${RED}错误：设置根速率失败，正在回滚配置${NC}" >&2
        rollback_config_and_runtime "$backup_file"
        return 1
    fi

    cleanup_config_backup "$backup_file"
    echo -e "${GREEN}根速率已设置为: $tc_rate${NC}"
}

ensure_limit_within_root_rate() {
    local input_rate="$1"
    local tc_rate root_rate rate_kbps root_rate_kbps

    tc_rate="$(convert_bandwidth_to_tc "$input_rate")"
    root_rate="$(jq -r '.tc.root_rate' "$CONFIG_FILE")"
    rate_kbps="$(parse_tc_rate_to_kbps "$tc_rate")"
    root_rate_kbps="$(parse_tc_rate_to_kbps "$root_rate")"

    if [ "$rate_kbps" -gt "$root_rate_kbps" ]; then
        echo -e "${RED}错误：限速 $input_rate 高于当前根速率 $root_rate${NC}" >&2
        echo "请先使用 --root-rate 或菜单 6 调高根速率。" >&2
        return 1
    fi

    return 0
}

cli_add_limit() {
    local port="$1"
    local rate="$2"

    validate_port_or_range "$port" || exit 1

    if ! validate_bandwidth "$rate"; then
        echo -e "${RED}错误：带宽格式无效: $rate${NC}" >&2
        echo "格式示例: 500Kbps, 100Mbps, 1Gbps" >&2
        exit 1
    fi

    check_port_overlap "$port" || exit 1
    ensure_limit_within_root_rate "$rate" || exit 1

    local backup_file
    backup_file="$(backup_config)" || exit 1

    if ! save_limit_to_config "$port" "$rate" || ! rebuild_all_limits; then
        echo -e "${RED}错误：添加限速规则失败，正在回滚配置${NC}" >&2
        rollback_config_and_runtime "$backup_file"
        exit 1
    fi

    cleanup_config_backup "$backup_file"

    echo -e "${GREEN}端口 $port IPv4 出口限速设置成功: $rate${NC}"
}

cli_remove_limit() {
    local port="$1"

    validate_port_or_range "$port" || exit 1

    if ! limit_exists "$port"; then
        echo -e "${YELLOW}端口 $port 没有限速规则${NC}" >&2
        exit 0
    fi

    local rate
    rate="$(get_limit_value "$port" "rate")"

    local backup_file
    backup_file="$(backup_config)" || exit 1

    if ! update_config --arg port "$port" 'del(.limits[$port])' || ! rebuild_all_limits; then
        echo -e "${RED}错误：删除限速规则失败，正在回滚配置${NC}" >&2
        rollback_config_and_runtime "$backup_file"
        exit 1
    fi

    cleanup_config_backup "$backup_file"

    echo -e "${GREEN}端口 $port 限速规则已删除（原限制: $rate）${NC}"
}

add_port_limit_interactive() {
    echo -e "${BLUE}=== 添加端口限速 ===${NC}"
    echo
    show_current_ports
    echo

    local port_input
    read -r -p "请输入要限速的端口（单个端口如80，端口段如100-200）: " port_input
    validate_port_or_range "$port_input" || { sleep 2; return; }
    check_port_overlap "$port_input" || { sleep 2; return; }

    local existed
    if limit_exists "$port_input"; then
        local existing_rate overwrite
        existing_rate="$(get_limit_value "$port_input" "rate")"
        echo -e "${YELLOW}端口 $port_input 已存在限速规则: $existing_rate${NC}"
        read -r -p "是否覆盖? [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            return
        fi
    fi

    local limit_input
    while true; do
        read -r -p "请输入带宽限制（如 500Kbps, 100Mbps, 1Gbps）: " limit_input
        if validate_bandwidth "$limit_input"; then
            break
        fi
        echo -e "${RED}格式错误：请使用如 500Kbps, 100Mbps, 1Gbps，且数值必须大于 0${NC}"
    done
    ensure_limit_within_root_rate "$limit_input" || { sleep 2; return; }

    local backup_file
    backup_file="$(backup_config)" || { sleep 2; return; }

    if ! save_limit_to_config "$port_input" "$limit_input" || ! rebuild_all_limits; then
        echo -e "${RED}添加限速规则失败，正在回滚配置${NC}" >&2
        rollback_config_and_runtime "$backup_file"
        sleep 2
        return
    fi

    cleanup_config_backup "$backup_file"
    echo -e "${GREEN}端口 $port_input IPv4 出口限速设置成功: $limit_input${NC}"
    sleep 2
}

remove_port_limit_interactive() {
    echo -e "${BLUE}=== 删除端口限速 ===${NC}"
    echo

    local ports
    mapfile -t ports < <(get_limited_ports)
    if [ ${#ports[@]} -eq 0 ]; then
        echo "当前没有限速规则"
        sleep 2
        return
    fi

    echo "当前限速端口:"
    local i
    for i in "${!ports[@]}"; do
        local port rate port_type
        port="${ports[$i]}"
        rate="$(get_limit_value "$port" "rate")"
        port_type="单端口"
        if is_port_range "$port"; then
            port_type="端口段"
        fi
        echo "  $((i + 1)). 端口 $port ($port_type) → $rate"
    done
    echo

    local choice_input
    read -r -p "请选择要删除的端口（多端口使用逗号分隔） [1-${#ports[@]}]: " choice_input

    IFS=',' read -r -a choices <<< "$choice_input"
    local ports_to_delete=()
    local choice
    for choice in "${choices[@]}"; do
        choice="$(echo "$choice" | tr -d ' ')"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#ports[@]} ]; then
            ports_to_delete+=("${ports[$((choice - 1))]}")
        else
            echo -e "${RED}无效选择: $choice${NC}"
        fi
    done

    if [ ${#ports_to_delete[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可删除${NC}"
        sleep 2
        return
    fi

    echo
    echo "将删除以下端口的限速规则:"
    for port in "${ports_to_delete[@]}"; do
        local rate
        rate="$(get_limit_value "$port" "rate")"
        echo "  端口 $port ($rate)"
    done
    echo

    local confirm
    read -r -p "确认删除? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local backup_file
        backup_file="$(backup_config)" || { sleep 2; return; }

        for port in "${ports_to_delete[@]}"; do
            if ! update_config --arg port "$port" 'del(.limits[$port])'; then
                echo -e "${RED}删除限速规则失败，正在回滚配置${NC}" >&2
                rollback_config_and_runtime "$backup_file"
                sleep 2
                return
            fi
            echo -e "${GREEN}端口 $port 限速规则已删除${NC}"
        done

        if ! rebuild_all_limits; then
            echo -e "${RED}删除后重建运行时规则失败，正在回滚配置${NC}" >&2
            rollback_config_and_runtime "$backup_file"
            sleep 2
            return
        fi

        cleanup_config_backup "$backup_file"
        echo -e "${GREEN}删除完成${NC}"
    else
        echo "取消删除"
    fi
    sleep 2
}

set_interface_interactive() {
    echo -e "${BLUE}=== 设置限速网卡 ===${NC}"
    echo
    echo "当前可用网卡:"
    get_network_interfaces | sed 's/^/  - /'
    echo
    local iface
    read -r -p "请输入网卡名: " iface
    if [ -z "$iface" ]; then
        echo -e "${RED}网卡名不能为空${NC}"
        sleep 2
        return
    fi
    set_interface "$iface" || { sleep 2; return; }
    sleep 2
}

set_root_rate_interactive() {
    echo -e "${BLUE}=== 设置根速率 ===${NC}"
    echo
    echo "当前根速率: $(jq -r '.tc.root_rate' "$CONFIG_FILE")"
    echo

    local rate
    read -r -p "请输入根速率（如 1000Mbps, 10Gbps）: " rate
    if [ -z "$rate" ]; then
        echo -e "${RED}根速率不能为空${NC}"
        sleep 2
        return
    fi

    set_root_rate "$rate" || { sleep 2; return; }
    sleep 2
}

install_systemd_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}错误：系统不支持 systemd${NC}" >&2
        return 1
    fi

    local service_file="/etc/systemd/system/port-bandwidth-limit.service"
    echo -e "${YELLOW}正在创建 Systemd 服务文件: $service_file${NC}"

    cat > "$service_file" <<EOF
[Unit]
Description=Port Bandwidth Limit Restore Service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${YELLOW}正在启用并启动 Systemd 服务...${NC}"
    systemctl daemon-reload
    systemctl enable port-bandwidth-limit.service

    # 临时释放文件锁，防止 systemctl start 触发的服务进程（会执行 --restore）因竞争锁而死锁
    exec 9>&-

    systemctl start port-bandwidth-limit.service

    # 重新获取文件锁，恢复交互式菜单的独占锁状态
    acquire_lock

    echo -e "${GREEN}Systemd 服务已成功安装并启用。重启后限速规则将自动恢复。${NC}"
}

uninstall_systemd_service() {
    local service_file="/etc/systemd/system/port-bandwidth-limit.service"
    if [ -f "$service_file" ]; then
        echo -e "${YELLOW}正在停止并禁用 Systemd 服务...${NC}"
        systemctl stop port-bandwidth-limit.service 2>/dev/null || true
        systemctl disable port-bandwidth-limit.service 2>/dev/null || true
        rm -f "$service_file"
        systemctl daemon-reload
        echo -e "${GREEN}Systemd 服务已卸载。${NC}"
    else
        echo -e "${YELLOW}未检测到已安装的 Systemd 服务。${NC}"
    fi
}

systemd_service_interactive() {
    clear
    echo -e "${BLUE}=== 开机自启服务管理 (Systemd) ===${NC}"
    echo
    local service_file="/etc/systemd/system/port-bandwidth-limit.service"
    if [ -f "$service_file" ]; then
        echo -e "当前状态: ${GREEN}已安装${NC}"
        if systemctl is-active --quiet port-bandwidth-limit.service 2>/dev/null; then
            echo -e "运行状态: ${GREEN}活动 (active)${NC}"
        else
            echo -e "运行状态: ${RED}未活动 (inactive)${NC}"
        fi
        echo
        echo -e "${BLUE}1.${NC} 重新安装/更新服务"
        echo -e "${BLUE}2.${NC} 卸载服务"
        echo -e "${BLUE}0.${NC} 返回"
        echo
        local choice
        read -r -p "请选择操作 [0-2]: " choice
        case "$choice" in
            1) install_systemd_service ;;
            2) uninstall_systemd_service ;;
            *) return ;;
        esac
    else
        echo -e "当前状态: ${RED}未安装${NC}"
        echo
        echo -e "${BLUE}1.${NC} 安装开机自启服务"
        echo -e "${BLUE}0.${NC} 返回"
        echo
        local choice
        read -r -p "请选择操作 [0-1]: " choice
        case "$choice" in
            1) install_systemd_service ;;
            *) return ;;
        esac
    fi
}

# ==================== 菜单 ====================

show_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== $SCRIPT_NAME v$SCRIPT_VERSION ===${NC}"
        echo "模式: IPv4 出口方向 egress 限速"
        echo

        local ports interface root_rate config_valid
        mapfile -t ports < <(get_limited_ports)
        interface="$(get_default_interface)"
        root_rate="$(jq -r '.tc.root_rate' "$CONFIG_FILE")"
        echo -e "网卡: ${GREEN}$interface${NC} | 根速率: ${GREEN}$root_rate${NC} | 限速规则: ${GREEN}${#ports[@]}条${NC}"
        echo "────────────────────────────────────────────────────────"

        config_valid=true
        if ! validate_runtime_config >/dev/null 2>&1; then
            config_valid=false
            echo -e "${RED}  配置无效，请选择 3 查看详情或修复 $CONFIG_FILE${NC}"
        elif [ ${#ports[@]} -gt 0 ]; then
            local port
            for port in "${ports[@]}"; do
                local rate class_minor mark_id class_id status_icon port_type
                rate="$(get_limit_value "$port" "rate")"
                class_minor="$(get_limit_value "$port" "class_minor")"
                mark_id="$(get_limit_value "$port" "mark_id")"
                class_id="$(generate_tc_class_id "$class_minor")"
                case "$(runtime_rule_status "$interface" "$port" "$class_id" "$mark_id")" in
                    running) status_icon="✓" ;;
                    partial) status_icon="!" ;;
                    *) status_icon="✗" ;;
                esac
                port_type=""
                if is_port_range "$port"; then
                    port_type="[段]"
                fi
                echo -e "  [$status_icon] 端口 ${GREEN}$port${NC}${port_type} → ${YELLOW}$rate${NC}"
            done
        elif [ "$config_valid" = "true" ]; then
            echo "  暂无规则"
        fi

        echo "────────────────────────────────────────────────────────"
        echo
        echo -e "${BLUE}1.${NC} 添加端口限速       ${BLUE}2.${NC} 删除端口限速"
        echo -e "${BLUE}3.${NC} 查看限速详情       ${BLUE}4.${NC} 恢复所有限速规则"
        echo -e "${BLUE}5.${NC} 设置限速网卡       ${BLUE}6.${NC} 设置根速率"
        echo -e "${BLUE}7.${NC} 配置开机自启       ${BLUE}0.${NC} 退出"
        echo

        local choice
        read -r -p "请选择操作 [0-7]: " choice
        case "$choice" in
            1) add_port_limit_interactive ;;
            2) remove_port_limit_interactive ;;
            3)
                clear
                echo -e "${BLUE}=== 限速规则详情 ===${NC}"
                echo
                list_limits || true
                read -r -p "按回车键返回..."
                ;;
            4)
                if rebuild_all_limits; then
                    echo -e "${GREEN}规则恢复完成${NC}"
                else
                    echo -e "${RED}规则恢复失败，请查看上方错误信息${NC}"
                fi
                sleep 2
                ;;
            5) set_interface_interactive ;;
            6) set_root_rate_interactive ;;
            7)
                systemd_service_interactive
                sleep 2
                ;;
            0) exit 0 ;;
            *)
                echo -e "${RED}无效选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# ==================== 主入口 ====================

print_usage() {
    cat <<EOF_USAGE
用法: $0 [选项]

选项:
  --add <端口> <速率>       添加或覆盖限速规则，例如: --add 80 100Mbps
  --remove <端口>           删除限速规则，例如: --remove 80
  --list                    列出所有限速规则
  --restore                 按配置重建所有运行时规则，适合开机自启
  --interface <网卡>        设置限速网卡，例如: --interface eth0
  --root-rate <速率>        设置 HTB 根速率，例如: --root-rate 1Gbps
  --install-service         安装 Systemd 开机自启服务
  --uninstall-service       卸载 Systemd 开机自启服务
  --version, -v             显示版本信息
  --help, -h                显示此帮助

速率格式:
  数字 + Kbps/Mbps/Gbps，数值必须大于 0

示例:
  $0 --add 80 100Mbps
  $0 --add 100-200 500Kbps
  $0 --remove 80
  $0 --interface eth0
  $0 --root-rate 1Gbps
  $0 --list

重要限制:
  1. 仅支持 IPv4。
  2. 仅限制出口方向 egress。
  3. 会接管目标网卡 root qdisc；检测到未由本脚本管理的自定义 root qdisc 时会拒绝覆盖。
  4. 不允许端口规则重叠，例如已有限速 100-200 时，不能再添加 150。
  5. 缺少依赖时默认不自动安装；如需自动安装，请使用 PBL_AUTO_INSTALL_DEPS=true。

开机自启示例:
  @reboot $SCRIPT_PATH --restore

无参数运行时只进入交互式菜单，不会自动重建运行时规则；需要恢复时请选择菜单 4 或使用 --restore。
EOF_USAGE
}

main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            --help|-h)
                print_usage
                exit 0
                ;;
            --version|-v)
                echo -e "${BLUE}$SCRIPT_NAME v$SCRIPT_VERSION${NC}"
                exit 0
                ;;
            --add|--remove|--restore|--list|--interface|--root-rate|--install-service|--uninstall-service)
                ;;
            *)
                echo -e "${RED}未知选项: $1${NC}" >&2
                echo "使用 --help 查看帮助" >&2
                exit 1
                ;;
        esac
    fi

    check_root
    check_dependencies "${PBL_SILENT_DEPS:-false}"
    acquire_lock
    init_config
    ensure_rule_ids

    if [ $# -gt 0 ]; then
        case "$1" in
            --add)
                if [ $# -lt 3 ]; then
                    echo -e "${RED}错误：--add 需要端口和速率参数${NC}" >&2
                    echo "用法: $0 --add <端口> <速率>" >&2
                    exit 1
                fi
                cli_add_limit "$2" "$3"
                exit 0
                ;;
            --remove)
                if [ $# -lt 2 ]; then
                    echo -e "${RED}错误：--remove 需要端口参数${NC}" >&2
                    echo "用法: $0 --remove <端口>" >&2
                    exit 1
                fi
                cli_remove_limit "$2"
                exit 0
                ;;
            --restore)
                if ! rebuild_all_limits; then
                    echo -e "${RED}恢复失败：运行时规则可能已被清理，请检查上方错误和 tc/nft 状态${NC}" >&2
                    exit 1
                fi
                echo -e "${GREEN}所有限速规则已恢复${NC}"
                exit 0
                ;;
            --list)
                echo -e "${BLUE}=== $SCRIPT_NAME v$SCRIPT_VERSION ===${NC}"
                echo
                list_limits
                exit 0
                ;;
            --interface)
                if [ $# -lt 2 ]; then
                    echo -e "${RED}错误：--interface 需要网卡名${NC}" >&2
                    exit 1
                fi
                set_interface "$2" || exit 1
                exit 0
                ;;
            --root-rate)
                if [ $# -lt 2 ]; then
                    echo -e "${RED}错误：--root-rate 需要速率参数${NC}" >&2
                    exit 1
                fi
                set_root_rate "$2" || exit 1
                exit 0
                ;;
            --install-service)
                install_systemd_service || exit 1
                exit 0
                ;;
            --uninstall-service)
                uninstall_systemd_service || exit 1
                exit 0
                ;;
            *)
                echo -e "${RED}未知选项: $1${NC}" >&2
                echo "使用 --help 查看帮助" >&2
                exit 1
                ;;
        esac
    fi

    show_menu
}

main "$@"
