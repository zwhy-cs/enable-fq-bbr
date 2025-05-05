#!/bin/bash

# 颜色设置
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
NC="\033[0m"

# 打印信息函数
info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

error() {
    echo -e "${RED}[错误]${NC} $1"
}

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请以root权限运行此脚本"
        exit 1
    fi
}

# 检查系统环境
check_system() {
    # 检查操作系统
    if [[ -f /etc/redhat-release ]]; then
        PKGMANAGER="yum"
    elif cat /etc/issue | grep -Eqi "debian"; then
        PKGMANAGER="apt"
    elif cat /etc/issue | grep -Eqi "ubuntu"; then
        PKGMANAGER="apt"
    elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
        PKGMANAGER="yum"
    elif cat /proc/version | grep -Eqi "debian"; then
        PKGMANAGER="apt"
    elif cat /proc/version | grep -Eqi "ubuntu"; then
        PKGMANAGER="apt"
    elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
        PKGMANAGER="yum"
    else
        error "不支持的操作系统"
        exit 1
    fi
    info "包管理器: $PKGMANAGER"
}


# 安装Xray
install_xray() {
    info "开始安装Xray..."
    
    # 下载Xray官方安装脚本
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    info "Xray安装成功"
}

# 配置Xray基本框架
configure_xray() {
    info "开始配置Xray..."

    # 生成最简单的配置
    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "debug"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

    # 重启Xray服务
    systemctl restart xray
    systemctl enable xray
    
    info "Xray基本配置完成"
}

# 添加Reality节点
add_reality_node() {
    info "开始添加Reality节点..."
    
    UUID=$(xray uuid)
    KEY_PAIR=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "Private" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "Public" | awk '{print $3}')
    
    # 询问用户输入
    read -p "请输入监听端口 [默认: 443]: " PORT
    PORT=${PORT:-443}
    
    read -p "请输入目标网站 (需支持TLS1.3和h2，例如: www.microsoft.com:443): " DEST
    DEST=${DEST:-"www.microsoft.com:443"}
    
    read -p "请输入服务器名称 (一般与目标网站域名相同): " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-"www.microsoft.com"}

    # 读取现有配置
    CURRENT_CONFIG=$(cat /usr/local/etc/xray/config.json)
    
    # 创建新的inbound配置
    NEW_INBOUND=$(cat << EOF
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$DEST",
          "serverNames": [
            "$SERVER_NAME"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "",
            "0123456789abcdef"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
EOF
)

    # 使用临时文件进行处理
    TMP_FILE=$(mktemp)
    
    
    # 将新的inbound添加到现有配置中
    echo "$CURRENT_CONFIG" | jq ".inbounds += [$NEW_INBOUND]" > "$TMP_FILE"
    mv "$TMP_FILE" /usr/local/etc/xray/config.json
    
    # 重启Xray
    systemctl restart xray
    
    # 显示节点信息
    IP=$(curl -s http://ipinfo.io/ip)
    
    echo ""
    echo "================================================================="
    echo -e "${GREEN}Reality节点添加成功!${NC}"
    echo -e "${YELLOW}节点配置信息：${NC}"
    echo -e "协议: ${GREEN}VLESS${NC}"
    echo -e "地址: ${GREEN}$IP${NC}"
    echo -e "端口: ${GREEN}$PORT${NC}"
    echo -e "用户ID: ${GREEN}$UUID${NC}"
    echo -e "流控: ${GREEN}xtls-rprx-vision${NC}"
    echo -e "传输协议: ${GREEN}tcp${NC}"
    echo -e "安全: ${GREEN}reality${NC}"
    echo -e "私钥: ${GREEN}$PRIVATE_KEY${NC}"
    echo -e "公钥: ${GREEN}$PUBLIC_KEY${NC}"
    echo -e "ServerName: ${GREEN}$SERVER_NAME${NC}"
    echo -e "ShortID: ${GREEN}0123456789abcdef${NC}"
    echo -e "Fingerprint: ${GREEN}chrome${NC}"
    echo "================================================================="
    echo ""
    
    info "Reality节点配置完成"
}

# 添加Shadowsocks节点
add_ss_node() {
    info "开始添加Shadowsocks节点..."
    
    # 生成随机密码
    PASSWORD=$(openssl rand -base64 16)
    
    # 询问用户输入
    read -p "请输入监听端口 [默认: 1234]: " PORT
    PORT=${PORT:-1234}
    
    read -p "请输入加密方法 [默认: 2022-blake3-aes-128-gcm]: " METHOD
    METHOD=${METHOD:-"2022-blake3-aes-128-gcm"}
    
    read -p "请输入密码 [默认随机生成]: " USER_PASSWORD
    PASSWORD=${USER_PASSWORD:-$PASSWORD}

    # 读取现有配置
    CURRENT_CONFIG=$(cat /usr/local/etc/xray/config.json)
    
    # 创建新的inbound配置
    NEW_INBOUND=$(cat << EOF
    {
      "port": $PORT,
      "protocol": "shadowsocks",
      "settings": {
        "method": "$METHOD",
        "password": "$PASSWORD",
        "network": "tcp,udp"
      }
    }
EOF
)

    # 使用临时文件进行处理
    TMP_FILE=$(mktemp)
    
    # 将新的inbound添加到现有配置中
    echo "$CURRENT_CONFIG" | jq ".inbounds += [$NEW_INBOUND]" > "$TMP_FILE"
    mv "$TMP_FILE" /usr/local/etc/xray/config.json
    
    # 重启Xray
    systemctl restart xray
    
    # 显示节点信息
    IP=$(curl -s http://ipinfo.io/ip)
    
    echo ""
    echo "================================================================="
    echo -e "${GREEN}Shadowsocks节点添加成功!${NC}"
    echo -e "${YELLOW}节点配置信息：${NC}"
    echo -e "协议: ${GREEN}Shadowsocks${NC}"
    echo -e "地址: ${GREEN}$IP${NC}"
    echo -e "端口: ${GREEN}$PORT${NC}"
    echo -e "加密方法: ${GREEN}$METHOD${NC}"
    echo -e "密码: ${GREEN}$PASSWORD${NC}"
    echo "================================================================="
    echo ""
    
    info "Shadowsocks节点配置完成"
}

# 卸载Xray
uninstall_xray() {
    info "开始卸载Xray..."
    
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
      
    info "Xray已卸载"
}

# 添加查看配置文件函数
view_config() {
    info "Xray配置文件内容："
    echo ""
    cat /usr/local/etc/xray/config.json
    echo ""
}

# 检查Xray状态
check_status() {
    echo ""
    echo "Xray状态："
    systemctl status xray
}

# 主菜单
show_menu() {
    echo ""
    echo "Xray管理脚本"
    echo "----------------------"
    echo "1. 安装Xray"
    echo "2. 添加Reality节点"
    echo "3. 添加Shadowsocks节点"
    echo "4. 卸载Xray"
    echo "5. 查看Xray状态"
    echo "6. 查看Xray配置"
    echo "0. 退出脚本"
    echo "----------------------"
    read -p "请输入选项 [0-6]: " option
    
    case "$option" in
        1)
            check_root
            check_system
            install_xray
            configure_xray
            ;;
        2)
            check_root
            add_reality_node
            ;;
        3)
            check_root
            add_ss_node
            ;;
        4)
            check_root
            uninstall_xray
            ;;
        5)
            check_status
            ;;
        6)
            view_config
            ;;
        0)
            exit 0
            ;;
        *)
            error "无效选项"
            ;;
    esac
}

# 执行主菜单
show_menu