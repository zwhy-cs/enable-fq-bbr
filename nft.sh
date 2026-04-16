#!/bin/bash
# ============================================================
#  nft.sh
#  向 /etc/nftables.conf 的 table ip nat 追加端口转发规则
#  前提：配置文件已含 table ip nat { chain prerouting/postrouting }
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
[[ -f "$NFT_CONF" ]] || error "${NFT_CONF} 不存在，请先创建基础配置"
grep -q "chain prerouting"  "$NFT_CONF" || error "${NFT_CONF} 中未找到 chain prerouting"
grep -q "chain postrouting" "$NFT_CONF" || error "${NFT_CONF} 中未找到 chain postrouting"

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
#  Banner
# ────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║    nftables 端口转发 交互式配置工具      ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ────────────────────────────────
#  显示已有规则（只读，不解析）
# ────────────────────────────────
existing=$(grep -E "tcp dport [0-9]+ dnat to" "$NFT_CONF" || true)
if [[ -n "$existing" ]]; then
    info "当前已有转发规则："
    printf "  ${BOLD}%-12s  %-24s${RESET}\n" "监听端口" "目标地址"
    printf "  %s\n" "────────────────────────────────────"
    while read -r line; do
        if [[ "$line" =~ tcp[[:space:]]+dport[[:space:]]+([0-9]+)[[:space:]]+dnat[[:space:]]+to[[:space:]]+([^[:space:]]+) ]]; then
            printf "  %-12s  %-24s\n" "*:${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        fi
    done <<< "$existing"
    echo ""
fi

# ────────────────────────────────
#  收集新规则
# ────────────────────────────────
NEW_RULES=()

echo -e "追加新转发规则（TCP + UDP），${BOLD}监听端口直接回车${RESET}结束。"
echo ""

index=1
while true; do
    echo -e "${BOLD}── 新规则 #${index} ──${RESET}"

    while true; do
        prompt "本机监听端口（回车结束）："
        read -r LISTEN_PORT
        [[ -z "$LISTEN_PORT" ]] && {
            (( ${#NEW_RULES[@]} > 0 )) && break 2
            warn "至少需要一条新规则！"
            continue
        }
        is_valid_port "$LISTEN_PORT" && break
        warn "端口无效（1-65535）"
    done

    while true; do
        prompt "目标 IP 地址："
        read -r DEST_IP
        is_valid_ip "$DEST_IP" && break
        warn "IP 格式不正确（例如：1.2.3.4）"
    done

    while true; do
        prompt "目标端口 [默认: ${LISTEN_PORT}]："
        read -r DEST_PORT
        DEST_PORT="${DEST_PORT:-$LISTEN_PORT}"
        is_valid_port "$DEST_PORT" && break
        warn "端口无效（1-65535）"
    done

    NEW_RULES+=("${LISTEN_PORT} ${DEST_IP} ${DEST_PORT}")
    success "已添加：*:${LISTEN_PORT} → ${DEST_IP}:${DEST_PORT}（TCP + UDP）"
    echo ""
    (( index++ ))
done

# ────────────────────────────────
#  备份
# ────────────────────────────────
cp "$NFT_CONF" "${NFT_CONF}.bak.$(date +%Y%m%d%H%M%S)"
info "已备份旧配置"

# ────────────────────────────────
#  将新规则插入配置文件
#  原理：逐行读取，在 chain prerouting / chain postrouting
#        的结尾 } 之前插入对应规则行
# ────────────────────────────────
info "写入 ${NFT_CONF} ..."

tmp=$(mktemp)
in_pre=0
in_post=0
declare -A SEEN_IPS

while IFS= read -r line; do
    # 检测链开始
    if [[ "$line" =~ chain[[:space:]]prerouting ]]; then
        in_pre=1; in_post=0
    elif [[ "$line" =~ chain[[:space:]]postrouting ]]; then
        in_pre=0; in_post=1
    fi

    # 在 prerouting 的 } 前插入 dnat 规则
    if (( in_pre )) && [[ "$line" == "        }" ]]; then
        for rule in "${NEW_RULES[@]}"; do
            read -r lport dip dport <<< "$rule"
            echo "                tcp dport ${lport} dnat to ${dip}:${dport}"
            echo "                udp dport ${lport} dnat to ${dip}:${dport}"
        done
        in_pre=0
    fi

    # 在 postrouting 的 } 前插入 masquerade 规则（同一 IP 只加一条）
    if (( in_post )) && [[ "$line" == "        }" ]]; then
        for rule in "${NEW_RULES[@]}"; do
            read -r lport dip dport <<< "$rule"
            if [[ -z "${SEEN_IPS[$dip]+x}" ]]; then
                # 只在该 IP 的 masquerade 规则尚不存在时才添加
                if ! grep -q "ip daddr ${dip} masquerade" "$NFT_CONF"; then
                    echo "                ip daddr ${dip} masquerade"
                fi
                SEEN_IPS[$dip]=1
            fi
        done
        in_post=0
    fi

    echo "$line"
done < "$NFT_CONF" > "$tmp"

mv "$tmp" "$NFT_CONF"
success "配置文件已更新"

# ────────────────────────────────
#  加载配置
# ────────────────────────────────
info "加载配置：nft -f ${NFT_CONF}"
nft -f "$NFT_CONF"
success "配置已生效"

systemctl enable nftables &>/dev/null
success "nftables.service 已设置开机自启"

# ────────────────────────────────
#  摘要
# ────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════${RESET}"
echo -e "${GREEN}  完成 ✔  （本次新增 ${#NEW_RULES[@]} 条规则）${RESET}"
echo -e "${GREEN}══════════════════════════════════════════${RESET}"
printf "\n  ${BOLD}%-12s  %-24s  %s${RESET}\n" "监听端口" "目标地址" "协议"
printf "  %s\n" "────────────────────────────────────────"
for rule in "${NEW_RULES[@]}"; do
    read -r lport dip dport <<< "$rule"
    printf "  %-12s  %-24s  %s\n" "*:${lport}" "${dip}:${dport}" "TCP + UDP"
done
echo ""
echo -e "  查看规则  : ${YELLOW}nft list table ip nat${RESET}"
echo -e "  当前配置  : ${YELLOW}cat ${NFT_CONF}${RESET}"
echo ""
