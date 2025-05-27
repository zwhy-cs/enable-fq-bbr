#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误: 必须使用root用户运行此脚本!${PLAIN}"
    exit 1
fi

# 检查docker是否安装
check_docker() {
  if ! docker version &> /dev/null; then
    echo "未检测到 docker，正在安装..."
    curl -sSL https://get.docker.com | bash
    echo "docker 安装完成"
  else
    echo "docker 已安装"
  fi
}

# 配置系统内存锁定限制
configure_memlock() {

  cat >> /etc/security/limits.conf << EOF
*    hard    memlock        unlimited
*    soft    memlock        unlimited
EOF
}

# 获取用户输入
get_user_input() {
    read -p "请输入TLS域名和端口(例如: icloud.com:443): " TLS_SERVER
    if [ -z "$TLS_SERVER" ]; then
        TLS_SERVER="icloud.com:443"
        echo -e "${YELLOW}您没有输入，将使用默认值: ${TLS_SERVER}${PLAIN}"
    fi
}

# 创建配置文件
create_config() {
    echo -e "${GREEN}正在创建配置文件...${PLAIN}"
    
    # 创建docker-compose.yml
    mkdir -p /etc/shadowtls
    cat > /etc/shadowtls/compose.yml << EOF
version: '3.5'
services:
  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    restart: always
    network_mode: "host"
    environment:
      - MODE=server
      - LISTEN=0.0.0.0:443
      - SERVER=127.0.0.1:45678
      - TLS=${TLS_SERVER}
      - PASSWORD=ixejvmdGp0fuIBkg4M2Diw==
      - V3=1
      - STRICT=1
      - RUST_LOG=error
    security_opt:
      - seccomp:unconfined
EOF
}

# 启动服务
start_service() {
    echo -e "${GREEN}正在启动服务...${PLAIN}"
    cd /etc/shadowtls && docker compose up -d
    if [ $? -ne 0 ]; then
        echo -e "${RED}服务启动失败，请检查配置和网络${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}服务启动成功${PLAIN}"
}

# 显示配置信息
show_config() {
    SHADOW_TLS_PASSWORD=$(grep "PASSWORD=" /etc/shadowtls/compose.yml | tail -1 | cut -d'=' -f2- | tr -d ' ')

    echo -e "${YELLOW}Shadow-TLS 密码: ${PLAIN}${SHADOW_TLS_PASSWORD}"
    echo -e "${YELLOW}Shadow-TLS 版本: ${PLAIN}v3"
    echo -e "${YELLOW}混淆域名: ${PLAIN}${TLS_SERVER}"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "${GREEN}配置文件路径: /etc/shadowtls/compose.yml${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
}

# 主函数
main() {
    echo -e "${GREEN}开始安装Shadow-TLS...${PLAIN}"
    check_docker
    configure_memlock
    get_user_input
    create_config
    start_service
    show_config
}

main
