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
echo "5. 退出"
echo "6. 一键删除所有XrayR相关文件和配置" # 原来的 5 变为 6
echo "--------------------------------------------------"
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
    echo -e "Log:\n  Level: warning # Log level: none, error, warning, info, debug\n  AccessPath: # /etc/XrayR/access.Log\n  ErrorPath: # /etc/XrayR/error.log\nDnsConfigPath: # /etc/XrayR/dns.json # Path to dns config, check https://xtls.github.io/config/dns.html for help\nRouteConfigPath: # /etc/XrayR/route.json # Path to route config, check https://xtls.github.io/config/routing.html for help\nInboundConfigPath: # /etc/XrayR/custom_inbound.json # Path to custom inbound config, check https://xtls.github.io/config/inbound.html for help\nOutboundConfigPath: # /etc/XrayR/custom_outbound.json # Path to custom outbound config, check https://xtls.github.io/config/outbound.html for help\nConnectionConfig:\n  Handshake: 4 # Handshake time limit, Second\n  ConnIdle: 30 # Connection idle time limit, Second\n  UplinkOnly: 2 # Time limit when the connection downstream is closed, Second\n  DownlinkOnly: 4 # Time limit when the connection is closed after the uplink is closed, Second\n  BufferSize: 64 # The internal cache size of each connection, kB\nNodes:" > $CONFIG_FILE
    echo "XrayR 安装并初始化配置文件完成。"
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
            ;; # 类型有效
        *)
            echo "错误：无效的节点类型 '$node_type'。请输入 V2ray, Vmess, Vless, Shadowsocks 或 Trojan。"
            return 1
            ;;
    esac
    read -p "是否启用Reality (yes/no): " enable_reality

    # 根据是否启用Reality来设置其他参数
    if [[ "$enable_reality" == "yes" ]]; then
        enable_vless=true
        disable_local_reality=true
        enable_reality_flag=true # 使用不同的变量名以区分输入的 "yes/no"
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
      ApiKey: "lzi0V41No3lVqnX9sYiGcnycy"
      NodeID: $node_id
      NodeType: $node_type # Node type: V2ray, Vmess, Vless, Shadowsocks, Trojan, Shadowsocks-Plugin
      Timeout: 30 # Timeout for the api request
      EnableVless: $enable_vless # Enable Vless for V2ray Type
      VlessFlow: "xtls-rprx-vision" # Only support vless
      SpeedLimit: 0 # Mbps, Local settings will replace remote settings, 0 means disable
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
        CertMode: dns # Option about how to get certificate: none, file, http, tls, dns. Choose "none" will forcedly disable the tls config.
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

# --- 新增：删除节点功能 ---
delete_node() {
    echo "请输入要删除的节点信息："
    read -p "节点 ID (NodeID): " node_id_to_delete
    # 验证 NodeID
    if [[ -z "$node_id_to_delete" ]]; then
        echo "错误：节点 ID 不能为空。"
        return 1
    fi
    read -p "节点类型 (NodeType: V2ray/Vmess/Vless/Shadowsocks/Trojan): " node_type_to_delete
    # 验证 NodeType
    case "$node_type_to_delete" in
        V2ray|Vmess|Vless|Shadowsocks|Trojan)
            ;; # 类型有效
        *)
            echo "错误：无效的节点类型 '$node_type_to_delete'。请输入 V2ray, Vmess, Vless, Shadowsocks 或 Trojan。"
            return 1
            ;;
    esac

    echo "正在查找并准备删除节点 (ID: $node_id_to_delete, Type: $node_type_to_delete)..."

    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误：配置文件 $CONFIG_FILE 不存在。"
        return 1
    fi

    # 使用 awk 处理 YAML 文件来删除匹配的节点块
    # 逻辑：
    # 1. 逐行读取文件。
    # 2. 当遇到以 '  - PanelType:' 开头的行时，认为是一个新的节点块的开始。
    # 3. 处理上一个缓存的块：检查缓存块中是否同时包含目标 NodeID 和 NodeType。
    # 4. 如果上一个块不包含目标 ID 和 Type，则打印该块。
    # 5. 开始缓存新的块。
    # 6. 如果当前行不是块的开始，且我们在一个块内，则将该行追加到缓存。
    # 7. 如果当前行不在块内（例如文件头部的配置），则直接打印。
    # 8. 文件结束时，处理最后一个缓存的块。

    local temp_file=$(mktemp) # 创建临时文件
    local found_node=0 # 标记是否找到了要删除的节点

    # 将 NodeID 和 NodeType 导出为环境变量，以便 awk 可以访问
    export TARGET_NODE_ID="$node_id_to_delete"
    export TARGET_NODE_TYPE="$node_type_to_delete"


    awk '
    # 函数：处理缓存的块
    function process_buffer() {
        if (buffer != "") {
            # ID 模式保持不变
            id_pattern = "^[[:space:]]*NodeID:[[:space:]]*" ENVIRON["TARGET_NODE_ID"] "[[:space:]]*$"
            # NodeType 模式 (修正版): 匹配键值对，允许后面有空格、注释或直接是行尾
            target_type_lower = tolower(ENVIRON["TARGET_NODE_TYPE"])
            # 修正后的模式：匹配到类型值后，允许后面是空格+注释(#...) 或者 直接是行尾(可能带空格)
            type_pattern_lower = "^[[:space:]]*nodetype:[[:space:]]*\"?" target_type_lower "\"?([[:space:]]+#.*|[[:space:]]*$)"

            split(buffer, lines, "\n")
            match_id = 0
            match_type = 0

            # --- DEBUG START (可以保留或删除) ---
            # print "--- Checking Buffer ---" > "/dev/stderr"
            # print buffer > "/dev/stderr"
            # print "Target ID: [" ENVIRON["TARGET_NODE_ID"] "], Target Type (lower): [" target_type_lower "]" > "/dev/stderr"
            # print "ID Pattern: [" id_pattern "]" > "/dev/stderr"
            # print "Type Pattern (lower): [" type_pattern_lower "]" > "/dev/stderr"
            # --- DEBUG END ---

            for (i in lines) {
                current_line = lines[i]
                current_line_lower = tolower(current_line)
                # --- DEBUG START (可以保留或删除) ---
                # print "  Line " i ": [" current_line "]" > "/dev/stderr"
                # --- DEBUG END ---

                if (current_line ~ id_pattern) {
                    # --- DEBUG START (可以保留或删除) ---
                    # print "    -> ID Matched!" > "/dev/stderr"
                    # --- DEBUG END ---
                    match_id = 1
                }
                # 使用修正后的 type_pattern_lower 进行匹配
                if (current_line_lower ~ type_pattern_lower) {
                     # --- DEBUG START (可以保留或删除) ---
                     # print "    -> Type Matched (case-insensitive)!" > "/dev/stderr"
                     # --- DEBUG END ---
                     match_type = 1
                }
            }

            if (match_id && match_type) {
                 found_node_flag = 1
                 # --- DEBUG START (可以保留或删除) ---
                 # print ">>> Block Matched! Deleting." > "/dev/stderr"
                 # --- DEBUG END ---
                 # 匹配成功，不打印 buffer (即删除)
            } else {
                 # --- DEBUG START (可以保留或删除) ---
                 # print "<<< Block Not Matched. Keeping." > "/dev/stderr"
                 # --- DEBUG END ---
                 print buffer # 块不匹配，打印到标准输出 (即临时文件)
            }
            # --- DEBUG START (可以保留或删除) ---
            # print "--- Buffer Processed ---" > "/dev/stderr"
            # --- DEBUG END ---
            buffer = "" # 清空缓存
        }
    }

    # 主处理逻辑 (保持不变)
    BEGIN { buffer = ""; in_block = 0; found_node_flag = 0 }
    /^  - PanelType:/ { process_buffer(); buffer = $0; in_block = 1; next }
    in_block { buffer = buffer "\n" $0; next }
    { print }
    END {
        process_buffer()
        if (found_node_flag) { print "__NODE_FOUND_AND_DELETED__" > "/dev/stderr" }
        else { print "__NODE_NOT_FOUND__" > "/dev/stderr" }
    }
    ' "$CONFIG_FILE" > "$temp_file" 2> >(tee /dev/tty | grep -q "__NODE_FOUND_AND_DELETED__" && found_node=1)

# --- 后续的 if [ "$found_node" -eq 1 ]; then ... else ... fi 不变 ---



    if [ "$found_node" -eq 1 ]; then
        echo "找到并已从临时配置中移除节点 (ID: $node_id_to_delete, Type: $node_type_to_delete)。"
        # 可选：显示更改前后的差异
        # echo "配置更改预览 (diff):"
        # diff -u "$CONFIG_FILE" "$temp_file"

        read -p "确认要应用更改并覆盖原配置文件吗？(yes/no): " confirm_delete
        if [[ "$confirm_delete" == "yes" ]]; then
            # 备份原配置文件
            cp "$CONFIG_FILE" "$CONFIG_FILE.bak_$(date +%Y%m%d_%H%M%S)"
            echo "原配置文件已备份为 $CONFIG_FILE.bak_..."
            # 用临时文件覆盖原文件
            mv "$temp_file" "$CONFIG_FILE"
            echo "节点已成功删除。"
            # 重启 XrayR 使配置生效
            restart_xrayr
        else
            echo "操作已取消，未修改配置文件。"
            rm "$temp_file" # 删除临时文件
        fi
    else
        echo "未在配置文件中找到匹配的节点 (ID: $node_id_to_delete, Type: $node_type_to_delete)。"
        rm "$temp_file" # 删除临时文件
    fi

    # 清理环境变量
    unset TARGET_NODE_ID
    unset TARGET_NODE_TYPE
}


# 一键删除所有XrayR相关文件和配置
remove_all_xrayr() {
    echo "警告：即将删除所有XrayR相关文件和配置！"
    read -p "确定要继续吗？(yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
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
    4) # 新增的删除选项
        delete_node
        ;;
    5) # 原来的 4 变为 5
        echo "退出脚本。"
        exit 0
        ;;
    6) # 原来的 5 变为 6
        remove_all_xrayr
        ;;
    *)
        echo "无效选项，退出脚本。"
        exit 1
        ;;
esac

exit 0
