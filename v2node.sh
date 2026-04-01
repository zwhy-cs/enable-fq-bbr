#!/bin/bash

# v2node 自动化安装与配置脚本 (方案 B: 独立 API 存储版)

CONFIG_FILE="/etc/v2node/config.json"
API_INFO_FILE="/etc/v2node/api_info"

# 颜色定义
green="\033[32m"
red="\033[31m"
yellow="\033[33m"
plain="\033[0m"

# 打印信息
print_info() {
    echo -e "${green}[INFO]${plain} $1"
}

print_error() {
    echo -e "${red}[ERROR]${plain} $1"
}

print_warn() {
    echo -e "${yellow}[WARN]${plain} $1"
}

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   print_error "此脚本必须以 root 身份运行！"
   exit 1
fi

# 安装必要依赖
install_dependencies() {
    if ! command -v jq &> /dev/null; then
        print_info "正在安装 jq (JSON 处理工具)..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y jq
        elif command -v yum &> /dev/null; then
            yum install -y jq
        else
            print_error "未找到包管理器，请手动安装 jq。"
            exit 1
        fi
    fi
}

# 1. 基础安装 v2node
install_v2node() {
    print_info "正在开始安装 v2node 核心..."
    wget -N https://raw.githubusercontent.com/wyx2685/v2node/master/script/install.sh && bash install.sh
}

# 加载数据
load_api_info() {
    if [ -f "$API_INFO_FILE" ]; then
        API_HOST=$(sed -n '1p' "$API_INFO_FILE")
        API_KEY=$(sed -n '2p' "$API_INFO_FILE")
        return 0
    else
        return 1
    fi
}

# 2. 设置/初始化 API 配置
setup_api() {
    print_info "初始化 API 设置"
    read -p "请输入 ApiHost (例如 http://your-panel.com): " api_host
    read -p "请输入 ApiKey: " api_key
    
    if [[ -z "$api_host" || -z "$api_key" ]]; then
        print_error "ApiHost 和 ApiKey 不能为空！"
        return 1
    fi

    mkdir -p /etc/v2node
    echo "$api_host" > "$API_INFO_FILE"
    echo "$api_key" >> "$API_INFO_FILE"
    chmod 600 "$API_INFO_FILE"
    
    # 初始化 config.json 结构 (如果还不存在)
    if [ ! -f "$CONFIG_FILE" ]; then
        echo '{"Log": {"Level": "warning", "Output": "", "Access": "none"}, "Nodes": []}' > "$CONFIG_FILE"
    fi
    
    print_info "API 信息已保存至 $API_INFO_FILE"
}

# 3. 添加节点
add_node() {
    if ! load_api_info; then
        print_warn "未检测到 API 配置。请先输入："
        setup_api || return 1
        load_api_info
    else
        print_info "已加载 API 主机: $API_HOST"
    fi
    
    read -p "请输入要添加的节点 ID (NodeID, 多个以空格或逗号分隔): " input_ids
    if [[ -z "$input_ids" ]]; then
        print_error "NodeID 不能为空！"
        return 1
    fi

    # 替换逗号为空格，并按空格分割
    local node_ids=$(echo "$input_ids" | tr ',' ' ')
    local added_count=0

    # 确保 config.json 存在且结构正确
    if [ ! -f "$CONFIG_FILE" ]; then
        echo '{"Log": {"Level": "warning", "Output": "", "Access": "none"}, "Nodes": []}' > "$CONFIG_FILE"
    fi

    for node_id in $node_ids; do
        # 验证是否为纯数字
        if ! [[ "$node_id" =~ ^[0-9]+$ ]]; then
            print_error "无效的 NodeID: $node_id (必须为数字)，跳过。"
            continue
        fi

        # 检查 NodeID 是否已存在
        if jq -e ".Nodes[] | select(.NodeID == $node_id)" "$CONFIG_FILE" > /dev/null 2>&1; then
            print_warn "警告: NodeID $node_id 已存在于配置中。"
            read -p "是否重复添加该节点？(y/n): " confirm
            [[ "$confirm" != "y" ]] && continue
        fi

        print_info "正在添加节点: $node_id ..."

        # 构建新节点 JSON
        new_node=$(cat <<EOF
{
  "ApiHost": "$API_HOST",
  "NodeID": $node_id,
  "ApiKey": "$API_KEY",
  "Timeout": 15
}
EOF
)

        # 使用 jq 追加到 Nodes 数组
        tmp_json=$(jq ".Nodes += [$new_node]" "$CONFIG_FILE")
        if [ $? -eq 0 ]; then
            echo "$tmp_json" > "$CONFIG_FILE"
            ((added_count++))
        else
            print_error "JSON 处理失败 ($node_id)，请检查 jq 工具或配置文件格式。"
        fi
    done

    if [ $added_count -gt 0 ]; then
        print_info "共成功添加了 $added_count 个节点。"
        restart_service
    else
        print_warn "没有节点被添加。"
    fi
}

# 4. 重启服务
restart_service() {
    print_info "正在重启 v2node 服务..."
    v2node restart
}

# 5. 查看日志
view_log() {
    v2node log
}

# 6. 查看配置状态 (简略)
view_status() {
    if [ -f "$API_INFO_FILE" ]; then
        load_api_info
        echo -e "全局 API: ${yellow}$API_HOST${plain}"
    fi
    if [ -f "$CONFIG_FILE" ]; then
        print_info "当前已配置的节点列表:"
        jq -r '.Nodes[] | "ID: \(.NodeID)"' "$CONFIG_FILE"
    else
        print_error "配置文件不存在。"
    fi
}

# 7. 查看原始配置文件
view_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        print_info "文件路径: $CONFIG_FILE"
        echo "-------------------------------------------"
        if command -v jq &> /dev/null; then
            jq . "$CONFIG_FILE"
        else
            cat "$CONFIG_FILE"
        fi
        echo "-------------------------------------------"
    else
        print_error "配置文件不存在。"
    fi
}

# 运行逻辑
main_menu() {
    install_dependencies
    while true; do
        echo -e "\n---------- v2node 自动化管理脚本 ----------"
        echo "1. 安装 v2node 核心"
        echo "2. 初始化/设置 API (ApiHost/ApiKey)"
        echo "3. 添加新节点 (需先完成选项 2)"
        echo "4. 重启 v2node 服务"
        echo "5. 查看 v2node 日志"
        echo "6. 查看节点运行状态 (简略)"
        echo "7. 查看完整配置文件 (JSON)"
        echo "0. 退出脚本"
        echo "-------------------------------------------"
        read -p "请选择操作 [0-7]: " choice
        
        case $choice in
            1) install_v2node ;;
            2) setup_api ;;
            3) add_node ;;
            4) restart_service ;;
            5) view_log ;;
            6) view_status ;;
            7) view_config_file ;;
            0) exit 0 ;;
            *) echo "无效选择，请重新输入。" ;;
        esac
    done
}

main_menu
