#!/bin/bash
set -e

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行此脚本"
  exit 1
fi

# 检查 Docker 是否已安装，否则安装
if ! command -v docker &> /dev/null; then
  echo "未检测到 Docker，正在安装..."
  if command -v apt-get &> /dev/null; then
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
  elif command -v yum &> /dev/null; then
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io
    systemctl start docker
    systemctl enable docker
  else
    echo "无法自动安装 Docker，请手动安装后重试。"
    exit 1
  fi
  echo "Docker 安装完成。"
fi

# 确保 Docker 服务正在运行
if ! systemctl is-active --quiet docker; then
  echo "Docker 服务未运行，正在启动..."
  systemctl start docker
  systemctl enable docker
  echo "Docker 服务已启动。"
fi

# 检查 docker-compose 是否已安装，否则安装
if ! command -v docker-compose &> /dev/null; then
  echo "未检测到 docker-compose，正在安装..."
  if command -v apt-get &> /dev/null; then
    apt-get update
    apt-get install -y docker-compose
  elif command -v yum &> /dev/null; then
    yum install -y docker-compose
  else
    echo "无法通过包管理器安装 docker-compose，尝试使用 curl 方式安装..."
    curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
  fi
  
  if ! command -v docker-compose &> /dev/null; then
    echo "安装 docker-compose 失败，请手动安装后重试。"
    exit 1
  fi
  echo "docker-compose 安装完成。"
fi

SOGA_DIR="/etc/soga"
DEFAULT_COMPOSE_FILE="$SOGA_DIR/docker-compose.yml"
COMPOSE_FILE=""

# 显示菜单
enable_show_menu() {
  clear
  echo "========================================="
  echo "        Soga 后端管理脚本               "
  echo "========================================="
  echo "1) 安装 Soga"
  echo "2) 编辑 Soga 配置"
  echo "3) 重启 Soga 服务"
  echo "4) 添加节点"
  echo "5) 删除节点"
  echo "0) 退出"
  echo "========================================="
}

# 选择服务类型对应的 compose 文件
enable_choose_compose() {
  read -p "请输入 server_type (对应 compose 文件后缀，如 ss、v2ray、trojan): " sts
  file="$SOGA_DIR/docker-compose-$sts.yml"
  if [ ! -f "$file" ]; then
    echo "找不到文件 $file，请确认已安装对应服务。"
    return 1
  fi
  COMPOSE_FILE="$file"
  return 0
}

# 安装函数
install_soga() {
  echo " >>> 安装 Soga..."
  read -p "请输入 server_type (如 ss/v2ray/trojan 等): " server_type
  read -p "请输入 webapi_url (含 https://、以 / 结尾): " webapi_url
  read -p "请输入 webapi_key: " webapi_key
  echo "node_id 将留空，请使用“添加节点”功能添加。"

  mkdir -p "$SOGA_DIR"
  COMPOSE_FILE="$SOGA_DIR/docker-compose-$server_type.yml"
  cat > "$COMPOSE_FILE" << EOF
version: "3.8"

services:
  soga:
    image: vaxilu/soga:latest
    container_name: soga-$server_type
    restart: always
    network_mode: host
    volumes:
      - /etc/soga/:/etc/soga/
    environment:
      - type=v2board
      - server_type=$server_type
      - api=webapi
      - webapi_url=$webapi_url
      - webapi_key=$webapi_key
      - node_id=
      - forbidden_bit_torrent=true
      - log_level=info
      - default_dns=1.1.1.1
      - dns_strategy=ipv4_first
EOF

  echo "配置文件已生成：$COMPOSE_FILE"
  echo "正在启动 Soga 服务..."
  docker-compose -f "$COMPOSE_FILE" up -d
  echo "安装并启动完成。"
  read -p "按回车键返回菜单..." _
}

# 编辑配置
edit_soga() {
  echo " >>> 请选择要编辑的服务 compose 文件"
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  echo "编辑文件：$COMPOSE_FILE"
  ${EDITOR:-vi} "$COMPOSE_FILE"
  echo "配置已保存。"
  read -p "按回车键返回菜单..." _
}

# 重启服务
restart_soga() {
  echo " >>> 请选择要重启的服务"
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  echo "重启服务：$COMPOSE_FILE"
  docker-compose -f "$COMPOSE_FILE" up -d
  echo "服务已重启。"
  read -p "按回车键返回菜单..." _
}

# 添加节点
add_node() {
  echo " >>> 添加节点：请选择对应服务"
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  read -p "请输入要添加的 node_id: " new_id
  current=$(grep "- node_id=" "$COMPOSE_FILE" | cut -d'=' -f2)
  if [ -z "$current" ]; then
    updated="$new_id"
  else
    updated="$current,$new_id"
  fi
  sed -i "/- node_id=/c\      - node_id=$updated" "$COMPOSE_FILE"
  echo "已更新 node_id 列表：$updated"
  docker-compose -f "$COMPOSE_FILE" up -d
  echo "添加并重启服务完成。"
  read -p "按回车键返回菜单..." _
}

# 删除节点
delete_node() {
  echo " >>> 删除节点：请选择对应服务"
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  read -p "请输入要删除的 node_id: " rem_id
  current=$(grep "- node_id=" "$COMPOSE_FILE" | cut -d'=' -f2)
  IFS=',' read -ra ids <<< "$current"
  new_list=""
  for id in "${ids[@]}"; do
    if [ "$id" != "$rem_id" ] && [ -n "$id" ]; then
      new_list=${new_list:+$new_list,}$id
    fi
  done
  sed -i "/- node_id=/c\      - node_id=$new_list" "$COMPOSE_FILE"
  echo "已更新 node_id 列表：$new_list"
  docker-compose -f "$COMPOSE_FILE" up -d
  echo "删除并重启服务完成。"
  read -p "按回车键返回菜单..." _
}

# 主循环
while true; do
  enable_show_menu
  read -p "请输入选项 [0-5]: " choice
  case "$choice" in
    1) install_soga  ;; 
    2) edit_soga     ;; 
    3) restart_soga  ;; 
    4) add_node      ;; 
    5) delete_node   ;; 
    0) echo "退出脚本。"; exit 0 ;; 
    *) echo "无效选项，请重新输入。"; read -p "按回车键继续..." _;;
  esac
done
