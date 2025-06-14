#!/bin/bash

# v2bx management script

CONFIG_FILE="/etc/V2bX/config.json"
API_USERS_FILE="/etc/V2bX/api_users.json"

# --- Helper Functions ---

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to print colored messages
print_message() {
    color=$1
    message=$2
    case $color in
        "green") echo -e "\e[32m${message}\e[0m" ;;
        "red") echo -e "\e[31m${message}\e[0m" ;;
        "yellow") echo -e "\e[33m${message}\e[0m" ;;
        *) echo "${message}" ;;
    esac
}

# --- Installation ---

ensure_api_users_file_exists() {
    if [ ! -f "$API_USERS_FILE" ]; then
        print_message "yellow" "未找到API用户文件，正在创建: $API_USERS_FILE"
        echo '{"users":[]}' > "$API_USERS_FILE"
    fi
}

uninstall_v2bx() {
    print_message "yellow" "--- 卸载 V2bX ---"
    print_message "red" "警告: 此操作将完全卸载V2bX并删除所有配置文件！"
    read -p "您确定要继续吗？ (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_message "yellow" "取消卸载操作。"
        return
    fi
    
    print_message "yellow" "正在停止V2bX服务..."
    systemctl stop v2bx 2>/dev/null || true
    systemctl disable v2bx 2>/dev/null || true
    
    print_message "yellow" "正在删除V2bX配置文件..."
    rm -rf /etc/V2bX/ 2>/dev/null || true
    
    print_message "yellow" "正在删除V2bX二进制文件..."
    rm -f /usr/local/bin/v2bx 2>/dev/null || true
    
    print_message "yellow" "正在删除V2bX服务文件..."
    rm -f /etc/systemd/system/v2bx.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    
    print_message "yellow" "正在删除V2bX日志文件..."
    rm -rf /var/log/v2bx/ 2>/dev/null || true
    
    print_message "yellow" "正在删除V2bX临时文件..."
    rm -rf /tmp/v2bx* 2>/dev/null || true
    
    print_message "green" "V2bX 卸载完成！"
    print_message "yellow" "注意: 如果您之前安装了Xray Core，它可能仍然存在。"
}

install_v2bx() {
    if ! command_exists v2bx; then
        print_message "yellow" "未找到 v2bx。正在开始安装..."
        wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh && bash install.sh
        
        # After installation, overwrite config.json with a minimal version
        if [ -f "$CONFIG_FILE" ]; then
            print_message "yellow" "安装完成。正在使用指定的最小化配置覆盖默认配置..."
            cat <<'EOF' > "$CONFIG_FILE"
{
	"Log": {
		"Level": "error",
		"Output": ""
	},
	"Cores": [
		{
			"Type": "xray",
			"Log": {
				"Level": "error",
				"AccessPath": "",
				"ErrorPath": ""
			},
			"AssetPath": "",
			"DnsConfigPath": "/etc/V2bX/dns.json",
			"RouteConfigPath": "/etc/V2bX/route.json",
			"ConnectionConfig": {
				"handshake": 4,
				"connIdle": 300,
				"uplinkOnly": 2,
				"downlinkOnly": 5,
				"statsUserUplink": true,
				"statsUserDownlink": true,
				"bufferSize": 4
			},
			"InboundConfigPath": "/etc/V2bX/custom_inbound.json",
			"OutboundConfigPath": "/etc/V2bX/custom_outbound.json"
		}
	],
	"Nodes": []
}
EOF
            print_message "green" "配置文件已更新。请使用菜单添加您的第一个节点。"
        fi
    else
        print_message "green" "v2bx 已安装。"
    fi
    cat > /etc/V2bX/dns.json <<EOF
{
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8"
    ]
  }
}
EOF

    创建 custom_outbound.json
   cat > /etc/V2bX/custom_outbound.json <<EOF
[
]
EOF

   cat > /etc/V2bX/custom_inbound.json <<EOF
[
]
EOF

    # 创建 route.json
    cat > /etc/V2bX/route.json <<EOF
{
    "rules": []
}
EOF
}

# --- Node Management ---

check_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_message "red" "错误: 在当前目录中未找到 $CONFIG_FILE。"
        print_message "red" "请在与 v2bx config.json 相同的目录中运行此脚本。"
        exit 1
    fi
}

list_nodes() {
    check_config_file
    print_message "yellow" "\n--- 当前节点 ---"
    jq -r '.Nodes[] | "ID: \(.NodeID) | 名称: \(.Name) | 类型: \(.NodeType) | ApiHost: \(.ApiHost) | ApiKey: \(.ApiKey)"' "$CONFIG_FILE"
    echo ""
}

view_config() {
    check_config_file
    print_message "yellow" "\n--- 当前配置文件内容 ---"
    cat "$CONFIG_FILE" | jq .
    echo ""
}

add_node() {
    check_config_file
    ensure_api_users_file_exists
    
    print_message "yellow" "--- 添加新节点 ---"
    
    # 获取NodeID
    read -p "输入节点ID (NodeID): " node_id
    if [ -z "$node_id" ]; then
        print_message "red" "错误: 节点ID不能为空。"
        return
    fi
    
    # 检查NodeID是否已存在
    existing_node=$(jq --argjson id "$node_id" '.Nodes[] | select(.NodeID == $id)' "$CONFIG_FILE")
    if [ -n "$existing_node" ]; then
        print_message "red" "错误: 节点ID $node_id 已存在。"
        return
    fi
    
    # 获取NodeType
    print_message "yellow" "可用的节点类型: vless, vmess, trojan, shadowsocks"
    read -p "输入节点类型 (NodeType): " node_type
    if [ -z "$node_type" ]; then
        print_message "red" "错误: 节点类型不能为空。"
        return
    fi
    
    # 验证节点类型
    case "$node_type" in
        vless|vmess|trojan|shadowsocks)
            ;;
        *)
            print_message "red" "错误: 无效的节点类型。支持的类型: vless, vmess, trojan, shadowsocks"
            return
            ;;
    esac
    
    # 列出可用的API用户
    print_message "yellow" "\n--- 可用的API用户 ---"
    api_users=$(jq -r '.users[] | .username' "$API_USERS_FILE" 2>/dev/null)
    if [ -z "$api_users" ]; then
        print_message "red" "错误: 没有找到API用户。请先在API用户管理中添加用户。"
        return
    fi
    
    echo "$api_users" | nl -w2 -s'. '
    echo ""
    
    read -p "选择API用户 (输入用户名): " selected_username
    if [ -z "$selected_username" ]; then
        print_message "red" "错误: 用户名不能为空。"
        return
    fi
    
    # 获取选定用户的API信息
    user_info=$(jq --arg name "$selected_username" '.users[] | select(.username == $name)' "$API_USERS_FILE")
    if [ -z "$user_info" ]; then
        print_message "red" "错误: 未找到用户名为 '$selected_username' 的API用户。"
        return
    fi
    
    api_host=$(echo "$user_info" | jq -r '.ApiHost')
    api_key=$(echo "$user_info" | jq -r '.ApiKey')
    
    # 创建新节点配置 - 使用基本默认值
    node_name="${node_type}_${node_id}_${selected_username}"
    new_node=$(jq -n \
        --arg node_name "$node_name" \
        --arg api_host "$api_host" \
        --arg api_key "$api_key" \
        --argjson node_id "$node_id" \
        --arg node_type "$node_type" \
        '{
            Name: $node_name,
            Core: "xray", 
            CoreName: "",
            ApiHost: $api_host,
            ApiKey: $api_key,
            NodeID: $node_id,
            NodeType: $node_type,
            Timeout: 30,
            ListenIP: "0.0.0.0",
            SendIP: "0.0.0.0",
            DeviceOnlineMinTraffic: 100,
            EnableProxyProtocol: false,
            EnableTFO: false,
            EnableDNS: true,
            DNSType: "UseIPv4",
            EnableUot: false,
            DisableIVCheck: false,
            DisableSniffing: false,
            EnableFallback: false,
            FallBackConfigs: [
                {
                    SNI: "",
                    Alpn: "",
                    Path: "",
                    Dest: "",
                    ProxyProtocolVer: 0
                }
            ]
        }')
    
    # 添加节点到配置文件
    jq ".Nodes += [$new_node]" "$CONFIG_FILE" > "tmp.$$.json"
    
    if [ $? -eq 0 ]; then
        mv "tmp.$$.json" "$CONFIG_FILE"
        print_message "green" "节点添加成功！"
        print_message "yellow" "正在重启 v2bx 以应用更改..."
        v2bx restart
    else
        print_message "red" "添加节点失败。发生错误。"
        rm -f "tmp.$$.json"
    fi
}

delete_node() {
    check_config_file
    list_nodes
    read -p "输入要删除的节点名称 (Name): " node_name_to_delete
    
    if [ -z "$node_name_to_delete" ]; then
        print_message "red" "未输入节点名称。正在中止。"
        return
    fi
    
    node_exists=$(jq --arg name "$node_name_to_delete" '.Nodes[] | select(.Name == $name)' "$CONFIG_FILE")
    if [ -z "$node_exists" ]; then
        print_message "red" "未找到名称为 '$node_name_to_delete' 的节点。"
        return
    fi
    
    jq --arg name "$node_name_to_delete" 'del(.Nodes[] | select(.Name == $name))' "$CONFIG_FILE" > "tmp.$$.json"
    
    if [ $? -eq 0 ]; then
        mv "tmp.$$.json" "$CONFIG_FILE"
        print_message "green" "名称为 '$node_name_to_delete' 的节点删除成功。"
        list_nodes
        print_message "yellow" "正在重启 v2bx 以应用更改..."
        v2bx restart
    else
        print_message "red" "删除节点失败。发生错误。"
        rm -f "tmp.$$.json"
    fi
}

# --- API User Management ---

list_api_users() {
    ensure_api_users_file_exists
    print_message "yellow" "\n--- API 用户列表 ---"
    jq -r '.users[] | "用户名: \(.username) | ApiHost: \(.ApiHost) | ApiKey: \(.ApiKey)"' "$API_USERS_FILE"
    echo ""
}

add_api_user() {
    ensure_api_users_file_exists
    print_message "yellow" "--- 添加新API用户 ---"
    read -p "输入新的用户名 (必须唯一): " username

    if [ -z "$username" ]; then
        print_message "red" "错误: 用户名不能为空。"
        return
    fi

    existing_users=$(jq -r '.users[].username' "$API_USERS_FILE")
    if echo "$existing_users" | grep -q "^${username}$"; then
        print_message "red" "错误: 用户名 '${username}' 已存在。"
        return
    fi

    read -p "输入 ApiHost [默认: http://127.0.0.1]: " api_host
    api_host=${api_host:-http://127.0.0.1}
    read -p "输入 ApiKey [默认: test]: " api_key
    api_key=${api_key:-test}

    new_user=$(jq -n --arg name "$username" --arg host "$api_host" --arg key "$api_key" \
        '{username: $name, ApiHost: $host, ApiKey: $key}')

    jq ".users += [$new_user]" "$API_USERS_FILE" > "tmp.$$.json"
    if [ $? -eq 0 ]; then
        mv "tmp.$$.json" "$API_USERS_FILE"
        print_message "green" "API用户 '${username}' 添加成功。"
        list_api_users
    else
        print_message "red" "添加API用户失败。发生错误。"
        rm -f "tmp.$$.json"
    fi
}

delete_api_user() {
    ensure_api_users_file_exists
    list_api_users
    read -p "输入要删除的API用户的用户名: " username

    if [ -z "$username" ]; then
        print_message "red" "未输入用户名。正在中止。"
        return
    fi
    
    user_exists=$(jq --arg name "$username" '.users[] | select(.username == $name)' "$API_USERS_FILE")
    if [ -z "$user_exists" ]; then
        print_message "red" "未找到用户名为 '${username}' 的用户。"
        return
    fi

    jq --arg name "$username" 'del(.users[] | select(.username == $name))' "$API_USERS_FILE" > "tmp.$$.json"
    if [ $? -eq 0 ]; then
        mv "tmp.$$.json" "$API_USERS_FILE"
        print_message "green" "API用户 '${username}' 删除成功。"
        list_api_users
    else
        print_message "red" "删除API用户失败。发生错误。"
        rm -f "tmp.$$.json"
    fi
}

api_user_menu() {
    while true; do
        echo ""
        print_message "green" "API 用户管理"
        echo "--------------------------"
        echo " 1. 添加API用户"
        echo " 2. 删除API用户"
        echo " 3. 列出所有API用户"
        echo " 4. 返回主菜单"
        echo "--------------------------"
        read -p "请输入您的选择 [1-4]: " choice

        case $choice in
            1) add_api_user ;;
            2) delete_api_user ;;
            3) list_api_users ;;
            4) return ;;
            *) print_message "red" "无效的选择，请重试。" ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
        clear
    done
}

# --- Main Menu ---

main_menu() {
    while true; do
        echo ""
        print_message "green" "V2bX 节点管理脚本"
        echo "---------------------------------"
        echo " 1. 添加节点"
        echo " 2. 删除节点"
        echo " 3. 列出所有节点"
        echo " 4. 查看当前配置"
        echo " 5. API 用户管理"
        echo " 6. 安装/重置 V2bX"
        echo " 7. 卸载 V2bX"
        echo " 8. 退出"
        echo "---------------------------------"
        read -p "请输入您的选择 [1-8]: " choice
        
        case $choice in
            1) add_node ;;
            2) delete_node ;;
            3) list_nodes ;;
            4) view_config ;;
            5) api_user_menu ;;
            6) install_v2bx ;;
            7) uninstall_v2bx ;;
            8) print_message "green" "正在退出..."; exit 0 ;;
            *) print_message "red" "无效的选择，请重试。" ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
        clear
    done
}

# --- Main Execution ---
clear
ensure_api_users_file_exists
main_menu