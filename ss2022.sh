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

# 创建配置文件
create_config() {
    echo -e "${GREEN}正在创建配置文件...${PLAIN}"
    
    # 生成随机密码
    SS_PASSWORD=$(openssl rand -base64 16)
    SHADOW_TLS_PASSWORD=$(openssl rand -base64 16)
    
    # 创建docker-compose.yml
    mkdir -p /etc/shadowsocks-docker
    cat > /etc/shadowsocks-docker/docker-compose.yml << EOF
version: '3.0'
services:
  shadowsocks:
    image: ghcr.io/shadowsocks/ssserver-rust:latest
    container_name: shadowsocks-raw
    restart: always
    network_mode: "host"
    volumes:
      - /etc/shadowsocks-docker/config.json:/etc/shadowsocks-rust/config.json
  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    restart: always
    network_mode: "host"
    environment:
      - MODE=server
      - LISTEN=0.0.0.0:8443
      - SERVER=127.0.0.1:45678
      - TLS=icloud.com:443
      - PASSWORD=${SHADOW_TLS_PASSWORD}
      - V3=1
EOF

    # 创建shadowsocks-rust的配置文件
    cat > /etc/shadowsocks-docker/config.json << EOF
{
    "server": "127.0.0.1",
    "server_port": 45678,
    "password": "${SS_PASSWORD}",
    "method": "2022-blake3-aes-128-gcm",
    "mode": "tcp_and_udp",
}
EOF

    echo -e "${GREEN}配置文件创建完成${PLAIN}"
}

# 启动服务
start_service() {
    echo -e "${GREEN}正在启动服务...${PLAIN}"
    cd /etc/shadowsocks-docker && docker compose up -d
    if [ $? -ne 0 ]; then
        echo -e "${RED}服务启动失败，请检查配置和网络${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}服务启动成功${PLAIN}"
}

# 显示配置信息
show_config() {
    IP=$(curl -s https://api.ipify.org)
    SS_PASSWORD=$(grep "\"password\":" /etc/shadowsocks-docker/config.json | cut -d'"' -f4)
    SHADOW_TLS_PASSWORD=$(grep "PASSWORD=" /etc/shadowsocks-docker/docker-compose.yml | tail -1 | cut -d'=' -f2- | tr -d ' ')

    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "${GREEN}Shadowsocks + Shadow-TLS 安装成功！${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "${YELLOW}服务器地址: ${PLAIN}${IP}"
    echo -e "${YELLOW}端口: ${PLAIN}8443"
    echo -e "${YELLOW}加密方式: ${PLAIN}2022-blake3-aes-128-gcm"
    echo -e "${YELLOW}Shadowsocks 密码: ${PLAIN}${SS_PASSWORD}"
    echo -e "${YELLOW}Shadow-TLS 密码: ${PLAIN}${SHADOW_TLS_PASSWORD}"
    echo -e "${YELLOW}Shadow-TLS 版本: ${PLAIN}v3"
    echo -e "${YELLOW}混淆域名: ${PLAIN}icloud.com:443"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "${GREEN}配置文件路径: /etc/shadowsocks-docker/config.json${PLAIN}"
    echo -e "${GREEN}重启命令: cd /etc/shadowsocks-docker && docker compose restart${PLAIN}"
    echo -e "${GREEN}停止命令: cd /etc/shadowsocks-docker && docker compose down${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
}

# 主函数
main() {
    echo -e "${GREEN}开始安装 Shadowsocks + Shadow-TLS...${PLAIN}"
    check_docker
    create_config
    start_service
    show_config
}

main
