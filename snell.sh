#!/bin/bash

set -e

# 配置变量
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/snell"
LOG_DIR="/var/log/snell"
SYSTEMD_TEMPLATE_SERVICE="/etc/systemd/system/snell@.service"


# 检查是否以root权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请以root权限运行此脚本"
    exit 1
fi

# 查找实例
find_instances() {
    if [ ! -d "${CONFIG_DIR}" ]; then
        return
    fi
    find "${CONFIG_DIR}" -maxdepth 1 -type f -name "*.conf" -printf "%f\n" | sed 's/\.conf$//'
}

# 列出实例
list_instances() {
    echo "当前 Snell 实例:"
    mapfile -t instances < <(find_instances)

    if [ ${#instances[@]} -eq 0 ]; then
        echo "未找到任何实例。"
        return 1
    fi

    for i in "${!instances[@]}"; do
        echo " $((i+1)). ${instances[i]}"
    done
    echo ""
    return 0
}


# 显示菜单
show_menu() {
    clear
    echo "========== Snell 多实例管理脚本 =========="
    echo "1. 安装/更新 Snell 程序"
    echo "2. 查看所有 Snell 实例状态"
    echo "3. 安装新 Snell 实例"
    echo "4. 卸载 Snell 实例"
    echo "5. 重启 Snell 实例"
    echo "6. 查看实例配置"
    echo "7. 修改实例配置 (nano)"
    echo "0. 退出脚本"
    echo "======================================"
    echo ""
    read -p "请选择操作 [0-7]: " choice
}

# 检查 snell-server 是否已安装
is_snell_installed() {
    if [ -f "${INSTALL_DIR}/snell-server" ]; then
        return 0
    else
        return 1
    fi
}

# 查看 Snell 状态
check_status() {
    echo "正在检查所有 Snell 实例状态..."
    
    INSTANCES=$(find_instances)
    if [ -z "$INSTANCES" ]; then
        echo "未找到任何 Snell 实例。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    for instance in $INSTANCES; do
        echo "--- 实例: ${instance} ---"
        if systemctl is-active --quiet "snell@${instance}"; then
            echo "状态: 运行中"
            # 从配置文件获取端口
            PORT=$(grep -oP 'listen\s*=\s*0\.0\.0\.0:\K[0-9]+' "${CONFIG_DIR}/${instance}.conf")
            echo "端口: ${PORT}"
            netstat -tlnp | grep ":${PORT}.*snell-server" || ss -tlnp | grep ":${PORT}.*snell-server" || echo "端口未被 snell-server 监听 (可能是权限问题)"
        else
            echo "状态: 未运行"
        fi
        echo ""
    done
    
    read -p "按任意键返回主菜单..." key
}

# 更新 snell-server 程序
update_snell_binary() {
    # 获取用户输入的Snell版本
    read -p "请输入要安装的Snell版本(默认 4.1.1): " SNELL_VERSION
    SNELL_VERSION=${SNELL_VERSION:-"4.1.1"}
    
    SNELL_DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-amd64.zip"
    
    echo "开始下载并安装 Snell v${SNELL_VERSION}..."

    # 确保依赖已安装
    for tool in curl unzip; do
        if ! command -v $tool &>/dev/null; then
            echo "正在安装 ${tool}..."
            if [ -x "$(command -v apt-get)" ]; then
                apt-get update && apt-get install -y $tool
            elif [ -x "$(command -v yum)" ]; then
                yum install -y $tool
            else
                echo "无法自动安装 ${tool}，请手动安装后重试。"
                return
            fi
        fi
    done
    
    # 创建临时目录并下载
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    echo "正在下载 Snell v${SNELL_VERSION}..."
    if ! curl -L -o snell.zip "$SNELL_DOWNLOAD_URL"; then
        echo "下载失败，请检查网络连接和下载链接。"
        cd / && rm -rf "$TMP_DIR"
        return
    fi
    
    echo "正在解压文件..."
    if ! unzip snell.zip; then
        echo "解压失败，请检查下载的文件是否完整。"
        cd / && rm -rf "$TMP_DIR"
        return
    fi
    
    # 移动可执行文件
    if [ -f "snell-server" ]; then
        # 记录并停止正在运行的实例
        INSTANCES=$(find_instances)
        INSTANCES_TO_RESTART=()
        for instance in $INSTANCES; do
             if systemctl is-active --quiet "snell@${instance}"; then
                echo "正在停止实例 ${instance}..."
                systemctl stop "snell@${instance}"
                INSTANCES_TO_RESTART+=("$instance")
             fi
        done

        mv snell-server ${INSTALL_DIR}/snell-server
        chmod +x ${INSTALL_DIR}/snell-server
        echo "snell-server 已更新至 ${INSTALL_DIR}/snell-server"

        # 重启之前正在运行的实例
        if [ ${#INSTANCES_TO_RESTART[@]} -gt 0 ]; then
            echo "正在重启之前运行的实例..."
            for instance in "${INSTANCES_TO_RESTART[@]}"; do
                echo -n "重启实例 ${instance}... "
                systemctl start "snell@${instance}"
                # 等待一秒并检查状态
                sleep 1
                if systemctl is-active --quiet "snell@${instance}"; then
                    echo "[成功]"
                else
                    echo "[失败] - 请检查日志: journalctl -u snell@${instance}"
                fi
            done
        fi
    else
        echo "错误：未找到 snell-server 可执行文件。"
    fi
    
    # 清理
    cd / && rm -rf "$TMP_DIR"
    echo "更新完成。"
}


# 安装 Snell
install_snell() {
    if ! is_snell_installed; then
        echo "未找到 snell-server 程序。请先使用菜单选项 1 更新/安装 snell-server。"
        read -p "按任意键返回主菜单..." key
        return
    fi
    
    read -p "请输入新实例的名称 (例如 snell1): " INSTANCE_NAME
    if [ -z "$INSTANCE_NAME" ]; then
        echo "实例名称不能为空。"
        read -p "按任意键返回主菜单..." key
        return
    fi
    if ! [[ "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        echo "错误: 实例名称只能包含字母、数字、下划线(_)、点(.)和连字符(-)。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    CONFIG_FILE="${CONFIG_DIR}/${INSTANCE_NAME}.conf"
    if [ -f "$CONFIG_FILE" ]; then
        echo "错误：实例 '${INSTANCE_NAME}' 已存在。"
        read -p "按任意键返回主菜单..." key
        return
    fi
    
    echo "开始为实例 '${INSTANCE_NAME}' 进行配置..."
    
    # 获取用户输入的监听端口
    read -p "请输入监听端口 (例如 8388): " PORT
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo "无效的端口号。"
        read -p "按任意键返回主菜单..." key
        return
    fi
    if ss -tlnp | grep -q ":${PORT}\s" || netstat -tlnp | grep -q ":${PORT}\s"; then
        echo "错误: 端口 ${PORT} 已被占用。"
        read -p "按任意键返回主菜单..." key
        return
    fi
    
    # 自动生成预共享密钥(PSK)
    if ! command -v openssl &>/dev/null; then
        echo "错误：系统中未安装 openssl，正在尝试安装..."
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update && apt-get install -y openssl
        elif [ -x "$(command -v yum)" ]; then
            yum install -y openssl
        else
            echo "无法自动安装 openssl，请手动安装后重试。"
            read -p "按任意键返回主菜单..." key
            return
        fi
    fi
    
    PSK=$(openssl rand -hex 16)
    echo "自动生成的预共享密钥(PSK)为: ${PSK}"
    
    # 创建目录
    mkdir -p ${CONFIG_DIR}
    mkdir -p ${LOG_DIR}
    
    # 生成配置文件
    echo "正在创建配置文件 ${CONFIG_FILE}..."
    cat > ${CONFIG_FILE} <<EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${PSK}
ipv6 = false
EOF
    
    # 创建日志文件
    touch "${LOG_DIR}/${INSTANCE_NAME}.log"
    chmod 644 "${LOG_DIR}/${INSTANCE_NAME}.log"
    
    # 创建 systemd 服务模板文件 (如果不存在)
    if [ ! -f "${SYSTEMD_TEMPLATE_SERVICE}" ]; then
        echo "正在创建 systemd 服务模板文件 ${SYSTEMD_TEMPLATE_SERVICE}..."
        cat > ${SYSTEMD_TEMPLATE_SERVICE} <<EOF
[Unit]
Description=Snell Server (%i)
After=network.target

[Service]
ExecStart=${INSTALL_DIR}/snell-server -c ${CONFIG_DIR}/%i.conf
Restart=on-failure
StandardOutput=append:${LOG_DIR}/%i.log
StandardError=append:${LOG_DIR}/%i.log

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
    
    # 启动服务
    echo "启动 Snell 实例 '${INSTANCE_NAME}' 并设置为开机自启..."
    systemctl enable "snell@${INSTANCE_NAME}"
    systemctl start "snell@${INSTANCE_NAME}"
    
    echo "Snell 实例 '${INSTANCE_NAME}' 安装并启动成功！"
    echo "配置文件路径: ${CONFIG_FILE}"
    echo "预共享密钥(PSK): ${PSK}"
    echo "监听端口: ${PORT}"
    
    read -p "按任意键返回主菜单..." key
}

# 卸载 Snell
uninstall_snell() {
    mapfile -t instances < <(find_instances)
    if [ ${#instances[@]} -eq 0 ]; then
        echo "未找到任何实例。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    echo "当前 Snell 实例:"
    for i in "${!instances[@]}"; do
        echo " $((i+1)). ${instances[i]}"
    done
    echo ""

    read -p "请输入要卸载的实例序号 (输入 0 返回): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入一个数字。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    if [ "$choice" -eq 0 ]; then
        return
    fi

    local index=$((choice-1))

    if [ "$index" -lt 0 ] || [ "$index" -ge ${#instances[@]} ]; then
        echo "错误: 无效的序号。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    local INSTANCE_NAME=${instances[$index]}
    
    CONFIG_FILE="${CONFIG_DIR}/${INSTANCE_NAME}.conf"
    LOG_FILE="${LOG_DIR}/${INSTANCE_NAME}.log"
    SERVICE_NAME="snell@${INSTANCE_NAME}.service"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 实例 '${INSTANCE_NAME}' 不存在。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    read -p "确定要卸载实例 '${INSTANCE_NAME}' 吗？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "卸载已取消"
        read -p "按任意键返回主菜单..." key
        return
    fi
    
    echo "开始卸载实例 '${INSTANCE_NAME}'..."
    
    # 停止并禁用服务
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
    fi
    if systemctl is-enabled --quiet "$SERVICE_NAME"; then
        systemctl disable "$SERVICE_NAME"
    fi
    
    # 备份并删除配置文件
    cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak"
    echo "已备份配置文件到 ${CONFIG_FILE}.bak"
    rm -f "${CONFIG_FILE}"
    
    # 备份并删除日志文件
    if [ -f "${LOG_FILE}" ]; then
        cp "${LOG_FILE}" "${LOG_FILE}.bak"
        echo "已备份日志文件到 ${LOG_FILE}.bak"
        rm -f "${LOG_FILE}"
    fi

    systemctl daemon-reload
    
    echo "实例 '${INSTANCE_NAME}' 已成功卸载"

    # 检查是否还有其他实例
    REMAINING_INSTANCES=$(find_instances)
    if [ -z "$REMAINING_INSTANCES" ]; then
        read -p "所有实例都已卸载。是否要删除 snell-server 程序和 systemd 模板? (y/n): " cleanup_confirm
        if [ "$cleanup_confirm" = "y" ] || [ "$cleanup_confirm" = "Y" ]; then
            rm -f "${INSTALL_DIR}/snell-server"
            rm -f "${SYSTEMD_TEMPLATE_SERVICE}"
            rm -rf "${CONFIG_DIR}"
            rm -rf "${LOG_DIR}"
            systemctl daemon-reload
            echo "snell-server 和相关文件已清理。"
        fi
    fi

    read -p "按任意键返回主菜单..." key
}

# 重启 Snell 实例
restart_snell() {
    mapfile -t instances < <(find_instances)
    if [ ${#instances[@]} -eq 0 ]; then
        echo "未找到任何实例。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    echo "当前 Snell 实例:"
    for i in "${!instances[@]}"; do
        echo " $((i+1)). ${instances[i]}"
    done
    echo ""

    read -p "请输入要重启的实例序号 (输入 0 返回): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入一个数字。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    if [ "$choice" -eq 0 ]; then
        return
    fi

    local index=$((choice-1))

    if [ "$index" -lt 0 ] || [ "$index" -ge ${#instances[@]} ]; then
        echo "错误: 无效的序号。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    local INSTANCE_NAME=${instances[$index]}
    
    CONFIG_FILE="${CONFIG_DIR}/${INSTANCE_NAME}.conf"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 实例 '${INSTANCE_NAME}' 不存在。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    echo "正在重启实例 '${INSTANCE_NAME}'..."
    if systemctl restart "snell@${INSTANCE_NAME}"; then
        echo "实例 '${INSTANCE_NAME}' 重启成功。"
    else
        echo "错误: 实例 '${INSTANCE_NAME}' 重启失败。请检查日志。"
    fi
    
    read -p "按任意键返回主菜单..." key
}

# 查看配置
view_config() {
    mapfile -t instances < <(find_instances)
    if [ ${#instances[@]} -eq 0 ]; then
        echo "未找到任何实例。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    echo "当前 Snell 实例:"
    for i in "${!instances[@]}"; do
        echo " $((i+1)). ${instances[i]}"
    done
    echo ""

    read -p "请输入要查看配置的实例序号 (输入 0 返回): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入一个数字。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    if [ "$choice" -eq 0 ]; then
        return
    fi

    local index=$((choice-1))

    if [ "$index" -lt 0 ] || [ "$index" -ge ${#instances[@]} ]; then
        echo "错误: 无效的序号。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    local INSTANCE_NAME=${instances[$index]}
    
    CONFIG_FILE="${CONFIG_DIR}/${INSTANCE_NAME}.conf"

    if [ -f "${CONFIG_FILE}" ]; then
        echo "===== 实例 '${INSTANCE_NAME}' 配置信息 ====="
        echo "配置文件路径: ${CONFIG_FILE}"
        echo "配置内容:"
        cat "${CONFIG_FILE}"
        
        PORT=$(grep -oP 'listen\s*=\s*0\.0\.0\.0:\K[0-9]+' ${CONFIG_FILE})
        PSK=$(grep -oP 'psk\s*=\s*\K\S+' ${CONFIG_FILE})
        
        echo ""
        echo "===== 配置摘要 ====="
        echo "端口: ${PORT:-未配置}"
        echo "PSK: ${PSK:-未配置}"
        
        echo ""
        echo "===== 客户端配置参考 ====="
        SERVER_IP=$(ip -4 addr | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
        echo "Surge/Shadowrocket 配置:"
        echo "[Proxy]"
        echo "${INSTANCE_NAME} = snell, ${SERVER_IP:-<服务器IP>}, ${PORT:-<端口>}, psk=${PSK:-<密钥>}, version=4, reuse=true, block-quic=on"
    else
        echo "未找到实例 '${INSTANCE_NAME}' 的配置文件。"
    fi
    
    echo ""
    read -p "按任意键返回主菜单..." key
}

# 修改实例配置
edit_config() {
    # 检查 nano 是否已安装
    if ! command -v nano &> /dev/null; then
        echo "错误: nano 编辑器未安装。"
        read -p "是否尝试自动安装 nano? (y/n): " install_confirm
        if [ "$install_confirm" = "y" ] || [ "$install_confirm" = "Y" ]; then
            if [ -x "$(command -v apt-get)" ]; then
                apt-get update && apt-get install -y nano
            elif [ -x "$(command -v yum)" ]; then
                yum install -y nano
            else
                echo "无法自动安装 nano，请手动安装后重试。"
                read -p "按任意键返回主菜单..." key
                return
            fi
        else
            echo "操作已取消。"
            read -p "按任意键返回主菜单..." key
            return
        fi
    fi

    mapfile -t instances < <(find_instances)
    if [ ${#instances[@]} -eq 0 ]; then
        echo "未找到任何实例。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    echo "当前 Snell 实例:"
    for i in "${!instances[@]}"; do
        echo " $((i+1)). ${instances[i]}"
    done
    echo ""

    read -p "请输入要修改配置的实例序号 (输入 0 返回): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入一个数字。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    if [ "$choice" -eq 0 ]; then
        return
    fi

    local index=$((choice-1))

    if [ "$index" -lt 0 ] || [ "$index" -ge ${#instances[@]} ]; then
        echo "错误: 无效的序号。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    local INSTANCE_NAME=${instances[$index]}
    
    CONFIG_FILE="${CONFIG_DIR}/${INSTANCE_NAME}.conf"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 实例 '${INSTANCE_NAME}' 的配置文件不存在。"
        read -p "按任意键返回主菜单..." key
        return
    fi

    nano "${CONFIG_FILE}"

    read -p "配置已修改。是否需要重启实例 '${INSTANCE_NAME}' 使配置生效? (y/n): " restart_confirm
    if [ "$restart_confirm" = "y" ] || [ "$restart_confirm" = "Y" ]; then
        echo "正在重启实例 '${INSTANCE_NAME}'..."
        if systemctl restart "snell@${INSTANCE_NAME}"; then
            echo "实例 '${INSTANCE_NAME}' 重启成功。"
        else
            echo "错误: 实例 '${INSTANCE_NAME}' 重启失败。请检查日志。"
        fi
    fi

    read -p "按任意键返回主菜单..." key
}


# 主程序
while true; do
    show_menu
    case $choice in
        1)
            update_snell_binary
            read -p "按任意键返回主菜单..." key
            ;;
        2)
            check_status
            ;;
        3)
            install_snell
            ;;
        4)
            uninstall_snell
            ;;
        5)
            restart_snell
            ;;
        6)
            view_config
            ;;
        7)
            edit_config
            ;;
        0)
            echo "感谢使用 Snell 管理脚本，再见！"
            exit 0
            ;;
        *)
            echo "无效选择，请重新输入"
            sleep 2
            ;;
    esac
done
