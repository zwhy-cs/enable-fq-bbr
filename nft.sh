#!/bin/bash
# ============================================================
#  nft.sh
#  管理 /etc/nftables.conf 中 table ip nat 的端口转发规则
#  支持：列表显示、按序号添加/删除
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
[[ -f "$NFT_CONF" ]] || error "${NFT_CONF} 不存在"

# 若文件中没有 table ip nat，则追加基础结构
if ! grep -q "table ip nat" "$NFT_CONF"; then
    warn "${NFT_CONF} 中未找到 table ip nat，自动追加基础配置..."
    cat >> "$NFT_CONF" << 'EOF'
table ip nat {
        chain prerouting {
                type nat hook prerouting priority dstnat; policy accept;
        }

        chain postrouting {
                type nat hook postrouting priority srcnat; policy accept;
        }
}
EOF
    success "已追加 table ip nat 基础配置"
fi

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
#  从配置文件解析已有规则 → RULES[]
#  格式: "listen_port dest_ip dest_port"
# ────────────────────────────────
load_rules() {
    RULES=()
    while IFS= read -r line; do
        if [[ "$line" =~ tcp[[:space:]]+dport[[:space:]]+([0-9]+)[[:space:]]+dnat[[:space:]]+to[[:space:]]+([0-9.]+):([0-9]+) ]]; then
            RULES+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}")
        fi
    done < <(grep -E "tcp dport [0-9]+ dnat to" "$NFT_CONF" || true)
}

# ────────────────────────────────
#  打印规则列表（带序号）
# ────────────────────────────────
print_rules() {
    echo ""
    if (( ${#RULES[@]} == 0 )); then
        echo -e "  ${YELLOW}（暂无转发规则）${RESET}"
        echo ""
        return
    fi
    printf "  ${BOLD}%-4s  %-12s  %-26s  %s${RESET}\n" "序号" "监听端口" "目标地址" "协议"
    printf "  %s\n" "────────────────────────────────────────────────"
    local i=1
    for rule in "${RULES[@]}"; do
        read -r lport dip dport <<< "$rule"
        printf "  ${CYAN}%-4s${RESET}  %-12s  %-26s  %s\n" \
            "[${i}]" "*:${lport}" "${dip}:${dport}" "TCP + UDP"
        (( i++ ))
    done
    echo ""
}

# ────────────────────────────────
#  将 RULES[] 写回 /etc/nftables.conf
#  保留 table inet filter 及其前内容，重建 table ip nat
# ────────────────────────────────
write_conf() {
    local tmp
    tmp="$(mktemp)"

    # 保留 table ip nat 之前的所有内容
    while IFS= read -r line; do
        [[ "$line" =~ ^table[[:space:]]ip[[:space:]]nat ]] && break
        echo "$line"
    done < "$NFT_CONF" > "$tmp"

    # 写入新的 table ip nat 块
    {
        echo "table ip nat {"
        echo "        chain prerouting {"
        echo "                type nat hook prerouting priority dstnat; policy accept;"
        for rule in "${RULES[@]}"; do
            read -r lport dip dport <<< "$rule"
            echo "                tcp dport ${lport} dnat to ${dip}:${dport}"
            echo "                udp dport ${lport} dnat to ${dip}:${dport}"
        done
        echo "        }"
        echo ""
        echo "        chain postrouting {"
        echo "                type nat hook postrouting priority srcnat; policy accept;"
        # snat：按唯一目标 IP 去重，自动探测本机出口 IP
        declare -A seen
        for rule in "${RULES[@]}"; do
            read -r lport dip dport <<< "$rule"
            if [[ -z "${seen[$dip]+x}" ]]; then
                # 自动获取到达目标 IP 时使用的本机源 IP
                local_ip=$(ip route get "${dip}" 2>/dev/null | grep -oP 'src \K\S+' | head -1 || true)
                if [[ -n "$local_ip" ]]; then
                    echo "                ip daddr ${dip} snat to ${local_ip}"
                else
                    # 获取失败则回退到 masquerade
                    echo "                ip daddr ${dip} masquerade"
                fi
                seen[$dip]=1
            fi
        done
        echo "        }"
        echo "}"
    } >> "$tmp"

    cp "$NFT_CONF" "${NFT_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$tmp" "$NFT_CONF"
}

# ────────────────────────────────
#  主流程
# ────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║    nftables 端口转发 交互式配置工具      ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"

load_rules

while true; do
    # ── 显示当前规则 ──
    info "当前转发规则："
    print_rules

    # ── 操作菜单 ──
    echo -e "  ${BOLD}[A]${RESET} 添加规则   ${BOLD}[D]${RESET} 删除规则   ${BOLD}[Q]${RESET} 保存并退出"
    echo ""
    prompt "请选择操作 [A/D/Q]："
    read -r ACTION
    ACTION="${ACTION^^}"   # 转大写
    echo ""

    case "$ACTION" in
    # ── 添加 ──────────────────────────────────────────
    A)
        while true; do
            echo -e "${BOLD}── 添加规则 ──${RESET}"

            while true; do
                prompt "本机监听端口（回车返回菜单）："
                read -r LISTEN_PORT
                [[ -z "$LISTEN_PORT" ]] && break 2
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

            RULES+=("${LISTEN_PORT} ${DEST_IP} ${DEST_PORT}")
            success "已添加：*:${LISTEN_PORT} → ${DEST_IP}:${DEST_PORT}（TCP + UDP）"
            echo ""
        done
        ;;

    # ── 删除 ──────────────────────────────────────────
    D)
        if (( ${#RULES[@]} == 0 )); then
            warn "当前没有可删除的规则"
            continue
        fi
        prompt "输入要删除的规则序号（多个用空格分隔，回车取消）："
        read -r -a NUMS
        [[ ${#NUMS[@]} -eq 0 ]] && continue

        # 验证所有序号合法
        local_err=0
        for n in "${NUMS[@]}"; do
            if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#RULES[@]} )); then
                warn "无效序号：${n}（范围 1-${#RULES[@]}）"
                local_err=1
            fi
        done
        (( local_err )) && continue

        # 去重、排序后从大到小删除（避免索引偏移）
        mapfile -t SORTED < <(printf '%s\n' "${NUMS[@]}" | sort -rnu)
        for n in "${SORTED[@]}"; do
            removed="${RULES[$(( n - 1 ))]}"
            read -r lport dip dport <<< "$removed"
            unset 'RULES['"$(( n - 1 ))"']'
            warn "已删除规则 [${n}]：*:${lport} → ${dip}:${dport}"
        done
        # 重新索引数组
        RULES=("${RULES[@]}")
        echo ""
        ;;

    # ── 保存退出 ──────────────────────────────────────
    Q)
        info "写入 ${NFT_CONF} ..."
        write_conf
        success "配置文件已更新"

        systemctl enable nftables &>/dev/null
        success "nftables.service 已设置开机自启"
        nft flush ruleset
        nft -f "$NFT_CONF"
        echo ""
        echo -e "${GREEN}══════════════════════════════════════════${RESET}"
        echo -e "${GREEN}  完成 ✔  （共 ${#RULES[@]} 条规则）${RESET}"
        echo -e "${GREEN}══════════════════════════════════════════${RESET}"
        print_rules
        echo -e "  查看规则  : ${YELLOW}nft list table ip nat${RESET}"
        echo -e "  当前配置  : ${YELLOW}cat ${NFT_CONF}${RESET}"
        echo ""
        exit 0
        ;;

    *)
        warn "无效输入，请输入 A、D 或 Q"
        ;;
    esac
done
