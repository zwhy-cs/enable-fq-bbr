#!/bin/bash

# 定义XrayR配置文件路径
CONFIG_FILE="/etc/XrayR/config.yml"

# 目录栏
echo "--------------------------------------------------"
echo " XrayR 管理脚本"
echo "--------------------------------------------------"
echo "1. 安装 XrayR"
echo "2. 重启 XrayR"
echo "3. 添加节点"
echo "4. 删除节点" # 新增选项
echo "5. 一键删除所有XrayR相关文件和配置" # 原来的 5 变为 6
echo "6. 查看当前XrayR配置" # 新增查看配置选项
echo "7. 使用nano编辑config.yml" # 新增nano编辑选项
echo "8. 更新 XrayR" # 新增更新选项
echo "10. 修改节点限速" # 新增限速修改选项
echo "--------------------------------------------------"
echo "9. 退出" # 退出移到最后一行
read -p "请选择操作： " choice

# 安装 XrayR
install_xrayr() {
    echo "正在安装 XrayR..."
    bash <(curl -Ls https://raw.githubusercontent.com/XrayR-project/XrayR-release/master/install.sh)
    # 修改 config.yml 配置文件
    echo "正在初始化 config.yml 文件..."
    # 确保目录存在
    mkdir -p /etc/XrayR
    # 写入基础配置，如果文件已存在则覆盖（安装时通常需要初始化）
    echo -e "Log:\n  Level: warning # Log level: none, error, warning, info, debug\n  AccessPath: # /etc/XrayR/access.Log\n  ErrorPath: # /etc/XrayR/error.log\nDnsConfigPath: # /etc/XrayR/dns.json # Path to dns config, check https://xtls.github.io/config/dns.html for help\nRouteConfigPath: /etc/XrayR/route.json # Path to route config, check https://xtls.github.io/config/routing.html for help\nInboundConfigPath: /etc/XrayR/custom_inbound.json # Path to custom inbound config, check https://xtls.github.io/config/inbound.html for help\nOutboundConfigPath: /etc/XrayR/custom_outbound.json # Path to custom outbound config, check https://xtls.github.io/config/outbound.html for help\nConnectionConfig:\n  Handshake: 4 # Handshake time limit, Second\n  ConnIdle: 600 # Connection idle time limit, Second\n  UplinkOnly: 2 # Time limit when the connection downstream is closed, Second\n  DownlinkOnly: 4 # Time limit when the connection is closed after the uplink is closed, Second\n  BufferSize: 64 # The internal cache size of each connection, kB\nNodes:" > $CONFIG_FILE
    echo "XrayR 安装并初始化配置文件完成。"

    # 覆盖 route.json
    cat > /etc/XrayR/route.json <<EOF
{
    "rules": [
      {
        "inboundTag": [
          "dokodemo-in"
        ],
        "domain": [
          "speed.cloudflare.com"
        ],
        "outboundTag": "direct"
      },
      {
        "inboundTag": [
          "dokodemo-in"
        ],
        "outboundTag": "block"
      }
    ]
}
EOF

    # 覆盖 custom_inbound.json
    cat > /etc/XrayR/custom_inbound.json <<EOF
[
  {
    "tag": "dokodemo-in",
    "port": 443,
    "protocol": "dokodemo-door",
    "settings": {
        "address": "127.0.0.1",
        "port": 4431,  
        "network": "tcp"
    },
    "sniffing": {
        "enabled": true,
        "destOverride": [
            "tls"
        ],
        "routeOnly": true
    }
  }
]
EOF

    # 覆盖 custom_outbound.json
    cat > /etc/XrayR/custom_outbound.json <<EOF
[
  {
    "protocol": "freedom",
    "tag": "direct"
  },
  {
    "protocol": "blackhole",
    "tag": "block"
  }
]
EOF
}

# 重启 XrayR
restart_xrayr() {
    echo "正在重启 XrayR..."
    # 检查 XrayR 命令是否存在
    if command -v XrayR &> /dev/null; then
        XrayR restart
        echo "XrayR 已重启。"
    else
        echo "错误：未找到 XrayR 命令。请确保 XrayR 已正确安装并配置在 PATH 中。"
        # 尝试使用 systemctl (如果存在)
        if command -v systemctl &> /dev/null; then
            echo "尝试使用 systemctl 重启 XrayR 服务..."
            systemctl restart XrayR
            if systemctl is-active --quiet XrayR; then
                echo "XrayR 服务已通过 systemctl 重启。"
            else
                echo "使用 systemctl 重启 XrayR 服务失败。"
            fi
        else
             echo "也未找到 systemctl 命令。无法自动重启 XrayR。"
        fi
    fi
}

# 添加节点到 config.yml
add_node() {
    echo "请输入要添加的节点信息："
    read -p "节点 ID (NodeID): " node_id
    # 对 NodeID 进行简单验证，确保不为空
    if [[ -z "$node_id" ]]; then
        echo "错误：节点 ID 不能为空。"
        return 1
    fi
    read -p "选择节点类型 (NodeType: V2ray/Vmess/Vless/Shadowsocks/Trojan): " node_type
    # 对 NodeType 进行简单验证
    case "$node_type" in
        V2ray|Vmess|Vless|Shadowsocks|Trojan)
            ;;
        *)
            echo "错误：无效的节点类型 '$node_type'。请输入 V2ray, Vmess, Vless, Shadowsocks 或 Trojan。"
            return 1
            ;;
    esac

    # 新增：手动输入ApiKey
    read -p "请输入面板ApiKey: " api_key
    if [[ -z "$api_key" ]]; then
        echo "错误：ApiKey 不能为空。"
        return 1
    fi

    # 新增：是否设置SpeedLimit
    read -p "是否要设置限速（SpeedLimit）？(y/n): " set_speed_limit
    if [[ "$set_speed_limit" == "y" ]]; then
        read -p "请输入限速值（单位：Mbps，0为不限制）: " speed_limit
        if [[ ! "$speed_limit" =~ ^[0-9]+$ ]]; then
            echo "错误：限速值必须为数字。"
            return 1
        fi
    else
        speed_limit=0
    fi

    # 如果是Vless，输入端口并修改custom_inbound.json
    if [[ "$node_type" == "Vless" ]]; then
        read -p "请输入要转发到的端口（将写入 /etc/XrayR/custom_inbound.json 的 settings.port）: " vless_port
        if [[ ! "$vless_port" =~ ^[0-9]+$ ]]; then
            echo "错误：端口必须为数字。"
            return 1
        fi
        # 用 sed 替换 custom_inbound.json 里的 "port": xxx
        sed -i '/"address": "127.0.0.1",/{n;s/"port": *[0-9]\+,/"port": '"$vless_port"',/}' /etc/XrayR/custom_inbound.json
        echo "已将 /etc/XrayR/custom_inbound.json 的 settings.port 修改为 $vless_port"
    fi

    read -p "是否启用Reality (y/n): " enable_reality

    # 根据是否启用Reality来设置其他参数
    if [[ "$enable_reality" == "y" ]]; then
        enable_vless=true
        disable_local_reality=true
        enable_reality_flag=true # 使用不同的变量名以区分输入的 "y/n"
    else
        enable_vless=false
        disable_local_reality=false
        enable_reality_flag=false
    fi

    echo "正在添加节点..."

    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误：配置文件 $CONFIG_FILE 不存在。请先执行安装或手动创建。"
        return 1
    fi

    # 检查 Nodes: 关键字是否存在，如果不存在则添加
    if ! grep -q "^Nodes:" "$CONFIG_FILE"; then
        echo -e "\nNodes:" >> "$CONFIG_FILE"
        echo "已在配置文件末尾添加 'Nodes:' 关键字。"
    fi

    # 使用 cat 和 EOF 将节点配置追加到 config.yml
    # 注意：这里的缩进非常重要，YAML 对缩进敏感
    # 每个节点块以 '  - PanelType:' 开始（前面有两个空格）
    cat >> $CONFIG_FILE <<EOF
  - PanelType: "NewV2board" # Panel type: SSpanel, NewV2board, PMpanel, Proxypanel, V2RaySocks, GoV2Panel, BunPanel
    ApiConfig:
      ApiHost: "https://xb.zwhy.cc"
      ApiKey: "$api_key"
      NodeID: $node_id
      NodeType: $node_type # Node type: V2ray, Vmess, Vless, Shadowsocks, Trojan, Shadowsocks-Plugin
      Timeout: 30 # Timeout for the api request
      EnableVless: $enable_vless # Enable Vless for V2ray Type
      VlessFlow: "xtls-rprx-vision" # Only support vless
      SpeedLimit: $speed_limit # Mbps, Local settings will replace remote settings, 0 means disable
      DeviceLimit: 0 # Local settings will replace remote settings, 0 means disable
      RuleListPath: # /etc/XrayR/rulelist Path to local rulelist file
      DisableCustomConfig: false # disable custom config for sspanel
    ControllerConfig:
      ListenIP: 0.0.0.0 # IP address you want to listen
      SendIP: 0.0.0.0 # IP address you want to send pacakage
      UpdatePeriodic: 60 # Time to update the nodeinfo, how many sec.
      EnableDNS: false # Use custom DNS config, Please ensure that you set the dns.json well
      DNSType: AsIs # AsIs, UseIP, UseIPv4, UseIPv6, DNS strategy
      EnableProxyProtocol: false # Only works for WebSocket and TCP
      AutoSpeedLimitConfig:
        Limit: 0 # Warned speed. Set to 0 to disable AutoSpeedLimit (mbps)
        WarnTimes: 0 # After (WarnTimes) consecutive warnings, the user will be limited. Set to 0 to punish overspeed user immediately.
        LimitSpeed: 0 # The speedlimit of a limited user (unit: mbps)
        LimitDuration: 0 # How many minutes will the limiting last (unit: minute)
      GlobalDeviceLimitConfig:
        Enable: false # Enable the global device limit of a user
        RedisNetwork: tcp # Redis protocol, tcp or unix
        RedisAddr: 127.0.0.1:6379 # Redis server address, or unix socket path
        RedisUsername: # Redis username
        RedisPassword: YOUR PASSWORD # Redis password
        RedisDB: 0 # Redis DB
        Timeout: 5 # Timeout for redis request
        Expiry: 60 # Expiry time (second)
      EnableFallback: false # Only support for Trojan and Vless
      FallBackConfigs:  # Support multiple fallbacks
        - SNI: # TLS SNI(Server Name Indication), Empty for any
          Alpn: # Alpn, Empty for any
          Path: # HTTP PATH, Empty for any
          Dest: 80 # Required, Destination of fallback, check https://xtls.github.io/config/features/fallback.html for details.
          ProxyProtocolVer: 0 # Send PROXY protocol version, 0 for disable
      DisableLocalREALITYConfig: $disable_local_reality  # disable local reality config
      EnableREALITY: $enable_reality_flag # Enable REALITY
      REALITYConfigs:
        Show: true # Show REALITY debug
        Dest: www.amazon.com:443 # Required, Same as fallback
        ProxyProtocolVer: 0 # Send PROXY protocol version, 0 for disable
        ServerNames: # Required, list of available serverNames for the client, * wildcard is not supported at the moment.
          - www.amazon.com
        PrivateKey: YOUR_PRIVATE_KEY # Required, execute './XrayR x25519' to generate.
        MinClientVer: # Optional, minimum version of Xray client, format is x.y.z.
        MaxClientVer: # Optional, maximum version of Xray client, format is x.y.z.
        MaxTimeDiff: 0 # Optional, maximum allowed time difference, unit is in milliseconds.
        ShortIds: # Required, list of available shortIds for the client, can be used to differentiate between different clients.
          - ""
          - 0123456789abcdef
      CertConfig:
        CertMode: none # Option about how to get certificate: none, file, http, tls, dns. Choose "none" will forcedly disable the tls config.
        CertDomain: "node1.test.com" # Domain to cert
        CertFile: /etc/XrayR/cert/node1.test.com.cert # Provided if the CertMode is file
        KeyFile: /etc/XrayR/cert/node1.test.com.key
        Provider: alidns # DNS cert provider, Get the full support list here: https://go-acme.github.io/lego/dns/
        Email: test@me.com
        DNSEnv: # DNS ENV option used by DNS provider
          ALICLOUD_ACCESS_KEY: aaa
          ALICLOUD_SECRET_KEY: bbb
EOF

    # 提示用户添加成功
    echo "节点 (ID: $node_id, Type: $node_type) 已成功添加到 $CONFIG_FILE 文件中！"
    # 重启 XrayR 使配置生效
    restart_xrayr
}

delete_node() {
    echo "----------------------------------------"
    read -p "请输入要删除的节点的 NodeID: " TARGET_NODE_ID
    read -p "请输入要删除的节点的类型 (NodeType: V2ray/Vmess/Vless/Shadowsocks/Trojan): " TARGET_NODE_TYPE

    if [[ -z "$TARGET_NODE_ID" ]] || [[ -z "$TARGET_NODE_TYPE" ]]; then
        echo "错误：NodeID 和 NodeType 不能为空。"
        return
    fi

    # 传递给 awk 的环境变量
    export TARGET_NODE_ID
    export TARGET_NODE_TYPE # awk 内部会处理大小写

    echo "正在查找并准备删除节点 (ID: ${TARGET_NODE_ID}, Type: ${TARGET_NODE_TYPE})..."

    local temp_file=$(mktemp)
    local stderr_file=$(mktemp) # 临时文件捕获 stderr
    local found_node=0 # 初始化为 0

    # --- AWK 处理配置文件，输出到临时文件，错误输出到 stderr_file ---
    awk '
    function process_buffer() {
        if (buffer != "") {
            id_pattern = "^[[:space:]]*NodeID:[[:space:]]*" ENVIRON["TARGET_NODE_ID"] "[[:space:]]*$"
            target_type_lower = tolower(ENVIRON["TARGET_NODE_TYPE"])
            type_pattern_lower = "^[[:space:]]*nodetype:[[:space:]]*\"?" target_type_lower "\"?([[:space:]]+#.*|[[:space:]]*$)"
            split(buffer, lines, "\n"); match_id = 0; match_type = 0
            for (i in lines) {
                current_line = lines[i]; current_line_lower = tolower(current_line)
                if (current_line ~ id_pattern) { match_id = 1 }
                if (current_line_lower ~ type_pattern_lower) { match_type = 1 }
            }
            if (match_id && match_type) { found_node_flag = 1 } else { print buffer }
            buffer = ""
        }
    }
    BEGIN { buffer = ""; in_block = 0; found_node_flag = 0 }
    /^  - PanelType:/ { process_buffer(); buffer = $0; in_block = 1; next }
    in_block { buffer = buffer "\n" $0; next }
    { print }
    END {
        process_buffer()
        if (found_node_flag) { print "__NODE_FOUND_AND_DELETED__" > "/dev/stderr" }
        else { print "__NODE_NOT_FOUND__" > "/dev/stderr" }
    }
    ' "$CONFIG_FILE" > "$temp_file" 2> "$stderr_file"
    # --- AWK 结束 ---

    # --- 检查 stderr 文件内容 ---
    if grep -q "__NODE_FOUND_AND_DELETED__" "$stderr_file"; then
        found_node=1
    fi
    rm "$stderr_file" # 清理 stderr 文件
    # --- 检查结束 ---

    # --- 根据是否找到节点执行操作 ---
    if [ "$found_node" -eq 1 ]; then
        echo "已在配置文件中找到匹配的节点。"
        echo "--- 将要删除的节点内容 ---"
        # 再次用 awk 仅打印匹配的块以供预览
        awk '
        function process_buffer() {
            if (buffer != "") {
                id_pattern = "^[[:space:]]*NodeID:[[:space:]]*" ENVIRON["TARGET_NODE_ID"] "[[:space:]]*$"
                target_type_lower = tolower(ENVIRON["TARGET_NODE_TYPE"])
                type_pattern_lower = "^[[:space:]]*nodetype:[[:space:]]*\"?" target_type_lower "\"?([[:space:]]+#.*|[[:space:]]*$)"
                split(buffer, lines, "\n"); match_id = 0; match_type = 0
                for (i in lines) {
                    current_line = lines[i]; current_line_lower = tolower(current_line)
                    if (current_line ~ id_pattern) { match_id = 1 }
                    if (current_line_lower ~ type_pattern_lower) { match_type = 1 }
                }
                if (match_id && match_type) { print buffer } # 只打印匹配的块
                buffer = ""
            }
        }
        BEGIN { buffer = ""; in_block = 0 }
        /^  - PanelType:/ { process_buffer(); buffer = $0; in_block = 1; next }
        in_block { buffer = buffer "\n" $0; next }
        END { process_buffer() }
        ' "$CONFIG_FILE"
        echo "---------------------------"

        read -p "确认删除此节点吗? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            mv "$temp_file" "$CONFIG_FILE"
            echo "节点已从 $CONFIG_FILE 删除。"
            read -p "是否需要重启 XrayR 服务以应用更改? (y/n): " restart_confirm
            if [[ "$restart_confirm" == "y" ]]; then
                systemctl restart xrayr
                echo "XrayR 服务已重启。"
            else
                echo "请稍后手动重启 XrayR 服务: systemctl restart xrayr"
            fi
        else
            echo "操作已取消。"
            rm "$temp_file" # 取消操作，删除临时文件
        fi
    else
        echo "未在配置文件中找到匹配的节点 (ID: ${TARGET_NODE_ID}, Type: ${TARGET_NODE_TYPE})。"
        rm "$temp_file" # 未找到节点，删除临时文件
    fi
}

# 查看 config.yml 配置内容
view_config() {
    echo "---------------- 当前 XrayR 配置 ----------------"
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
    else
        echo "未找到配置文件 $CONFIG_FILE"
    fi
    echo "--------------------------------------------------"
}

# 一键删除所有XrayR相关文件和配置
remove_all_xrayr() {
    echo "警告：即将删除所有XrayR相关文件和配置！"
    read -p "确定要继续吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        echo "正在停止 XrayR 服务..."
        systemctl stop XrayR 2>/dev/null
        systemctl disable XrayR 2>/dev/null
        # 尝试使用 XrayR 命令停止 (如果 systemctl 失败或不存在)
        if command -v XrayR &> /dev/null; then
            XrayR stop 2>/dev/null
        fi
        echo "正在删除 XrayR 文件和目录..."
        rm -rf /etc/XrayR
        rm -rf /usr/local/XrayR
        rm -f /etc/systemd/system/XrayR.service
        echo "正在重新加载 systemd 配置..."
        systemctl daemon-reload 2>/dev/null
        echo "所有XrayR相关文件和配置已删除。"
    else
        echo "操作已取消。"
    fi
}

# 使用nano编辑config.yml
edit_config() {
    echo "正在使用nano编辑 $CONFIG_FILE ..."
    # 检查nano是否安装
    if ! command -v nano &> /dev/null; then
        echo "未检测到nano，正在安装..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y nano
        elif command -v yum &> /dev/null; then
            yum install -y nano
        else
            echo "无法自动安装nano，请手动安装。"
            return 1
        fi
    fi
    nano "$CONFIG_FILE"
}

# 更新 XrayR
update_xrayr() {
    echo "正在更新 XrayR..."
    if command -v XrayR &> /dev/null; then
        XrayR update
        echo "XrayR 已完成更新。"
    else
        echo "错误：未找到 XrayR 命令。请确保 XrayR 已正确安装。"
    fi
}

# 修改节点限速
modify_speed_limit() {
    echo "----------------------------------------"
    read -p "请输入要修改限速的节点 NodeID: " TARGET_NODE_ID
    read -p "请输入节点类型 (NodeType: V2ray/Vmess/Vless/Shadowsocks/Trojan): " TARGET_NODE_TYPE
    read -p "请输入新的限速值（单位：Mbps，0为不限制）: " NEW_SPEED_LIMIT

    if [[ -z "$TARGET_NODE_ID" ]] || [[ -z "$TARGET_NODE_TYPE" ]] || [[ ! "$NEW_SPEED_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "错误：NodeID、NodeType 不能为空，限速值必须为数字。"
        return
    fi

    export TARGET_NODE_ID
    export TARGET_NODE_TYPE
    export NEW_SPEED_LIMIT

    local temp_file=$(mktemp)
    local stderr_file=$(mktemp)
    local found_node=0

    awk '
    function process_buffer() {
        if (buffer != "") {
            id_pattern = "^[[:space:]]*NodeID:[[:space:]]*" ENVIRON["TARGET_NODE_ID"] "[[:space:]]*$"
            target_type_lower = tolower(ENVIRON["TARGET_NODE_TYPE"])
            type_pattern_lower = "^[[:space:]]*nodetype:[[:space:]]*\"?" target_type_lower "\"?([[:space:]]+#.*|[[:space:]]*$)"
            split(buffer, lines, "\n"); match_id = 0; match_type = 0
            for (i in lines) {
                current_line = lines[i]; current_line_lower = tolower(current_line)
                if (current_line ~ id_pattern) { match_id = 1 }
                if (current_line_lower ~ type_pattern_lower) { match_type = 1 }
            }
            if (match_id && match_type) {
                found_node_flag = 1
                for (i in lines) {
                    if (lines[i] ~ /^[[:space:]]*SpeedLimit:/) {
                        print gensub(/SpeedLimit: .*/, "SpeedLimit: " ENVIRON["NEW_SPEED_LIMIT"] " # Mbps, Local settings will replace remote settings, 0 means disable", 1, lines[i])
                    } else {
                        print lines[i]
                    }
                }
            } else {
                for (i in lines) print lines[i]
            }
            buffer = ""
        }
    }
    BEGIN { buffer = ""; in_block = 0; found_node_flag = 0 }
    /^  - PanelType:/ { process_buffer(); buffer = $0; in_block = 1; next }
    in_block { buffer = buffer "\n" $0; next }
    { print }
    END {
        process_buffer()
        if (found_node_flag) { print "__NODE_FOUND_AND_MODIFIED__" > "/dev/stderr" }
        else { print "__NODE_NOT_FOUND__" > "/dev/stderr" }
    }
    ' "$CONFIG_FILE" > "$temp_file" 2> "$stderr_file"

    if grep -q "__NODE_FOUND_AND_MODIFIED__" "$stderr_file"; then
        mv "$temp_file" "$CONFIG_FILE"
        echo "节点 (ID: $TARGET_NODE_ID, Type: $TARGET_NODE_TYPE) 的限速已修改为 $NEW_SPEED_LIMIT Mbps。"
        read -p "是否需要重启 XrayR 服务以应用更改? (y/n): " restart_confirm
        if [[ "$restart_confirm" == "y" ]]; then
            XrayR restart
            echo "XrayR 服务已重启。"
        else
            echo "请稍后手动重启 XrayR 服务: XrayR restart"
        fi
    else
        echo "未找到匹配的节点 (ID: $TARGET_NODE_ID, Type: $TARGET_NODE_TYPE)。"
        rm "$temp_file"
    fi
    rm "$stderr_file"
}

# 根据用户选择执行相应的操作
case $choice in
    1)
        install_xrayr
        ;;
    2)
        restart_xrayr
        ;;
    3)
        add_node
        ;;
    4)
        delete_node
        ;;
    5)
        remove_all_xrayr
        ;;
    6)
        view_config
        ;;
    7)
        edit_config
        ;;
    8)
        update_xrayr
        ;;
    9)
        echo "退出脚本。"
        exit 0
        ;;
    10)
        modify_speed_limit
        ;;
    *)
        echo "无效选项，退出脚本。"
        exit 1
        ;;
esac

exit 0
