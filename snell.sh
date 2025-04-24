#!/bin/bash
# Snell v4 管理脚本 - 支持安装、卸载、查看状态和配置
# 请确保在 root 权限下运行
# 
# 安装方法:
# sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/wzxzwhy/enable-fq-bbr/refs/heads/main/snell.sh)"
# 
# 创建快捷命令:
# echo 'alias s="sudo /usr/local/bin/snell-manager.sh"' >> ~/.bashrc && source ~/.bashrc

set -e

# 配置变量
SNELL_VERSION="4.1.1"
SNELL_DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-amd64.zip"
INSTALL_DIR="/usr/local/bin"
CONFIG_FILE="/etc/snell.conf"
SYSTEMD_SERVICE="/etc/systemd/system/snell.service"
LOG_FILE="/var/log/snell.log"

# 检查是否以root权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请以root权限运行此脚本"
    exit 1
fi

# 显示菜单
show_menu() {
    clear
    echo "========== Snell v4 管理脚本 =========="
    echo "1. 查看当前 Snell 状态"
    echo "2. 安装 Snell"
    echo "3. 卸载 Snell"
    echo "4. 查看当前 Snell 配置"
    echo "5. 创建快捷命令 's'"
    echo "0. 退出脚本"
    echo "======================================"
    echo ""
    read -p "请选择操作 [0-5]: " choice
}

# 检查 Snell 是否已安装
is_snell_installed() {
    if [ -f "${INSTALL_DIR}/snell-server" ] && [ -f "${CONFIG_FILE}" ]; then
        return 0  # 已安装
    else
        return 1  # 未安装
    fi
}

# 查看 Snell 状态
check_status() {
    echo "正在检查 Snell 状态..."
    
    if is_snell_installed; then
        if systemctl is-active --quiet snell; then
            echo "Snell 服务当前状态: 运行中"
            systemctl status snell | grep -E "Active:|CGroup:"
            
            # 显示当前监听端口
            PORT=$(grep -oP "listen = 0.0.0.0:\K[0-9]+" ${CONFIG_FILE})
            echo "当前监听端口: ${PORT}"
            
            # 显示网络连接状态
            echo "网络连接状态:"
            netstat -tlnp | grep snell-server || ss -tlnp | grep snell-server || echo "无法获取网络连接信息，请确保已安装 netstat 或 ss 工具"
        else
            echo "Snell 服务当前状态: 未运行"
        fi
    else
        echo "Snell 未安装或配置文件丢失"
    fi
    
    echo ""
    read -p "按任意键返回主菜单..." key
}

# 安装 Snell
install_snell() {
    if is_snell_installed; then
        echo "Snell 已经安装。如需重新安装，请先卸载。"
        read -p "按任意键返回主菜单..." key
        return
    fi
    
    echo "开始安装 Snell v${SNELL_VERSION}..."
    
    # 获取用户输入的监听端口，默认8388
    read -p "请输入监听端口(默认8388): " PORT
    PORT=${PORT:-8388}
    
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
    
    # 检查 unzip 是否安装，如果未安装，则安装它
    if ! command -v unzip &>/dev/null; then
        echo "未检测到 unzip，正在安装 unzip..."
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update && apt-get install -y unzip
        elif [ -x "$(command -v yum)" ]; then
            yum install -y unzip
        else
            echo "无法检测到包管理工具，请手动安装 unzip。"
            read -p "按任意键返回主菜单..." key
            return
        fi
    fi
    
    # 检查 curl 是否安装，如果未安装，则安装它
    if ! command -v curl &>/dev/null; then
        echo "未检测到 curl，正在安装 curl..."
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update && apt-get install -y curl
        elif [ -x "$(command -v yum)" ]; then
            yum install -y curl
        else
            echo "无法检测到包管理工具，请手动安装 curl。"
            read -p "按任意键返回主菜单..." key
            return
        fi
    fi
    
    # 创建临时目录并下载 Snell ZIP 包
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    echo "正在下载 Snell v${SNELL_VERSION}..."
    if ! curl -L -o snell.zip "$SNELL_DOWNLOAD_URL"; then
        echo "下载失败，请检查网络连接和下载链接。"
        cd /
        rm -rf "$TMP_DIR"
        read -p "按任意键返回主菜单..." key
        return
    fi
    
    # 解压 ZIP 文件
    echo "正在解压文件..."
    if ! unzip snell.zip; then
        echo "解压失败，请检查下载的文件是否完整。"
        cd /
        rm -rf "$TMP_DIR"
        read -p "按任意键返回主菜单..." key
        return
    fi
    
    # 检查并移动可执行文件
    if [ -f "snell-server" ]; then
        mv snell-server ${INSTALL_DIR}/snell-server
        chmod +x ${INSTALL_DIR}/snell-server
    else
        echo "错误：未找到 snell-server 可执行文件，请检查下载链接和版本号。"
        cd /
        rm -rf "$TMP_DIR"
        read -p "按任意键返回主菜单..." key
        return
    fi
    
    # 清理临时目录
    cd /
    rm -rf "$TMP_DIR"
    
    # 生成配置文件
    echo "正在创建配置文件 ${CONFIG_FILE}..."
    cat > ${CONFIG_FILE} <<EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${PSK}
ipv6 = false
EOF
    
    # 创建日志文件
    touch ${LOG_FILE}
    chmod 644 ${LOG_FILE}
    
    # 创建 systemd 服务文件
    echo "正在创建 systemd 服务文件 ${SYSTEMD_SERVICE}..."
    cat > ${SYSTEMD_SERVICE} <<EOF
[Unit]
Description=Snell v4 Server
After=network.target

[Service]
ExecStart=${INSTALL_DIR}/snell-server -c ${CONFIG_FILE}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    
    # 重新加载 systemd 并启动服务
    echo "正在重新加载 systemd..."
    systemctl daemon-reload
    echo "启动 Snell 服务并设置为开机自启..."
    systemctl enable snell
    systemctl start snell
    
    echo "Snell v4 安装并启动成功！"
    echo "配置文件路径: ${CONFIG_FILE}"
    echo "日志文件路径: ${LOG_FILE}"
    echo "预共享密钥(PSK): ${PSK}"
    echo "监听端口: ${PORT}"
    
    read -p "按任意键返回主菜单..." key
}

# 卸载 Snell
uninstall_snell() {
    if ! is_snell_installed; then
        echo "未检测到 Snell 安装，无需卸载。"
        read -p "按任意键返回主菜单..." key
        return
    fi
    
    read -p "确定要卸载 Snell 吗？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "卸载已取消"
        read -p "按任意键返回主菜单..." key
        return
    fi
    
    echo "开始卸载 Snell..."
    
    # 停止并禁用服务
    if systemctl is-active --quiet snell; then
        systemctl stop snell
    fi
    if systemctl is-enabled --quiet snell; then
        systemctl disable snell
    fi
    
    # 删除服务文件
    if [ -f "${SYSTEMD_SERVICE}" ]; then
        rm -f "${SYSTEMD_SERVICE}"
        systemctl daemon-reload
    fi
    
    # 删除可执行文件
    if [ -f "${INSTALL_DIR}/snell-server" ]; then
        rm -f "${INSTALL_DIR}/snell-server"
    fi
    
    # 备份并删除配置文件
    if [ -f "${CONFIG_FILE}" ]; then
        cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak"
        echo "已备份配置文件到 ${CONFIG_FILE}.bak"
        rm -f "${CONFIG_FILE}"
    fi
    
    # 备份并删除日志文件
    if [ -f "${LOG_FILE}" ]; then
        cp "${LOG_FILE}" "${LOG_FILE}.bak"
        echo "已备份日志文件到 ${LOG_FILE}.bak"
        rm -f "${LOG_FILE}"
    fi
    
    echo "Snell 已成功卸载"
    read -p "按任意键返回主菜单..." key
}

# 查看配置
view_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        echo "===== Snell 配置信息 ====="
        echo "配置文件路径: ${CONFIG_FILE}"
        echo "配置内容:"
        cat "${CONFIG_FILE}"
        
        # 提取关键信息
        PORT=$(grep -oP "listen = 0.0.0.0:\K[0-9]+" ${CONFIG_FILE})
        PSK=$(grep -oP "psk = \K[a-z0-9]+" ${CONFIG_FILE})
        IPV6=$(grep -oP "ipv6 = \K(true|false)" ${CONFIG_FILE})
        
        echo ""
        echo "===== 配置摘要 ====="
        echo "端口: ${PORT:-未配置}"
        echo "PSK: ${PSK:-未配置}"
        echo "IPv6: ${IPV6:-未配置}"
        
        # 为 Surge 等客户端提供快速配置格式
        echo ""
        echo "===== 客户端配置参考 ====="
        SERVER_IP=$(ip -4 addr | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
        echo "Surge/Shadowrocket 配置:"
        echo "[Proxy]"
        echo "Snell = snell, ${SERVER_IP:-<服务器IP>}, ${PORT:-<端口>}, psk=${PSK:-<密钥>}, version=4, reuse=true, block-quic=on"
    else
        echo "未找到 Snell 配置文件：${CONFIG_FILE}"
    fi
    
    echo ""
    read -p "按任意键返回主菜单..." key
}

# 安装脚本到系统路径并创建别名
install_shortcut() {
    # 将脚本复制到系统路径
    SCRIPT_PATH="/usr/local/bin/snell-manager.sh"
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    
    # 判断当前使用的是 bash 还是 zsh
    SHELL_TYPE="$(basename "$SHELL")"
    RC_FILE=""
    
    if [ "$SHELL_TYPE" = "zsh" ]; then
        RC_FILE="$HOME/.zshrc"
    else
        RC_FILE="$HOME/.bashrc"
    fi
    
    # 检查别名是否已存在
    if ! grep -q "alias s=" "$RC_FILE"; then
        echo 'alias s="sudo /usr/local/bin/snell-manager.sh"' >> "$RC_FILE"
        echo "已添加别名 's' 到 $RC_FILE"
        echo "请运行 'source $RC_FILE' 或重新打开终端以激活别名"
    else
        echo "别名 's' 已存在于 $RC_FILE 中"
    fi
    
    echo "现在您可以使用 's' 命令来运行此脚本"
    read -p "按任意键返回主菜单..." key
}

# 处理命令行参数
if [ $# -ge 1 ]; then
    case "$1" in
        "status" | "1")
            check_status
            exit 0
            ;;
        "install" | "2")
            install_snell
            exit 0
            ;;
        "uninstall" | "3")
            uninstall_snell
            exit 0
            ;;
        "config" | "4")
            view_config
            exit 0
            ;;
        *)
            # 无效参数，显示菜单
            ;;
    esac
fi

# 主程序
while true; do
    show_menu
    case $choice in
        1)
            check_status
            ;;
        2)
            install_snell
            ;;
        3)
            uninstall_snell
            ;;
        4)
            view_config
            ;;
        5)
            install_shortcut
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
