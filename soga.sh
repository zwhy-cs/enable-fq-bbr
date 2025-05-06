#!/bin/bash
set -e

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行此脚本"
  exit 1
fi

# 检查并安装 docker
check_install_docker() {
  if ! docker version &> /dev/null; then
    echo "未检测到 docker，正在安装..."
    curl -sSL https://get.docker.com | bash
    echo "docker 安装完成"
  else
    echo "docker 已安装"
  fi
}

# 执行检查安装
check_install_docker

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
  echo "6) 检查服务状态"
  echo "7) 更新 Soga"
  echo "0) 退出"
  echo "========================================="
}

# 选择服务类型对应的 compose 文件
enable_choose_compose() {
  read -p "请输入 server_type (对应 compose 文件后缀，如 ss、v2ray、trojan): " sts
  file="$SOGA_DIR/$sts/docker-compose-$sts.yml"
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
  echo "node_id 将留空，请使用"添加节点"功能添加。"

  mkdir -p "$SOGA_DIR/$server_type"
  COMPOSE_FILE="$SOGA_DIR/$server_type/docker-compose-$server_type.yml"
  cat > "$COMPOSE_FILE" << EOF
version: "3.3"

services:
  soga:
    image: vaxilu/soga:latest
    container_name: soga-$server_type
    restart: always
    network_mode: host
    volumes:
      - /etc/soga/$server_type/:/etc/soga/
    environment:
      - type=xboard
      - server_type=$server_type
      - api=webapi
      - webapi_url=$webapi_url
      - webapi_key=$webapi_key
      - node_id=
      - forbidden_bit_torrent=false
      - log_level=info
      - default_dns=1.1.1.1
      - dns_strategy=ipv4_first
EOF

  echo "配置文件已生成：$COMPOSE_FILE"
  echo "正在启动 Soga 服务..."
  docker compose -f "$COMPOSE_FILE" up -d
  echo "安装并启动完成。"
  read -p "按回车键返回菜单..." _
}

# 编辑配置
edit_soga() {
  echo " >>> 请选择要编辑的服务 compose 文件"
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  echo "编辑文件：$COMPOSE_FILE"
  ${EDITOR:-nano} "$COMPOSE_FILE"
  echo "配置已保存。"
  read -p "按回车键返回菜单..." _
}

# 重启服务
restart_soga() {
  echo " >>> 请选择要重启的服务"
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  echo "重启服务：$COMPOSE_FILE"
  docker compose -f "$COMPOSE_FILE" up -d
  echo "服务已重启。"
  read -p "按回车键返回菜单..." _
}

# 添加节点
add_node() {
  echo " >>> 添加节点..."
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  
  read -p "请输入 node_id: " node_id
  if [ -z "$node_id" ]; then
    echo "node_id 不能为空"
    read -p "按回车键返回菜单..." _
    return
  fi

  # 获取当前 node_id
  current_node_id=$(grep -oP 'node_id=\K[^ ]*' "$COMPOSE_FILE")
  
  # 如果当前 node_id 为空，直接设置新值
  if [ -z "$current_node_id" ]; then
    sed -i "s/node_id=.*/node_id=$node_id/" "$COMPOSE_FILE"
  else
    # 将当前node_id字符串转为数组，以便精确匹配
    IFS=',' read -r -a node_ids <<< "$current_node_id"
    node_exists=0
    
    # 检查新node_id是否已存在
    for existing_id in "${node_ids[@]}"; do
      if [ "$existing_id" = "$node_id" ]; then
        node_exists=1
        break
      fi
    done
    
    if [ $node_exists -eq 1 ]; then
      echo "该 node_id 已存在"
      read -p "按回车键返回菜单..." _
      return
    fi
    
    # 在现有 node_id 后添加新的 node_id
    new_node_id="$current_node_id,$node_id"
    sed -i "s/node_id=.*/node_id=$new_node_id/" "$COMPOSE_FILE"
  fi
  
  echo "正在重启服务以应用新配置..."
  docker compose -f "$COMPOSE_FILE" up -d
  echo "节点添加完成。"
  read -p "按回车键返回菜单..." _
}

# 删除节点
delete_node() {
  echo " >>> 删除节点..."
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  
  read -p "请输入要删除的 node_id: " node_id
  if [ -z "$node_id" ]; then
    echo "node_id 不能为空"
    read -p "按回车键返回菜单..." _
    return
  fi

  # 获取当前 node_id
  current_node_id=$(grep -oP 'node_id=\K[^ ]*' "$COMPOSE_FILE")
  
  if [ -z "$current_node_id" ]; then
    echo "当前没有配置任何 node_id"
    read -p "按回车键返回菜单..." _
    return
  fi

  # 将当前node_id字符串转为数组
  IFS=',' read -r -a node_ids <<< "$current_node_id"
  node_exists=0
  new_node_ids=()
  
  # 检查要删除的node_id是否存在，并构建新的node_id列表
  for existing_id in "${node_ids[@]}"; do
    if [ "$existing_id" = "$node_id" ]; then
      node_exists=1
    else
      new_node_ids+=("$existing_id")
    fi
  done
  
  if [ $node_exists -eq 0 ]; then
    echo "该 node_id 不存在"
    read -p "按回车键返回菜单..." _
    return
  fi

  # 将数组转回逗号分隔的字符串
  new_node_id=$(IFS=,; echo "${new_node_ids[*]}")
  
  # 如果删除后为空，则设置为空
  if [ -z "$new_node_id" ]; then
    sed -i "s/node_id=.*/node_id=/" "$COMPOSE_FILE"
  else
    sed -i "s/node_id=.*/node_id=$new_node_id/" "$COMPOSE_FILE"
  fi
  
  echo "正在重启服务以应用新配置..."
  docker compose -f "$COMPOSE_FILE" up -d
  echo "节点已删除。"
  read -p "按回车键返回菜单..." _
}

# 检查服务状态
check_services() {
  echo " >>> 检查服务状态..."
  echo "当前运行的服务："
  docker ps | grep soga
  echo ""
  echo "所有配置文件："
  ls -l /etc/soga/*/docker-compose-*.yml 2>/dev/null || echo "未找到配置文件"
  read -p "按回车键返回菜单..." _
}

# 更新soga
update_soga() {
  echo " >>> 更新 Soga..."
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  
  echo "正在更新 Soga 镜像..."
  docker compose -f "$COMPOSE_FILE" pull
  
  echo "正在重启服务..."
  docker compose -f "$COMPOSE_FILE" up -d
  
  echo "Soga 已更新至最新版本。"
  read -p "按回车键返回菜单..." _
}

# 主循环
while true; do
  enable_show_menu
  read -p "请输入选项 [0-7]: " choice
  case "$choice" in
    1) install_soga  ;; 
    2) edit_soga     ;; 
    3) restart_soga  ;; 
    4) add_node      ;; 
    5) delete_node   ;; 
    6) check_services;; 
    7) update_soga   ;;
    0) echo "退出脚本。"; exit 0 ;; 
    *) echo "无效选项，请重新输入。"; read -p "按回车键继续..." _;;
  esac
done