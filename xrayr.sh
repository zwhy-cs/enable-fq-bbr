#!/bin/bash

# 定义XrayR配置文件路径
CONFIG_FILE="/etc/XrayR/config.yml"

# 目录栏
echo "--------------------------------------------------"
echo "1. 安装 XrayR"
echo "2. 重启 XrayR"
echo "3. 添加节点"
echo "4. 删除节点"
echo "5. 退出"
echo "6. 一键删除所有XrayR相关文件和配置"
echo "--------------------------------------------------"
read -p "请选择操作： " choice

# 安装 XrayR
install_xrayr() {
    echo "正在安装 XrayR..."
    bash <(curl -Ls https://raw.githubusercontent.com/XrayR-project/XrayR-release/master/install.sh)
    # 修改 config.yml 配置文件
    echo "正在初始化 config.yml 文件..."
    echo -e "Log:\n  Level: warning # Log level: none, error, warning, info, debug\n  AccessPath: # /etc/XrayR/access.Log\n  ErrorPath: # /etc/XrayR/error.log\nDnsConfigPath: # /etc/XrayR/dns.json # Path to dns config, check https://xtls.github.io/config/dns.html for help\nRouteConfigPath: # /etc/XrayR/route.json # Path to route config, check https://xtls.github.io/config/routing.html for help\nInboundConfigPath: # /etc/XrayR/custom_inbound.json # Path to custom inbound config, check https://xtls.github.io/config/inbound.html for help\nOutboundConfigPath: # /etc/XrayR/custom_outbound.json # Path to custom outbound config, check https://xtls.github.io/config/outbound.html for help\nConnectionConfig:\n  Handshake: 4 # Handshake time limit, Second\n  ConnIdle: 30 # Connection idle time limit, Second\n  UplinkOnly: 2 # Time limit when the connection downstream is closed, Second\n  DownlinkOnly: 4 # Time limit when the connection is closed after the uplink is closed, Second\n  BufferSize: 64 # The internal cache size of each connection, kB\nNodes:" > $CONFIG_FILE
    echo "XrayR 安装并初始化配置文件完成。"
}

# 重启 XrayR
restart_xrayr() {
    echo "正在重启 XrayR..."
    XrayR restart   
    echo "XrayR 已重启。"
}

# 添加节点到 config.yml
add_node() {
    echo "请输入要添加的节点信息："
    read -p "节点 ID: " node_id
    read -p "选择节点类型 (V2ray/Vmess/Vless/Shadowsocks/Trojan): " node_type
    read -p "是否启用Reality (yes/no): " enable_reality

    # 根据是否启用Reality来设置其他参数
    if [[ "$enable_reality" == "yes" ]]; then
        enable_vless=true
        disable_local_reality=true
        enable_reality=true
    else
        enable_vless=false
        disable_local_reality=false
        enable_reality=false
    fi

    echo "正在添加节点..."

    # 将节点配置添加到config.yml
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
      EnableREALITY: $enable_reality # Enable REALITY
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
    echo "节点已成功添加到 config.yml 文件中！"
    # 重启 XrayR 使配置生效
    restart_xrayr
}

# 删除节点
delete_node() {
    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误：配置文件 $CONFIG_FILE 不存在!"
        return 1
    fi
    
    # 备份原始配置文件
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    echo "已备份配置文件到 ${CONFIG_FILE}.bak"
    
    # 要求用户输入要删除的节点信息
    read -p "请输入要删除的节点ID: " node_id
    read -p "请输入节点类型 (V2ray/Vmess/Vless/Shadowsocks/Trojan): " node_type
    
    # 查找同时包含NodeID和NodeType的区域
    node_id_line=$(grep -n "NodeID: *$node_id" "$CONFIG_FILE" | cut -d: -f1)
    
    if [ -z "$node_id_line" ]; then
        echo "未找到节点ID为 $node_id 的配置，请检查ID是否正确！"
        return 1
    fi
    
    # 检查该NodeID对应的NodeType是否匹配
    node_type_found=false
    for line in $node_id_line; do
        # 获取NodeID所在行之后的几行，查找NodeType
        node_type_line=$(tail -n +$line "$CONFIG_FILE" | grep -n "NodeType: *$node_type" | head -n 1 | cut -d: -f1)
        if [ ! -z "$node_type_line" ]; then
            # 计算NodeType实际所在行号
            actual_type_line=$((line + node_type_line - 1))
            # 检查该NodeType是否在合理范围内（通常NodeType应该在NodeID附近几行内）
            if [ $((actual_type_line - line)) -lt 10 ]; then
                node_type_found=true
                # 使用找到的NodeID行
                node_line=$line
                break
            fi
        fi
    done
    
    if [ "$node_type_found" = false ]; then
        echo "未找到节点ID为 $node_id 且类型为 $node_type 的配置，请检查信息是否正确！"
        return 1
    fi
    
    # 查找Nodes:所在的行
    nodes_line=$(grep -n "^Nodes:" "$CONFIG_FILE" | cut -d: -f1)
    
    if [ -z "$nodes_line" ]; then
        echo "找不到Nodes:部分，配置文件格式可能不正确！"
        return 1
    fi
    
    # 确定节点配置开始行（节点块的开始标记行）
    start_line=0
    for (( i=$node_line; i>=$nodes_line; i-- )); do
        line_content=$(sed "${i}q;d" "$CONFIG_FILE")
        # 查找该节点块开始的标记
        if [[ "$line_content" =~ ^[[:space:]]*- || "$line_content" =~ ^[[:space:]]*PanelType: ]]; then
            start_line=$i
            break
        fi
    done
    
    if [ $start_line -eq 0 ]; then
        echo "无法确定节点的开始位置，删除失败！"
        return 1
    fi
    
    # 查找下一个节点开始的标志或文件结束
    end_line=0
    total_lines=$(wc -l < "$CONFIG_FILE")
    
    for (( i=$node_line+1; i<=$total_lines; i++ )); do
        line_content=$(sed "${i}q;d" "$CONFIG_FILE")
        # 查找下一个节点的开始标记
        if [[ "$line_content" =~ ^[[:space:]]*- ]]; then
            # 找到下一个节点的开始行
            end_line=$((i-1))
            break
        fi
    done
    
    # 如果没找到下一个节点的开始，则到文件结束
    if [ $end_line -eq 0 ]; then
        end_line=$total_lines
    fi
    
    echo "将删除从第 $start_line 行到第 $end_line 行的节点配置"
    
    # 创建临时文件
    temp_file="${CONFIG_FILE}.tmp"
    
    # 提取需要保留的部分（删除节点的行）
    {
        # 保留节点前的部分
        sed -n "1,$((start_line-1))p" "$CONFIG_FILE"
        # 保留节点后的部分
        if [ $end_line -lt $total_lines ]; then
            sed -n "$((end_line+1)),${total_lines}p" "$CONFIG_FILE"
        fi
    } > "$temp_file"
    
    # 将临时文件移动到原配置文件
    mv "$temp_file" "$CONFIG_FILE"
    
    echo "成功删除节点ID为 $node_id 类型为 $node_type 的配置！"
    
    # 重启XrayR使配置生效
    restart_xrayr
}

# 一键删除所有XrayR相关文件和配置
remove_all_xrayr() {
    echo "警告：即将删除所有XrayR相关文件和配置！"
    read -p "确定要继续吗？(yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        systemctl stop XrayR 2>/dev/null
        systemctl disable XrayR 2>/dev/null
        rm -rf /etc/XrayR
        rm -rf /usr/local/XrayR
        rm -f /etc/systemd/system/XrayR.service
        systemctl daemon-reload
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
    4)
        delete_node
        ;;
    5)
        echo "退出脚本。"
        exit 0
        ;;
    6)
        remove_all_xrayr
        ;;
    *)
        echo "无效选项，退出脚本。"
        exit 1
        ;;
esac
