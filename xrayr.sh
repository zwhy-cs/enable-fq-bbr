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
    echo -e "Log:\n  Level: warning\n  AccessPath: ''\n  ErrorPath: ''\nDnsConfigPath: '/etc/XrayR/dns.json'\nRouteConfigPath: '/etc/XrayR/route.json'\nInboundConfigPath: '/etc/XrayR/custom_inbound.json'\nOutboundConfigPath: '/etc/XrayR/custom_outbound.json'\nConnectionConfig:\n  Handshake: 4\n  ConnIdle: 30\n  UplinkOnly: 2\n  DownlinkOnly: 4\n  BufferSize: 64\nNodes:" > $CONFIG_FILE
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
    echo "
    - PanelType: 'NewV2board' # Panel type: SSpanel, NewV2board, PMpanel, Proxypanel, V2RaySocks, GoV2Panel, BunPanel
      ApiConfig:
        ApiHost: 'https://xb.zwhy.cc'
        ApiKey: 'lzi0V41No3lVqnX9sYiGcnycy'
        NodeID: $node_id
        NodeType: $node_type # Node type: V2ray, Vmess, Vless, Shadowsocks, Trojan, Shadowsocks-Plugin
        Timeout: 30
        EnableVless: $enable_vless
        VlessFlow: 'xtls-rprx-vision'
        SpeedLimit: 200
        DeviceLimit: 0
        RuleListPath: ''
        DisableCustomConfig: false
      ControllerConfig:
        ListenIP: 0.0.0.0
        SendIP: 0.0.0.0
        UpdatePeriodic: 60
        EnableDNS: false
        DNSType: 'AsIs'
        EnableProxyProtocol: false
        AutoSpeedLimitConfig:
          Limit: 0
          WarnTimes: 0
          LimitSpeed: 0
          LimitDuration: 0
        GlobalDeviceLimitConfig:
          Enable: false
          RedisNetwork: 'tcp'
          RedisAddr: '127.0.0.1:6379'
          RedisUsername: ''
          RedisPassword: 'YOUR PASSWORD'
          RedisDB: 0
          Timeout: 5
          Expiry: 60
        EnableFallback: false
        FallBackConfigs:
          - SNI: ''
            Alpn: ''
            Path: ''
            Dest: 80
            ProxyProtocolVer: 0
        DisableLocalREALITYConfig: $disable_local_reality
        EnableREALITY: $enable_reality
        REALITYConfigs:
          Show: true
          Dest: 'www.amazon.com:443'
          ProxyProtocolVer: 0
          ServerNames:
            - 'www.amazon.com'
          PrivateKey: 'YOUR_PRIVATE_KEY'
          MinClientVer: ''
          MaxClientVer: ''
          MaxTimeDiff: 0
          ShortIds:
            - ''
            - '0123456789abcdef'
      CertConfig:
        CertMode: 'dns'
        CertDomain: 'node1.test.com'
        CertFile: '/etc/XrayR/cert/node1.test.com.cert'
        KeyFile: '/etc/XrayR/cert/node1.test.com.key'
        Provider: 'alidns'
        Email: 'test@me.com'
        DNSEnv:
          ALICLOUD_ACCESS_KEY: 'aaa'
          ALICLOUD_SECRET_KEY: 'bbb'
    " >> $CONFIG_FILE

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
