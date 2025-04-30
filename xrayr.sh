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
    
    # 要求用户输入要删除的节点ID
    read -p "请输入要删除的节点ID: " node_id
    
    # 使用awk寻找并删除指定节点ID的配置
    awk -v node_id="$node_id" '
    BEGIN { 
        found = 0; 
        skip = 0; 
        nodeFound = 0;
    }
    
    # 如果遇到节点标记
    /^[ \t]*-[ \t]*PanelType:/ { 
        # 先保存这一行，判断后续行是否包含要删除的节点ID
        buffer = $0;
        # 标记进入节点配置区域
        inNode = 1;
        # 清空保存行的计数器
        n = 0;
        # 保存第一行
        lines[++n] = buffer;
        next;
    }
    
    # 如果在节点配置中，查找是否包含要删除的节点ID
    inNode && /NodeID:[ \t]*[0-9]+/ {
        # 提取节点ID
        match($0, /NodeID:[ \t]*([0-9]+)/, arr);
        current_id = arr[1];
        
        # 当前行也保存到缓存
        lines[++n] = $0;
        
        # 如果找到了要删除的节点ID
        if (current_id == node_id) {
            found = 1;
            nodeFound = 1;
            skip = 1;  # 标记需要跳过
            next;
        }
    }
    
    # 不在节点配置区或没有找到匹配的节点ID
    inNode && !/^[ \t]*-[ \t]*PanelType:/ {
        # 继续收集配置行
        if (!skip) {
            lines[++n] = $0;
        }
        next;
    }
    
    # 如果找到下一个节点的开始或文件结束，决定是否输出之前保存的行
    /^[ \t]*-[ \t]*PanelType:/ && inNode {
        # 如果不需要跳过，输出前面保存的所有行
        if (!skip) {
            for (i = 1; i <= n; i++) {
                print lines[i];
            }
        }
        
        # 重置状态
        inNode = 0;
        skip = 0;
        n = 0;
        
        # 这是新节点的开始行，保存起来
        buffer = $0;
        inNode = 1;
        lines[++n] = buffer;
        next;
    }
    
    # 如果不在节点配置中，直接输出
    !inNode { print; next; }
    
    END {
        # 处理最后一个节点
        if (inNode && !skip) {
            for (i = 1; i <= n; i++) {
                print lines[i];
            }
        }
        
        # 如果找到并删除了节点，输出成功消息
        if (nodeFound) {
            # 这个消息会混入到文件中，所以我们在脚本中另外输出
            # 这里只设置状态
            exit(0);
        } else {
            # 如果没找到节点，退出状态码为1
            exit(1);
        }
    }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    
    # 检查awk的执行结果
    if [ $? -eq 0 ]; then
        # 将临时文件移动到原配置文件
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        echo "成功删除节点ID为 $node_id 的配置！"
        # 重启XrayR使配置生效
        restart_xrayr
    else
        echo "未找到节点ID为 $node_id 的配置，请检查ID是否正确！"
        # 删除临时文件
        rm -f "${CONFIG_FILE}.tmp"
    fi
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
