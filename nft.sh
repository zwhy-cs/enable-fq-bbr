#!/bin/bash
# ============================================================
#  nft.sh
#  交互式配置 nftables 端口转发，Debian 11
#  用法：sudo bash nft.sh
# ============================================================

set -euo pipefail

NFT_CONF="/etc/nftables.conf"

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
[[ $EUID -eq 0 ]] || error "请以 root 身份运行（sudo bash $0）"
command -v nft &>/dev/null || error "未找到 nft，请先安装：apt install nftables"


# ────────────────────────────────
#  输入验证
# ────────────────────────────────
is_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a o <<< "$ip"
    for x in "${o[@]}"; do (( x >= 0 && x <= 255 )) || return 1; done
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

# ────────────────────────────────
#  主流程
# ────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║    nftables 端口转发 交互式配置工具      ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── 收集转发规则 ──────────────────
RULES=()   # 格式：listen_port dest_ip dest_port

echo -e "每条规则：本机端口 → 目标 IP:端口（TCP + UDP）"
echo -e "${BOLD}监听端口直接回车${RESET}结束添加（至少填一条）。"
echo ""

index=1
while true; do
    echo -e "${BOLD}── 规则 #${index} ──${RESET}"

    # 监听端口
    while true; do
        prompt "本机监听端口（回车结束）："
        read -r LISTEN_PORT
        [[ -z "$LISTEN_PORT" ]] && {
            (( ${#RULES[@]} > 0 )) && break 2
            warn "至少需要一条规则！"
            continue
        }
        is_valid_port "$LISTEN_PORT" && break
        warn "端口无效（1-65535）"
    done

    # 目标 IP
    while true; do
        prompt "目标 IP 地址："
        read -r DEST_IP
        is_valid_ip "$DEST_IP" && break
        warn "IP 格式不正确（例如：1.2.3.4）"
    done

    # 目标端口
    while true; do
        prompt "目标端口 [默认: ${LISTEN_PORT}]："
        read -r DEST_PORT
        DEST_PORT="${DEST_PORT:-$LISTEN_PORT}"
        is_valid_port "$DEST_PORT" && break
        warn "端口无效（1-65535）"
    done

    RULES+=("${LISTEN_PORT} ${DEST_IP} ${DEST_PORT}")
    success "已添加：*:${LISTEN_PORT} → ${DEST_IP}:${DEST_PORT}（TCP + UDP）"
    echo ""
    (( index++ ))
done

# ── 构建 prerouting 规则行 ────────
DNAT_LINES=""
for rule in "${RULES[@]}"; do
    read -r lport dip dport <<< "$rule"
    DNAT_LINES+="                tcp dport ${lport} dnat to ${dip}:${dport}\n"
    DNAT_LINES+="                udp dport ${lport} dnat to ${dip}:${dport}\n"
done

# ── 构建 postrouting 规则行（按唯一目标 IP）──
declare -A SEEN_IPS
MASQ_LINES=""
for rule in "${RULES[@]}"; do
    read -r lport dip dport <<< "$rule"
    if [[ -z "${SEEN_IPS[$dip]+x}" ]]; then
        MASQ_LINES+="                ip daddr ${dip} masquerade\n"
        SEEN_IPS[$dip]=1
    fi
done

# ── 备份旧配置 ────────────────────
if [[ -f "$NFT_CONF" ]]; then
    cp "$NFT_CONF" "${NFT_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份旧配置"
fi

# ── 写入新配置文件 ────────────────
info "写入 ${NFT_CONF} ..."

cat > "$NFT_CONF" << EOF
flush ruleset
table inet filter {
        chain input {
                type filter hook input priority filter; policy accept;
        }

        chain forward {
                type filter hook forward priority filter; policy accept;
        }

        chain output {
                type filter hook output priority filter; policy accept;
        }
}
table ip nat {
        chain prerouting {
                type nat hook prerouting priority dstnat; policy accept;
$(printf '%b' "${DNAT_LINES}")        }

        chain postrouting {
                type nat hook postrouting priority srcnat; policy accept;
$(printf '%b' "${MASQ_LINES}")        }
}
EOF


# ── 加载配置 ──────────────────────
info "加载配置：nft -f ${NFT_CONF}"
nft -f "$NFT_CONF"
success "配置已生效"

# ── 开机自启 ──────────────────────
systemctl enable nftables &>/dev/null
success "nftables.service 已设置开机自启"

# ── 摘要 ──────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════${RESET}"
echo -e "${GREEN}  完成 ✔  （共 ${#RULES[@]} 条转发规则）${RESET}"
echo -e "${GREEN}══════════════════════════════════════════${RESET}"
printf "\n  ${BOLD}%-12s  %-24s  %s${RESET}\n" "监听端口" "目标地址" "协议"
printf "  %s\n" "────────────────────────────────────────"
for rule in "${RULES[@]}"; do
    read -r lport dip dport <<< "$rule"
    printf "  %-12s  %-24s  %s\n" "*:${lport}" "${dip}:${dport}" "TCP + UDP"
done
echo ""
echo -e "  查看规则  : ${YELLOW}nft list table ip nat${RESET}"
echo -e "  当前配置  : ${YELLOW}cat ${NFT_CONF}${RESET}"
echo ""
