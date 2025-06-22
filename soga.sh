#!/bin/bash

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

# 检查并安装 jq
check_install_jq() {
  if ! command -v jq &> /dev/null; then
    echo "未检测到 jq，正在尝试安装..."
    if command -v apt-get &> /dev/null; then
      apt-get update >/dev/null && apt-get install -y jq
    elif command -v yum &> /dev/null; then
      yum install -y epel-release && yum install -y jq
    elif command -v pacman &> /dev/null; then
      pacman -Syu --noconfirm jq
    else
      echo "无法自动安装 jq，请手动安装后重试。"
      exit 1
    fi
    echo "jq 安装完成"
  fi
}

# 执行检查安装
check_install_docker
check_install_jq

SOGA_DIR="/etc/soga"
CREDENTIALS_FILE="$SOGA_DIR/credentials.json"
DEFAULT_COMPOSE_FILE="$SOGA_DIR/docker-compose.yml"
COMPOSE_FILE=""

# 初始化凭证文件
init_credentials_file() {
    mkdir -p "$SOGA_DIR"
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        echo '[]' > "$CREDENTIALS_FILE"
    fi
}
init_credentials_file

# 显示菜单
enable_show_menu() {
  clear
  echo "========================================="
  echo "        Soga 后端管理脚本               "
  echo "========================================="
  echo "1) 安装 Soga"
  echo "2) 管理API凭证"
  echo "3) 编辑 Soga 配置"
  echo "4) 重启 Soga 服务"
  echo "5) 添加节点"
  echo "6) 删除节点"
  echo "7) 检查服务状态"
  echo "8) 更新/修改 Soga 版本"
  echo "9) 删除指定 Soga 服务"
  echo "10) 一键删除全部"
  echo "11) 查看 docker-compose.yml 配置"
  echo "0) 退出"
  echo "========================================="
}

# 选择服务类型对应的 compose 文件
enable_choose_compose() {
  echo ">>> 请选择一个服务实例:"
  local service_dirs=()
  while IFS= read -r -d $'\0'; do
      local dir_name
      dir_name=$(basename "$REPLY")
      # 凭证文件不是一个服务实例，跳过它
      if [ "$dir_name" == "credentials.json" ]; then
          continue
      fi
      service_dirs+=("$dir_name")
  done < <(find "$SOGA_DIR" -mindepth 1 -maxdepth 1 -print0)

  if [ ${#service_dirs[@]} -eq 0 ]; then
      echo "未找到任何 Soga 服务实例。"
      return 1
  fi

  local i=0
  for dir in "${service_dirs[@]}"; do
      printf "%s) %s\n" "$((i+1))" "$dir"
      i=$((i+1))
  done

  read -p "请输入选择的编号: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#service_dirs[@]}" ]; then
      echo "无效的选择。"
      return 1
  fi

  local selected_instance
  selected_instance=${service_dirs[$((choice-1))]}
  COMPOSE_FILE="$SOGA_DIR/$selected_instance/docker-compose.yml"
  
  if [ ! -f "$COMPOSE_FILE" ]; then
      echo "错误: 找不到 Compose 文件: $COMPOSE_FILE"
      return 1
  fi
  
  return 0
}

# 凭证管理
add_credential() {
  read -p "请输入凭证名称 (例如 user1): " name
  if [ -z "$name" ]; then echo "名称不能为空"; return; fi
  read -p "请输入 webapi_url (含 https://、以 / 结尾): " url
  if [ -z "$url" ]; then echo "URL 不能为空"; return; fi
  read -p "请输入 webapi_key: " key
  if [ -z "$key" ]; then echo "Key 不能为空"; return; fi

  # 检查名称是否重复
  if jq -e --arg name "$name" '.[] | select(.name == $name)' "$CREDENTIALS_FILE" > /dev/null; then
    echo "错误：该名称的凭证已存在。"
    return
  fi
  
  local temp_file
  temp_file=$(mktemp)
  jq --arg name "$name" --arg url "$url" --arg key "$key" \
    '. += [{"name": $name, "url": $url, "key": $key}]' \
    "$CREDENTIALS_FILE" > "$temp_file" && mv "$temp_file" "$CREDENTIALS_FILE"
  
  echo "凭证 '$name' 已添加。"
  read -p "按回车键继续..." _
}

list_credentials() {
  echo ">>> 可用的API凭证:"
  if ! jq -e 'any' "$CREDENTIALS_FILE" >/dev/null; then
    echo "没有找到任何凭证。"
    return 1
  fi
  jq -r '.[] | .name' "$CREDENTIALS_FILE" | cat -n
  return 0
}

delete_credential() {
  if ! list_credentials; then
    read -p "按回车键继续..." _
    return
  fi
  read -p "请输入要删除的凭证编号: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then echo "无效输入"; return; fi

  local index=$((choice - 1))
  local len
  len=$(jq 'length' "$CREDENTIALS_FILE")
  if [ "$index" -lt 0 ] || [ "$index" -ge "$len" ]; then
    echo "无效的编号。"
    return
  fi
  
  local temp_file
  temp_file=$(mktemp)
  jq "del(.[$index])" "$CREDENTIALS_FILE" > "$temp_file" && mv "$temp_file" "$CREDENTIALS_FILE"
  echo "凭证已删除。"
  read -p "按回车键继续..." _
}

manage_credentials() {
  while true; do
    clear
    echo "========================================="
    echo "          API 凭证管理"
    echo "========================================="
    echo "1) 添加凭证"
    echo "2) 列出凭证"
    echo "3) 删除凭证"
    echo "0) 返回主菜单"
    echo "========================================="
    read -p "请选择一个操作: " cred_choice
    case "$cred_choice" in
      1) add_credential ;;
      2) list_credentials; echo; read -p "按回车键继续..." _ ;;
      3) delete_credential ;;
      0) break ;;
      *) echo "无效选项，请重新输入。"; read -p "按回车键继续..." _ ;;
    esac
  done
}


# 安装函数
install_soga() {
  echo " >>> 安装 Soga..."
  
  if ! list_credentials; then
    echo "没有可用的API凭证，请先添加。"
    read -p "按回车键返回菜单..." _
    return
  fi
  read -p "请选择要使用的API凭证编号: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then echo "无效输入"; read -p "按回车键返回菜单..." _; return; fi

  local index=$((choice - 1))
  local credential_data
  credential_data=$(jq -r ".[$index]" "$CREDENTIALS_FILE")
  if [ "$credential_data" == "null" ] || [ -z "$credential_data" ]; then
      echo "无效的编号。"
      read -p "按回车键返回菜单..." _
      return
  fi
  
  local webapi_url
  local webapi_key
  webapi_url=$(echo "$credential_data" | jq -r '.url')
  webapi_key=$(echo "$credential_data" | jq -r '.key')

  read -p "请输入此Soga实例的名称 (例如 v2ray-us): " instance_name
  if [ -z "$instance_name" ]; then
      echo "实例名称不能为空。"
      read -p "按回车键返回菜单..." _
      return
  fi

  read -p "请输入 server_type (如 ss/v2ray/trojan 等): " server_type
  if [ -z "$server_type" ]; then
      echo "server_type 不能为空。"
      read -p "按回车键返回菜单..." _
      return
  fi

  local service_name="${instance_name}-${server_type}"
  local container_name="$service_name"

  if [ -d "$SOGA_DIR/$service_name" ]; then
      echo "错误：服务实例 '$service_name' 已存在。"
      read -p "按回车键返回菜单..." _
      return
  fi

  if docker ps -a --format '{{.Names}}' | grep -Eq "^${container_name}$"; then
    echo "错误：容器名称 '$container_name' 已存在，请使用其他名称。"
    read -p "按回车键返回菜单..." _
    return
  fi

  read -p "请输入 Soga 版本 (默认为 latest): " soga_version
  soga_version=${soga_version:-latest}
  echo "node_id 将留空，请使用"添加节点"功能添加。"

  mkdir -p "$SOGA_DIR/$service_name"
  COMPOSE_FILE="$SOGA_DIR/$service_name/docker-compose.yml"
  cat > "$COMPOSE_FILE" << EOF
version: "3.3"

services:
  soga:
    image: vaxilu/soga:${soga_version}
    container_name: $container_name
    restart: always
    network_mode: host
    volumes:
      - /etc/soga/$service_name/:/etc/soga/
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
  echo " >>> 请选择要编辑的服务实例"
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  echo "编辑文件：$COMPOSE_FILE"
  ${EDITOR:-nano} "$COMPOSE_FILE"
  echo "配置已保存。"
  docker compose -f "$COMPOSE_FILE" up -d
  read -p "按回车键返回菜单..." _
}

# 重启服务
restart_soga() {
  echo " >>> 请选择要重启的服务实例"
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  echo "重启服务：$COMPOSE_FILE"
  docker compose -f "$COMPOSE_FILE" up -d
  echo "服务已重启。"
  read -p "按回车键返回菜单..." _
}

# 添加节点
add_node() {
  echo " >>> 添加节点到服务实例..."
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
  echo " >>> 从服务实例中删除节点..."
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
  echo "所有配置实例："
  local service_dirs=()
  while IFS= read -r -d $'\0'; do
      local dir_name
      dir_name=$(basename "$REPLY")
      if [ "$dir_name" == "credentials.json" ]; then continue; fi
      service_dirs+=("$dir_name")
  done < <(find "$SOGA_DIR" -mindepth 1 -maxdepth 1 -print0)

  if [ ${#service_dirs[@]} -eq 0 ]; then
      echo "未找到任何 Soga 配置实例。"
  else
      for dir in "${service_dirs[@]}"; do
          echo " - $dir (/etc/soga/$dir/docker-compose.yml)"
      done
  fi
  read -p "按回车键返回菜单..." _
}

# 更新soga
update_soga() {
  echo " >>> 更新 Soga..."
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi

  current_image=$(grep -oP 'image: \K[^ ]*' "$COMPOSE_FILE")
  echo "当前镜像: $current_image"
  read -p "请输入新的 Soga 版本 (留空以拉取当前版本最新镜像, 输入 'latest' 使用最新版): " new_version

  if [ -n "$new_version" ]; then
    sed -i "s|image: .*|image: vaxilu/soga:$new_version|" "$COMPOSE_FILE"
    echo "镜像已更新为 vaxilu/soga:$new_version"
  fi

  echo "正在拉取 Soga 镜像..."
  docker compose -f "$COMPOSE_FILE" pull
  
  echo "正在重启服务..."
  docker compose -f "$COMPOSE_FILE" up -d
  
  echo "Soga 更新操作完成。"
  read -p "按回车键返回菜单..." _
}

# 删除指定的 Soga 服务
delete_soga_instance() {
  echo " >>> 删除指定的 Soga 服务实例..."
  
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  
  local instance_name
  instance_name=$(basename "$(dirname "$COMPOSE_FILE")")

  read -p "!!! 警告：此操作将删除 Soga 服务实例 ($instance_name) 的配置和容器，且无法恢复。是否继续？(y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "操作已取消。"
    read -p "按回车键返回菜单..." _
    return
  fi

  echo ">>> 正在停止并删除 Soga 服务 ($instance_name)..."
  docker compose -f "$COMPOSE_FILE" down --rmi all -v --remove-orphans || echo "处理 $COMPOSE_FILE 时出错，但将继续。"

  echo ">>> 正在删除 Soga 配置目录..."
  local soga_instance_dir
  soga_instance_dir=$(dirname "$COMPOSE_FILE")
  if [ -d "$soga_instance_dir" ]; then
    rm -rf "$soga_instance_dir"
    echo "配置目录 $soga_instance_dir 已删除。"
  else
    echo "配置目录 $soga_instance_dir 未找到。"
  fi
  
  echo "Soga 服务 ($instance_name) 已成功删除。"
  read -p "按回车键返回菜单..." _
}

# 查看 docker-compose.yml 配置
view_soga_compose() {
  echo " >>> 请选择要查看的服务实例"
  if ! enable_choose_compose; then read -p "按回车键返回菜单..." _; return; fi
  echo "查看文件内容：$COMPOSE_FILE"
  echo "-----------------------------------------"
  cat "$COMPOSE_FILE"
  echo "-----------------------------------------"
  read -p "按回车键返回菜单..." _
}

# 一键删除全部
delete_all_soga() {
  read -p "!!! 警告：此操作将删除所有Soga配置和容器，且无法恢复。是否继续？(y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "操作已取消。"
    read -p "按回车键返回菜单..." _
    return
  fi

  echo ">>> 正在停止并删除所有 Soga 服务..."
  
  if [ ! -d "$SOGA_DIR" ]; then
    echo "Soga 配置目录 ($SOGA_DIR) 不存在，无需操作。"
    read -p "按回车键返回菜单..." _
    return
  fi

  # 查找所有 docker-compose 文件并停止服务
  find "$SOGA_DIR" -name "docker-compose.yml" -print0 | while IFS= read -r -d $'\0' compose_file; do
    echo "正在处理 $compose_file..."
    docker compose -f "$compose_file" down --rmi all -v --remove-orphans || echo "处理 $compose_file 时出错，但将继续。"
  done

  echo ">>> 正在删除 Soga 配置目录..."
  rm -rf "$SOGA_DIR"
  
  echo "所有 Soga 服务和配置已成功删除。"
  read -p "按回车键返回菜单..." _
}

# 主循环
while true; do
  enable_show_menu
  read -p "请输入选项 [0-11]: " choice
  case "$choice" in
    1) install_soga  ;;
    2) manage_credentials ;;
    3) edit_soga     ;; 
    4) restart_soga  ;; 
    5) add_node      ;; 
    6) delete_node   ;; 
    7) check_services;; 
    8) update_soga   ;;
    9) delete_soga_instance ;;
    10) delete_all_soga ;;
    11) view_soga_compose ;;
    0) echo "退出脚本。"; exit 0 ;; 
    *) echo "无效选项，请重新输入。"; read -p "按回车键继续..." _;;
  esac
done
