#!/bin/bash

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

version="v1.0.0"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误: ${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

os_version=""

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

# 确认函数
confirm() {
    if [[ $# > 1 ]]; then
        echo && read -p "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -p "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

# 定义XrayR配置文件路径
CONFIG_FILE="/etc/XrayR/config.yml"

# 系统服务状态检查函数
# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /etc/systemd/system/XrayR.service ]]; then
        return 2
    fi
    temp=$(systemctl status XrayR | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
    if [[ x"${temp}" == x"running" ]]; then
        return 0
    else
        return 1
    fi
}

check_enabled() {
    temp=$(systemctl is-enabled XrayR)
    if [[ x"${temp}" == x"enabled" ]]; then
        return 0
    else
        return 1;
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        echo -e "${red}请先安装XrayR${plain}"
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "XrayR状态: ${green}已运行${plain}"
            show_enable_status
            ;;
        1)
            echo -e "XrayR状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "XrayR状态: ${red}未安装${plain}"
    esac
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

# 显示菜单函数
show_menu() {
    echo -e "
  ${green}XrayR 管理脚本${plain}
  ${green}--- 增强版本 ---${plain}
    "
    show_status
    echo -e "
--------------------------------------------------
 XrayR 管理脚本
--------------------------------------------------
${green}1.${plain} 安装 XrayR
${green}2.${plain} 重启 XrayR  
${green}3.${plain} 添加节点
${green}4.${plain} 删除节点
${green}5.${plain} 一键删除所有XrayR相关文件和配置
${green}6.${plain} 查看当前XrayR配置
${green}7.${plain} 使用nano编辑config.yml
${green}8.${plain} 更新 XrayR
————————————————
${green}9.${plain} 启动 XrayR
${green}10.${plain} 停止 XrayR
${green}11.${plain} 查看 XrayR 状态
${green}12.${plain} 查看 XrayR 日志
${green}13.${plain} 设置 XrayR 开机自启
${green}14.${plain} 取消 XrayR 开机自启
————————————————
${green}15.${plain} 更新本脚本
${green}0.${plain} 退出
"
    read -p "请选择操作： " choice
}

# 添加新的系统服务管理函数
start_xrayr() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}XrayR已运行，无需再次启动${plain}"
    else
        systemctl start XrayR
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}XrayR 启动成功${plain}"
        else
            echo -e "${red}XrayR可能启动失败，请使用选项12查看日志${plain}"
        fi
    fi
}

stop_xrayr() {
    systemctl stop XrayR
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}XrayR 停止成功${plain}"
    else
        echo -e "${red}XrayR停止失败${plain}"
    fi
}

status_xrayr() {
    systemctl status XrayR --no-pager -l
}

enable_xrayr() {
    systemctl enable XrayR
    if [[ $? == 0 ]]; then
        echo -e "${green}XrayR 设置开机自启成功${plain}"
    else
        echo -e "${red}XrayR 设置开机自启失败${plain}"
    fi
}

disable_xrayr() {
    systemctl disable XrayR
    if [[ $? == 0 ]]; then
        echo -e "${green}XrayR 取消开机自启成功${plain}"
    else
        echo -e "${red}XrayR 取消开机自启失败${plain}"
    fi
}

show_log() {
    journalctl -u XrayR.service -e --no-pager -f
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
}

# 安装 XrayR
install_xrayr() {
    echo -e "${green}正在安装 XrayR...${plain}"

    # 确保 /etc/XrayR 目录存在
    mkdir -p /etc/XrayR

    # 检查并安装 unzip
    if ! command -v unzip &> /dev/null; then
        echo -e "${yellow}正在安装 unzip...${plain}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y unzip
        elif command -v yum &> /dev/null; then
            yum install -y unzip
        else
            echo -e "${red}错误：无法自动安装 unzip。请手动安装后重试。${plain}"
            return 1
        fi
    fi

    # 从指定 URL 下载 XrayR
    echo -e "${green}正在从 https://github.com/zwhy-cs/XrayR/releases/download/v1.0.1/XrayR-linux-64.zip 下载 XrayR...${plain}"
    curl -L -o /etc/XrayR/XrayR-linux-64.zip "https://github.com/zwhy-cs/XrayR/releases/download/v1.0.0/XrayR-linux-64.zip"

    # 解压并清理
    echo "正在解压 XrayR..."
    unzip -o /etc/XrayR/XrayR-linux-64.zip -d /etc/XrayR/
    rm /etc/XrayR/XrayR-linux-64.zip
    chmod +x /etc/XrayR/XrayR

    # 创建 systemd 服务文件
    echo "正在创建 systemd 服务..."
    cat > /etc/systemd/system/XrayR.service <<EOF
[Unit]
Description=XrayR Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/XrayR
ExecStart=/etc/XrayR/XrayR --config /etc/XrayR/config.yml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载 systemd 并启动 XrayR
    systemctl daemon-reload
    systemctl enable XrayR
    systemctl start XrayR
    
    # 初始化配置文件
    echo "正在初始化 config.yml 文件..."
    cat > $CONFIG_FILE <<EOF
Log:
  Level: error # Log level: none, error, warning, info, debug
  AccessPath: # /etc/XrayR/access.Log
  ErrorPath:  /etc/XrayR/error.log
DnsConfigPath:  /etc/XrayR/dns.json # Path to dns config, check https://xtls.github.io/config/dns.html for help
RouteConfigPath: /etc/XrayR/route.json # Path to route config, check https://xtls.github.io/config/routing.html for help
InboundConfigPath: #/etc/XrayR/custom_inbound.json # Path to custom inbound config, check https://xtls.github.io/config/inbound.html for help
OutboundConfigPath: #/etc/XrayR/custom_outbound.json # Path to custom outbound config, check https://xtls.github.io/config/outbound.html for help
ConnectionConfig:
  Handshake: 4 # Handshake time limit, Second
  ConnIdle: 600 # Connection idle time limit, Second
  UplinkOnly: 2 # Time limit when the connection downstream is closed, Second
  DownlinkOnly: 4 # Time limit when the connection is closed after the uplink is closed, Second
  BufferSize: 64 # The internal cache size of each connection, kB
Nodes:
EOF
    echo -e "${green}XrayR 安装并初始化配置文件完成。${plain}"

    # 覆盖 dns.json
    cat > /etc/XrayR/dns.json <<EOF
{
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8"
    ]
  }
}
EOF

    # 创建 custom_outbound.json
#    cat > /etc/XrayR/custom_outbound.json <<EOF
#[
#  {
#    "protocol": "freedom",
#    "tag": "direct"
#  },
#  {
#    "protocol": "blackhole",
#    "tag": "block"
#  }
#]
#EOF

    # 创建 route.json
    cat > /etc/XrayR/route.json <<EOF
{
    "rules": []
}
EOF
}

# 重启 XrayR
restart_xrayr() {
    echo -e "${yellow}正在重启 XrayR...${plain}"
    # 使用 systemctl 重启服务
    if command -v systemctl &> /dev/null; then
        systemctl restart XrayR
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}XrayR 重启成功${plain}"
        else
            echo -e "${red}XrayR 重启失败，请查看日志${plain}"
        fi
    else
        echo -e "${red}未找到 systemctl 命令，无法重启服务${plain}"
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

    # 新增：ApiHost 和 ApiKey 只需首次输入并保存
    API_CONF="/etc/XrayR/api.conf"
    if [ -f "$API_CONF" ]; then
        source "$API_CONF"
        api_host="$API_HOST"
        api_key="$API_KEY"
        echo "已自动读取 ApiHost: $api_host, ApiKey: $api_key"
    else
        read -p "请输入面板ApiHost: " api_host
        if [[ -z "$api_host" ]]; then
            echo "错误：ApiHost 不能为空。"
            return 1
        fi
        read -p "请输入面板ApiKey: " api_key
        if [[ -z "$api_key" ]]; then
            echo "错误：ApiKey 不能为空。"
            return 1
        fi
        echo "API_HOST=$api_host" > "$API_CONF"
        echo "API_KEY=$api_key" >> "$API_CONF"
        echo "已保存 ApiHost 和 ApiKey 到 $API_CONF"
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
    
    read -p "是否启用Reality (y/n): " enable_reality

    # 根据是否启用Reality来设置其他参数
    if [[ "$enable_reality" == "y" ]]; then
        enable_vless=true
        enable_reality_flag=true # 使用不同的变量名以区分输入的 "y/n"
    else
        enable_vless=false
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
      ApiHost: "$api_host"
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
      EnableDNS: true # Use custom DNS config, Please ensure that you set the dns.json well
      DNSType: UseIPv4 # AsIs, UseIP, UseIPv4, UseIPv6, DNS strategy
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
      DisableLocalREALITYConfig: true  # disable local reality config
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

    echo "正在添加路由规则..."
    # 检查 jq 是否安装
    if ! command -v jq &> /dev/null; then
        echo "未检测到jq，正在安装..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y jq
        elif command -v yum &> /dev/null; then
            yum install -y jq
        else
            echo "无法自动安装jq，请手动安装后重试。"
        fi
    fi
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
                XrayR restart
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
    echo -e "${red}警告：即将删除所有XrayR相关文件和配置！${plain}"
    confirm "确定要继续吗？" "n"
    if [[ $? == 0 ]]; then
        echo -e "${yellow}正在停止 XrayR 服务...${plain}"
        systemctl stop XrayR 2>/dev/null
        systemctl disable XrayR 2>/dev/null
        echo -e "${yellow}正在删除 XrayR 文件和目录...${plain}"
        rm -rf /etc/XrayR
        rm -rf /usr/local/XrayR
        rm -f /etc/systemd/system/XrayR.service
        echo -e "${yellow}正在重新加载 systemd 配置...${plain}"
        systemctl daemon-reload 2>/dev/null
        systemctl reset-failed 2>/dev/null
        echo -e "${green}所有XrayR相关文件和配置已删除。${plain}"
    else
        echo -e "${yellow}操作已取消。${plain}"
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

# 更新本脚本
update_self_script() {
    echo "正在从远程仓库拉取最新脚本..."
    curl -o /usr/local/bin/xrayr.sh -L "https://raw.githubusercontent.com/zwhy-cs/enable-fq-bbr/main/xrayr.sh"
    chmod +x /usr/local/bin/xrayr.sh
    echo "脚本已更新为最新版本（/usr/local/bin/xrayr.sh）。"
}

# 主执行逻辑
main() {
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
            check_install && start_xrayr
            ;;
        10)
            check_install && stop_xrayr
            ;;
        11)
            check_install && status_xrayr
            ;;
        12)
            check_install && show_log
            ;;
        13)
            check_install && enable_xrayr
            ;;
        14)
            check_install && disable_xrayr
            ;;
        15)
            update_self_script
            ;;
        0)
            echo -e "${green}退出脚本。${plain}"
            exit 0
            ;;
        *)
            echo -e "${red}无效选项，请重新选择。${plain}"
            ;;
    esac
    
    # 执行完操作后返回菜单
    before_show_menu
}

# 命令行参数支持
if [[ $# > 0 ]]; then
    case $1 in
        "start") check_install 0 && start_xrayr 0
        ;;
        "stop") check_install 0 && stop_xrayr 0
        ;;
        "restart") check_install 0 && restart_xrayr 0
        ;;
        "status") check_install 0 && status_xrayr 0
        ;;
        "enable") check_install 0 && enable_xrayr 0
        ;;
        "disable") check_install 0 && disable_xrayr 0
        ;;
        "log") check_install 0 && show_log 0
        ;;
        "install") install_xrayr 0
        ;;
        "uninstall") check_install 0 && remove_all_xrayr 0
        ;;
        "add") add_node 0
        ;;
        "delete") delete_node 0
        ;;
        "config") view_config 0
        ;;
        "edit") edit_config 0
        ;;
        "update") update_xrayr 0
        ;;
        *) echo -e "${red}无效参数${plain}"
           echo "使用方法: $0 [start|stop|restart|status|enable|disable|log|install|uninstall|add|delete|config|edit|update]"
        ;;
    esac
else
    show_menu
    main
fi
