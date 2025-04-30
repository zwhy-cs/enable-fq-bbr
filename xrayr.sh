#!/bin/bash

# 定义XrayR配置文件路径
CONFIG_FILE="/etc/XrayR/config.yml"

# 目录栏
echo "--------------------------------------------------"
echo "1. 安装 XrayR"
echo "2. 重启 XrayR"
echo "3. 添加节点"
echo "4. 退出"
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
    systemctl restart XrayR
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
    echo "\n- PanelType: \"NewV2board\" # Panel type: SSpanel, NewV2board, PMpanel, Proxypanel, V2RaySocks, GoV2Panel, BunPanel\n  ApiConfig:\n    ApiHost: \"https://xb.zwhy.cc\"\n    ApiKey: \"lzi0V41No3lVqnX9sYiGcnycy\"\n    NodeID: $node_id\n    NodeType: $node_type # Node type: V2ray, Vmess, Vless, Shadowsocks, Trojan, Shadowsocks-Plugin\n    Timeout: 30 # Timeout for the api request\n    EnableVless: $enable_vless # Enable Vless for V2ray Type\n    VlessFlow: \"xtls-rprx-vision\" # Only support vless\n    SpeedLimit: 0 # Mbps, Local settings will replace remote settings, 0 means disable\n    DeviceLimit: 0 # Local settings will replace remote settings, 0 means disable\n    RuleListPath: # /etc/XrayR/rulelist Path to local rulelist file\n    DisableCustomConfig: false # disable custom config for sspanel\n  ControllerConfig:\n    ListenIP: 0.0.0.0 # IP address you want to listen\n    SendIP: 0.0.0.0 # IP address you want to send pacakage\n    UpdatePeriodic: 60 # Time to update the nodeinfo, how many sec.\n    EnableDNS: false # Use custom DNS config, Please ensure that you set the dns.json well\n    DNSType: AsIs # AsIs, UseIP, UseIPv4, UseIPv6, DNS strategy\n    EnableProxyProtocol: false # Only works for WebSocket and TCP\n    AutoSpeedLimitConfig:\n      Limit: 0 # Warned speed. Set to 0 to disable AutoSpeedLimit (mbps)\n      WarnTimes: 0 # After (WarnTimes) consecutive warnings, the user will be limited. Set to 0 to punish overspeed user immediately.\n      LimitSpeed: 0 # The speedlimit of a limited user (unit: mbps)\n      LimitDuration: 0 # How many minutes will the limiting last (unit: minute)\n    GlobalDeviceLimitConfig:\n      Enable: false # Enable the global device limit of a user\n      RedisNetwork: tcp # Redis protocol, tcp or unix\n      RedisAddr: 127.0.0.1:6379 # Redis server address, or unix socket path\n      RedisUsername: # Redis username\n      RedisPassword: YOUR PASSWORD # Redis password\n      RedisDB: 0 # Redis DB\n      Timeout: 5 # Timeout for redis request\n      Expiry: 60 # Expiry time (second)\n    EnableFallback: false # Only support for Trojan and Vless\n    FallBackConfigs:  # Support multiple fallbacks\n      - SNI: # TLS SNI(Server Name Indication), Empty for any\n        Alpn: # Alpn, Empty for any\n        Path: # HTTP PATH, Empty for any\n        Dest: 80 # Required, Destination of fallback, check https://xtls.github.io/config/features/fallback.html for details.\n        ProxyProtocolVer: 0 # Send PROXY protocol version, 0 for disable\n    DisableLocalREALITYConfig: $disable_local_reality  # disable local reality config\n    EnableREALITY: $enable_reality # Enable REALITY\n    REALITYConfigs:\n      Show: true # Show REALITY debug\n      Dest: www.amazon.com:443 # Required, Same as fallback\n      ProxyProtocolVer: 0 # Send PROXY protocol version, 0 for disable\n      ServerNames: # Required, list of available serverNames for the client, * wildcard is not supported at the moment.\n        - www.amazon.com\n      PrivateKey: YOUR_PRIVATE_KEY # Required, execute './XrayR x25519' to generate.\n      MinClientVer: # Optional, minimum version of Xray client, format is x.y.z.\n      MaxClientVer: # Optional, maximum version of Xray client, format is x.y.z.\n      MaxTimeDiff: 0 # Optional, maximum allowed time difference, unit is in milliseconds.\n      ShortIds: # Required, list of available shortIds for the client, can be used to differentiate between different clients.\n        - \"\"\n        - 0123456789abcdef\n  CertConfig:\n    CertMode: dns # Option about how to get certificate: none, file, http, tls, dns. Choose \"none\" will forcedly disable the tls config.\n    CertDomain: \"node1.test.com\" # Domain to cert\n    CertFile: /etc/XrayR/cert/node1.test.com.cert # Provided if the CertMode is file\n    KeyFile: /etc/XrayR/cert/node1.test.com.key\n    Provider: alidns # DNS cert provider, Get the full support list here: https://go-acme.github.io/lego/dns/\n    Email: test@me.com\n    DNSEnv: # DNS ENV option used by DNS provider\n      ALICLOUD_ACCESS_KEY: aaa\n      ALICLOUD_SECRET_KEY: bbb\n" >> $CONFIG_FILE

    # 提示用户添加成功
    echo "节点已成功添加到 config.yml 文件中！"
    # 重启 XrayR 使配置生效
    restart_xrayr
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
        echo "退出脚本。"
        exit 0
        ;;
    *)
        echo "无效选项，退出脚本。"
        exit 1
        ;;
esac
