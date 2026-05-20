#!/bin/bash
# ============================================================
#  nft.sh
#  管理 /etc/nftables.conf 中自定义 nftables 表的端口转发规则
#  支持：列表显示、按序号添加/删除
#  用法：sudo bash nft.sh
# ============================================================

set -euo pipefail

NFT_CONF="/etc/nftables.conf"
# 自定义 nftables 表名，避免与 Docker 默认的 table ip nat 冲突
TABLE_NAME="custom_nat"

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
# 如果配置文件不存在，或不包含自定义的 table ip ${TABLE_NAME}，则初始化基础配置
if [[ ! -f "$NFT_CONF" ]] || ! grep -q "table ip ${TABLE_NAME}" "$NFT_CONF"; then
    warn "${NFT_CONF} 不存在或未配置 table ip ${TABLE_NAME}，正在初始化基础配置..."
    cat > "$NFT_CONF" << EOF
#!/usr/sbin/nft -f

table inet filter {
        chain input {
                type filter hook input priority 0;
            # 放行本地回环、已建立连接等常规过滤可在下面扩充
        }
        chain forward {
                type filter hook forward priority 0;
        }
        chain output {
                type filter hook output priority 0;
        }
}

table ip ${TABLE_NAME} {
        chain prerouting {
                type nat hook prerouting priority dstnat; policy accept;
        }

        chain postrouting {
                type nat hook postrouting priority srcnat; policy accept;
        }
}
EOF
    success "已初始化 ${NFT_CONF} 基础配置"
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

# 将域名/IP 解析为 IP，成功则将结果写入 RESOLVED_IP 并返回 0
resolve_host() {
    local host="$1"
    RESOLVED_IP=""
    # 若本身已是合法 IP，直接返回
    if is_valid_ip "$host"; then
        RESOLVED_IP="$host"
        return 0
    fi
    # 尝试 getent（glibc 标准工具，不依赖 dig）
    local res
    res=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -n "$res" ]]; then
        RESOLVED_IP="$res"
        return 0
    fi
    # 回退到 dig（需安装 dnsutils）
    if command -v dig &>/dev/null; then
        res=$(dig +short +timeout=3 +tries=1 "$host" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        if [[ -n "$res" ]]; then
            RESOLVED_IP="$res"
            return 0
        fi
    fi
    return 1
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
#  保留自定义 table 之前的所有内容，重建自定义 table
# ────────────────────────────────
write_conf() {
    local tmp
    tmp="$(mktemp)"

    # 保留自定义 table ip ${TABLE_NAME} 之前的所有内容
    while IFS= read -r line; do
        [[ "$line" =~ ^table[[:space:]]ip[[:space:]]${TABLE_NAME} ]] && break
        echo "$line"
    done < "$NFT_CONF" > "$tmp"

    # 写入新的自定义 NAT 表
    {
        # 先声明再删除，以保证幂等清理内核中旧表及旧规则，随后重建
        echo "table ip ${TABLE_NAME}"
        echo "delete table ip ${TABLE_NAME}"
        echo ""
        echo "table ip ${TABLE_NAME} {"
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
        # masquerade：按唯一目标 IP 去重
        declare -A seen
        for rule in "${RULES[@]}"; do
            read -r lport dip dport <<< "$rule"
            if [[ -z "${seen[$dip]+x}" ]]; then
                echo "                ip daddr ${dip} masquerade"
                seen[$dip]=1
            fi
        done
        echo "        }"
        echo "}"
    } >> "$tmp"

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
    echo -e "  ${BOLD}[1]${RESET} 添加规则"
    echo -e "  ${BOLD}[2]${RESET} 删除规则"
    echo -e "  ${BOLD}[3]${RESET} 保存并应用"
    echo -e "  ${BOLD}[0]${RESET} 直接退出"
    echo ""
    prompt "请选择操作 [1/2/3/0]："
    read -r ACTION
    echo ""

    case "$ACTION" in
    # ── 添加 ──────────────────────────────────────────
    1)
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
                prompt "目标地址（IP 或域名）："
                read -r DEST_HOST
                [[ -z "$DEST_HOST" ]] && { warn "目标地址不能为空"; continue; }
                if resolve_host "$DEST_HOST"; then
                    DEST_IP="$RESOLVED_IP"
                    # 若输入的是域名，额外显示解析结果
                    [[ "$DEST_HOST" != "$DEST_IP" ]] && info "域名解析：${DEST_HOST} → ${DEST_IP}"
                    break
                else
                    warn "无法解析地址：${DEST_HOST}（请检查域名或网络）"
                fi
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
    2)
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
    3)
        info "写入 ${NFT_CONF} ..."
        write_conf
        success "配置文件已更新"
        
        # 清理一次内核中的旧表防止语法加载错误，再执行重载
        nft delete table ip "${TABLE_NAME}" 2>/dev/null || true
        sleep 0.5
        
        if nft -f "$NFT_CONF"; then
            success "nftables 规则已成功应用到内核"
        else
            error "应用 nftables 规则失败，请检查配置文件语法"
        fi
        
        systemctl is-enabled nftables &>/dev/null || systemctl enable nftables
        echo ""
        echo -e "${GREEN}══════════════════════════════════════════${RESET}"
        echo -e "${GREEN}  完成 ✔  （共 ${#RULES[@]} 条规则）${RESET}"
        echo -e "${GREEN}══════════════════════════════════════════${RESET}"
        print_rules
        echo -e "  查看规则  : ${YELLOW}nft list table ip ${TABLE_NAME}${RESET}"
        echo -e "  当前配置  : ${YELLOW}cat ${NFT_CONF}${RESET}"
        echo ""
        exit 0
        ;;

    # ── 直接退出 ──────────────────────────────────────
    0)
        info "已退出，未作任何修改。"
        echo ""
        exit 0
        ;;

    *)
        warn "无效输入，请输入 1、2、3 或 0"
        ;;
    esac
done
