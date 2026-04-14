#!/bin/bash
# ============================================================
#  setup_nftables_forward.sh
#  交互式配置 nftables 端口转发（仅操作 table ip nat）
#  保留原有 table inet filter，适用于 Debian 11
#  用法：sudo bash setup_nftables_forward.sh
# ============================================================

set -euo pipefail

NFT_CONF="/etc/nftables.conf"
TABLE="ip nat"

# ────────────────────────────────
#  颜色输出
# ────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
prompt()  { printf "${BOLD}${YELLOW}>>> $*${RESET} "; }

# ────────────────────────────────
#  前置检查
# ────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || error "请以 root 身份运行此脚本（sudo bash $0）"
}

check_deps() {
    for cmd in nft sysctl ip awk; do
        command -v "$cmd" &>/dev/null || error "缺少命令: $cmd"
    done
}

# ────────────────────────────────
#  输入验证
# ────────────────────────────────
is_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octs <<< "$ip"
    for o in "${octs[@]}"; do (( o >= 0 && o <= 255 )) || return 1; done
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

# ────────────────────────────────
#  交互式收集规则
# ────────────────────────────────
interactive_input() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║    nftables 端口转发 交互式配置工具      ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
    echo ""

    FORWARD_RULES=()   # 格式：listen_port,dest_ip,dest_port
    local index=1

    echo -e "每条规则：本机端口 → 目标 IP:端口（TCP）"
    echo -e "输入完成后，${BOLD}监听端口直接回车${RESET}结束添加。"
    echo ""

    while true; do
        echo -e "${BOLD}── 规则 #${index} ──${RESET}"

        # 监听端口
        local listen_port
        while true; do
            prompt "本机监听端口（回车结束）："
            read -r listen_port
            [[ -z "$listen_port" ]] && {
                (( ${#FORWARD_RULES[@]} > 0 )) && break 2
                warn "至少需要一条规则！"
                continue
            }
            is_valid_port "$listen_port" && break
            warn "端口无效（1-65535）"
        done

        # 目标 IP
        local dest_ip
        while true; do
            prompt "目标 IP 地址："
            read -r dest_ip
            is_valid_ip "$dest_ip" && break
            warn "IP 格式不正确（例如：192.168.1.100）"
        done

        # 目标端口
        local dest_port
        while true; do
            prompt "目标端口 [默认: ${listen_port}]："
            read -r dest_port
            dest_port="${dest_port:-$listen_port}"
            is_valid_port "$dest_port" && break
            warn "端口无效（1-65535）"
        done

        FORWARD_RULES+=("${listen_port},${dest_ip},${dest_port}")
        success "已添加：*:${listen_port} → ${dest_ip}:${dest_port} (TCP)"
        echo ""
        (( index++ ))
    done
}

# ────────────────────────────────
#  开启内核 IP 转发
# ────────────────────────────────
enable_ip_forward() {
    info "开启 IPv4 转发..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    local conf="/etc/sysctl.d/99-ip-forward.conf"
    if grep -q "net.ipv4.ip_forward" "$conf" 2>/dev/null; then
        sed -i 's/^.*net\.ipv4\.ip_forward.*$/net.ipv4.ip_forward = 1/' "$conf"
    else
        echo "net.ipv4.ip_forward = 1" >> "$conf"
    fi
    sysctl -p "$conf" > /dev/null
    success "IPv4 转发已启用（永久生效）"
}

# ────────────────────────────────
#  构建 table ip nat 文本块
# ────────────────────────────────
build_nat_block() {
    local dnat_lines=""
    local masq_ips=()

    for rule in "${FORWARD_RULES[@]}"; do
        IFS=',' read -r lport dip dport <<< "$rule"
        dnat_lines+="                tcp dport ${lport} dnat to ${dip}:${dport}\n"

        # 收集唯一目标 IP
        local found=0
        for ip in "${masq_ips[@]:-}"; do
            [[ "$ip" == "$dip" ]] && found=1 && break
        done
        (( found == 0 )) && masq_ips+=("$dip")
    done

    local masq_lines=""
    for ip in "${masq_ips[@]}"; do
        masq_lines+="                ip daddr ${ip} masquerade\n"
    done

    printf 'table ip nat {\n'
    printf '        chain prerouting {\n'
    printf '                type nat hook prerouting priority dstnat; policy accept;\n'
    printf '%b' "${dnat_lines}"
    printf '        }\n\n'
    printf '        chain postrouting {\n'
    printf '                type nat hook postrouting priority srcnat; policy accept;\n'
    printf '%b' "${masq_lines}"
    printf '        }\n'
    printf '}\n'
}

# ────────────────────────────────
#  应用运行时规则
# ────────────────────────────────
apply_nft_rules() {
    info "加载 nftables 规则..."

    # 删除旧的 table ip nat（如果存在）
    if nft list tables | grep -q "^ip nat$"; then
        warn "检测到旧 table ip nat，先删除..."
        nft delete table ip nat
    fi

    # 加载新规则
    build_nat_block | nft -f -
    success "规则已加载"
    echo ""
    nft list table ip nat
}

# ────────────────────────────────
#  持久化：只替换/追加 table ip nat，不动其他内容
# ────────────────────────────────
persist_rules() {
    info "持久化到 ${NFT_CONF} ..."

    # 备份
    cp "$NFT_CONF" "${NFT_CONF}.bak.$(date +%Y%m%d%H%M%S)"

    # 用 awk 删除现有 table ip nat { ... } 块（处理嵌套括号）
    local tmp
    tmp="$(mktemp)"
    awk '
        /^table ip nat \{/ { skip=1; depth=0 }
        skip {
            for (i=1; i<=length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                if (c == "}") {
                    depth--
                    if (depth == 0) { skip=0; next }
                }
            }
            next
        }
        { print }
    ' "$NFT_CONF" | sed -e 's/[[:space:]]*$//' | sed -e '/^$/N;/^\n$/d' > "$tmp"

    # 追加新的 table ip nat 块
    {
        cat "$tmp"
        echo ""
        build_nat_block
    } > "$NFT_CONF"

    rm -f "$tmp"

    systemctl enable nftables &>/dev/null
    success "已写入 ${NFT_CONF}，nftables.service 已设置开机自启"
}

# ────────────────────────────────
#  打印摘要
# ────────────────────────────────
print_summary() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${RESET}"
    echo -e "${GREEN}  配置完成 ✔${RESET}"
    echo -e "${GREEN}══════════════════════════════════════════${RESET}"
    printf "\n  ${BOLD}%-14s  %-24s  %s${RESET}\n" "监听端口" "转发目标" "协议"
    printf "  %s\n" "──────────────────────────────────────────"
    for rule in "${FORWARD_RULES[@]}"; do
        IFS=',' read -r lport dip dport <<< "$rule"
        printf "  %-14s  %-24s  %s\n" "*:${lport}" "${dip}:${dport}" "TCP"
    done
    echo ""
    echo -e "  查看规则  : ${YELLOW}nft list table ip nat${RESET}"
    echo -e "  删除规则  : ${YELLOW}nft delete table ip nat${RESET}"
    echo -e "  当前配置  : ${YELLOW}cat ${NFT_CONF}${RESET}"
    echo ""
}

# ────────────────────────────────
#  主流程
# ────────────────────────────────
main() {
    check_root
    check_deps
    interactive_input
    enable_ip_forward
    apply_nft_rules
    persist_rules
    print_summary
}

main "$@"
