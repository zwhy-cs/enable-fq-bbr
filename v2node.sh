#!/bin/bash

# v2node 自动化安装与配置脚本 (初步版本)

CONFIG_FILE="/etc/v2node/config.json"

# 颜色定义
green="\032[32m"
red="\032[31m"
yellow="\032[33m"
plain="\032[0m"

# 打印信息
print_info() {
    echo -e "${green}[INFO]${plain} $1"
}

print_error() {
    echo -e "${red}[ERROR]${plain} $1"
}

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   print_error "此脚本必须以 root 身份运行！"
   exit 1
fi

# 1. 安装 v2node
install_v2node() {
    print_info "正在开始安装 v2node..."
    wget -N https://raw.githubusercontent.com/wyx2685/v2node/master/script/install.sh && bash install.sh
}

# 2. 配置 config.json
configure_v2node() {
    print_info "开始配置 v2node..."
    
    # 获取用户输入
    read -p "请输入 ApiHost (例如 http://your-panel.com): " api_host
    read -p "请输入 ApiKey: " api_key
    read -p "请输入节点 ID (NodeID): " node_id
    
    if [[ -z "$api_host" || -z "$api_key" || -z "$node_id" ]]; then
        print_error "所有配置项均为必填！"
        return 1
    fi

    # 确保目录存在
    mkdir -p /etc/v2node

    cat <<EOF > "$CONFIG_FILE"
{
  "Log": {
    "Level": "error",
    "Output": ""
  },
  "Nodes": [
    {
      "Name": "Node_$node_id",
      "ApiHost": "$api_host",
      "ApiKey": "$api_key",
      "NodeID": $node_id,
      "NodeType": "vless",
      "Timeout": 30,
      "ListenIP": "0.0.0.0",
      "SendIP": "0.0.0.0",
      "Core": "xray",
      "EnableDNS": true,
      "DNSType": "UseIPv4"
    }
  ]
}
EOF

    print_info "配置文件已写入: $CONFIG_FILE"
}

# 3. 运行逻辑
main() {
    clear
    echo "---------- v2node 自动化脚本 ----------"
    install_v2node
    configure_v2node
    
    print_info "正在尝试启动/重启 v2node 服务..."
    # 假设安装后二进制文件名为 v2node 并注册了服务
    if command -v v2node &> /dev/null; then
        v2node restart
    elif systemctl list-unit-files | grep -q v2node; then
        systemctl restart v2node
    else
        print_info "未能自动识别启动命令，请手动重启服务。"
    fi
    
    print_info "全部操作完成！"
}

main
