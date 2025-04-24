#!/bin/bash

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# 确保脚本以root权限运行
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用root用户运行此脚本！\n" && exit 1

# 系统配置路径
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="$CONFIG_DIR/config.json"
SYSTEMD_FILE="/etc/systemd/system/xray.service"
XRAY_BIN="/usr/local/bin/xray"
LOG_DIR="/var/log/xray"

# 检测操作系统
check_os() {
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
        echo -e "${RED}未检测到系统版本，请联系脚本作者！${PLAIN}\n" && exit 1
    fi

    if [[ $release = "centos" ]]; then
        os_version=$(grep -oE "[0-9.]+" /etc/redhat-release | cut -d "." -f1)
        if [[ ${os_version} -lt 7 ]]; then
            echo -e "${RED}请使用 CentOS 7 或更高版本的系统！${PLAIN}\n" && exit 1
        fi
    fi
}

# 安装依赖
install_dependencies() {
    echo -e "${GREEN}正在安装依赖...${PLAIN}"
    if [[ $release = "centos" ]]; then
        yum update -y
        yum install -y wget curl tar socat jq
    else
        apt update -y
        apt install -y wget curl tar socat jq
    fi
}

# 安装或更新xray
install_update_xray() {
    echo -e "${GREEN}开始安装/更新 Xray...${PLAIN}"
    
    # 下载最新版本xray
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # 创建配置目录（如果不存在）
    mkdir -p ${CONFIG_DIR}
    
    # 创建日志目录（如果不存在）
    mkdir -p ${LOG_DIR}
    
# 如果配置文件不存在，才创建一个基本配置
if [[ ! -f ${CONFIG_FILE} ]]; then
    cat >${CONFIG_FILE} <<-EOF
{
    "log": {
        "loglevel": "warning",
        "access": "${LOG_DIR}/access.log",
        "error": "${LOG_DIR}/error.log"
    },
    "inbounds": [],
    "outbounds": []
}
EOF
fi
    
    # 设置权限
    chmod 644 ${CONFIG_FILE}
    chmod +x ${XRAY_BIN}
    
    # 启动服务
    systemctl enable xray
    systemctl restart xray
    
    echo -e "${GREEN}Xray 已安装/更新成功！${PLAIN}"
}

# 卸载xray
uninstall_xray() {
    echo -e "${YELLOW}正在卸载 Xray...${PLAIN}"
    systemctl stop xray
    systemctl disable xray
    
    # 使用官方卸载脚本
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
    
    # 删除剩余文件
    rm -rf ${CONFIG_DIR}
    rm -rf ${LOG_DIR}
    
    echo -e "${GREEN}Xray 已成功卸载！${PLAIN}"
}

# 检查xray状态
check_xray_status() {
    echo -e "${BLUE}检查 Xray 状态...${PLAIN}"
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}Xray 服务状态: 运行中${PLAIN}"
        
        # 显示当前配置信息
        echo -e "${BLUE}当前配置概览:${PLAIN}"
        
        if [[ -f ${CONFIG_FILE} ]]; then
            # 显示入站连接数
            inbound_count=$(jq '.inbounds | length' ${CONFIG_FILE})
            echo -e "${GREEN}入站连接数: ${inbound_count}${PLAIN}"
            
            # 显示每个入站连接的协议和端口
            for ((i=0; i<${inbound_count}; i++)); do
                protocol=$(jq -r ".inbounds[$i].protocol" ${CONFIG_FILE})
                port=$(jq -r ".inbounds[$i].port" ${CONFIG_FILE})
                echo -e "${GREEN}[${i}] 协议: ${protocol}, 端口: ${port}${PLAIN}"
            done
        else
            echo -e "${RED}配置文件不存在！${PLAIN}"
        fi
        
        # 显示系统信息
        echo -e "\n${BLUE}系统信息:${PLAIN}"
        echo -e "$(cat /etc/os-release | grep "PRETTY_NAME" | cut -d "=" -f2 | tr -d '"')"
        echo -e "内核版本: $(uname -r)"
        
        # 显示网络信息
        echo -e "\n${BLUE}网络信息:${PLAIN}"
        ip=$(curl -s https://api.ipify.org)
        echo -e "公网IP: ${ip}"
        
        # 显示Xray版本
        echo -e "\n${BLUE}Xray 版本:${PLAIN}"
        ${XRAY_BIN} -version
    else
        echo -e "${RED}Xray 服务状态: 未运行${PLAIN}"
    fi
}

# 添加 Reality 节点
add_reality() {
    echo -e "${GREEN}添加 REALITY 节点...${PLAIN}"
    
    # 生成UUID
    uuid=$(xray uuid)
    echo -e "${GREEN}已生成UUID: ${uuid}${PLAIN}"
    
    # 生成 REALITY 密钥对
    key_pair=$(xray x25519)
    private_key=$(echo "$key_pair" | grep "Private" | awk '{print $3}')
    public_key=$(echo "$key_pair" | grep "Public" | awk '{print $3}')
    
    # 获取端口 (对外端口)
    read -p "请输入外部端口号 [默认: 443]: " port
    port=${port:-443}
    
    # 内部端口
    internal_port=4431
    
    # 获取服务器名称
    read -p "请输入服务器名称(SNI) [例如: speed.cloudflare.com]: " server_name
    server_name=${server_name:-speed.cloudflare.com}
    
    # 获取短ID
    short_ids_json=$(jq -n --arg id1 "" --arg id2 "$(openssl rand -hex 8)" '[$id1, $id2]')
    
    # 更新配置文件
    if [[ -f ${CONFIG_FILE} ]]; then
        # 备份配置文件
        cp ${CONFIG_FILE} ${CONFIG_FILE}.bak
        
        # 创建 dokodemo-door 入站配置
        dokodemo_config=$(cat <<EOF
{
    "tag": "dokodemo-in",
    "port": ${port},
    "protocol": "dokodemo-door",
    "settings": {
        "address": "127.0.0.1",
        "port": ${internal_port},
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
EOF
)

        # 创建 vless 入站配置
        vless_config=$(cat <<EOF
{
    "listen": "127.0.0.1",
    "port": ${internal_port},
    "protocol": "vless",
    "settings": {
        "clients": [
            {
                "id": "${uuid}",
                "flow": "xtls-rprx-vision"
            }
        ],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "dest": "${server_name}:443",
            "serverNames": [
                "${server_name}"
            ],
            "privateKey": "${private_key}",
            "shortIds": ${short_ids_json},
            "publicKey": "${public_key}"
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": [
            "http",
            "tls",
            "quic"
        ],
        "routeOnly": true
    }
}
EOF
)

        # 添加必要的出站配置
        outbounds_config=$(cat <<EOF
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
)

        # 添加路由规则
        routing_config=$(cat <<EOF
{
    "rules": [
        {
            "inboundTag": [
                "dokodemo-in"
            ],
            "domain": [
                "${server_name}"
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
)
        
        # 添加新的入站配置和出站配置
        jq --argjson dokodemo "$dokodemo_config" --argjson vless "$vless_config" --argjson outbounds "$outbounds_config" --argjson routing "$routing_config" \
        '.inbounds = [.inbounds[] | select(.tag != "dokodemo-in")] + [$dokodemo, $vless] | .outbounds = $outbounds | .routing = $routing' \
        ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
        mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
        
        # 重启xray服务
        systemctl restart xray
        
        # 显示客户端配置信息
        echo -e "\n${GREEN}安全的 REALITY 节点已添加成功!${PLAIN}"
        echo -e "${YELLOW}=== 客户端配置信息 ===${PLAIN}"
        echo -e "${GREEN}协议: VLESS${PLAIN}"
        echo -e "${GREEN}地址: $(curl -s https://api.ipify.org)${PLAIN}"
        echo -e "${GREEN}端口: ${port}${PLAIN}"
        echo -e "${GREEN}UUID: ${uuid}${PLAIN}"
        echo -e "${GREEN}流控: xtls-rprx-vision${PLAIN}"
        echo -e "${GREEN}传输协议: tcp${PLAIN}"
        echo -e "${GREEN}安全层: reality${PLAIN}"
        echo -e "${GREEN}SNI: ${server_name}${PLAIN}"
        echo -e "${GREEN}PublicKey: ${public_key}${PLAIN}"
        echo -e "${GREEN}ShortID: $(echo $short_ids_json | jq -r '.[1]')${PLAIN}"
        echo -e "${GREEN}请注意：这是使用dokodemo-door代理的安全Reality配置${PLAIN}"
        
        # 生成分享链接
        share_link="vless://${uuid}@$(curl -s https://api.ipify.org):${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=$(echo $short_ids_json | jq -r '.[1]')#REALITY-${port}"
        echo -e "${GREEN}分享链接: ${share_link}${PLAIN}"
    else
        echo -e "${RED}配置文件不存在，请先安装xray！${PLAIN}"
    fi
}

# 添加多个 Reality 节点
add_multiple_reality() {
    echo -e "${GREEN}添加 REALITY 节点...${PLAIN}"
    
    # 询问用户想要创建的节点数量
    read -p "请输入要创建的 REALITY 节点数量 [默认: 1]: " node_count
    node_count=${node_count:-1}
    
    # 验证输入是否为数字
    if [[ ! "$node_count" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}输入无效！请输入有效的数字。${PLAIN}"
        return
    fi
    
    # 如果输入的是0或负数，退出函数
    if [[ $node_count -le 0 ]]; then
        echo -e "${RED}节点数必须大于0！${PLAIN}"
        return
    fi
    
    # 检查现有配置，找出已经使用的内部端口
    declare -a used_internal_ports
    if [[ -f ${CONFIG_FILE} ]]; then
        inbound_count=$(jq '.inbounds | length' ${CONFIG_FILE})
        for ((i=0; i<${inbound_count}; i++)); do
            protocol=$(jq -r ".inbounds[$i].protocol" ${CONFIG_FILE})
            listen=$(jq -r ".inbounds[$i].listen // \"0.0.0.0\"" ${CONFIG_FILE})
            
            if [[ "$protocol" == "vless" && "$listen" == "127.0.0.1" ]]; then
                # 这是REALITY内部端口
                inner_port=$(jq -r ".inbounds[$i].port" ${CONFIG_FILE})
                used_internal_ports+=($inner_port)
            fi
        done
    fi
    
    # 找到可用的起始内部端口（默认从4431开始）
    start_internal_port=4431
    
    # 创建每个节点
    for ((i=1; i<=$node_count; i++)); do
        echo -e "\n${YELLOW}====== 创建第 $i 个 REALITY 节点 ======${PLAIN}"
        
        # 生成UUID
        uuid=$(xray uuid)
        echo -e "${GREEN}已生成UUID: ${uuid}${PLAIN}"
        
        # 生成 REALITY 密钥对
        key_pair=$(xray x25519)
        private_key=$(echo "$key_pair" | grep "Private" | awk '{print $3}')
        public_key=$(echo "$key_pair" | grep "Public" | awk '{print $3}')
        
        # 获取端口 (对外端口)
        read -p "请输入第 $i 个节点的外部端口号 [默认: $((443 + $i - 1))]: " port
        port=${port:-$((443 + $i - 1))}
        
        # 查找未被使用的内部端口
        internal_port=$start_internal_port
        while [[ " ${used_internal_ports[@]} " =~ " ${internal_port} " ]]; do
            internal_port=$((internal_port+1))
        done
        used_internal_ports+=($internal_port)
        
        echo -e "${GREEN}为该节点分配内部端口: ${internal_port}${PLAIN}"
        
        # 获取服务器名称
        read -p "请输入第 $i 个节点的服务器名称(SNI) [例如: speed.cloudflare.com]: " server_name
        server_name=${server_name:-speed.cloudflare.com}
        
        # 获取短ID
        short_ids_json=$(jq -n --arg id1 "" --arg id2 "$(openssl rand -hex 8)" '[$id1, $id2]')
        
        # 更新配置文件
        if [[ -f ${CONFIG_FILE} ]]; then
            # 备份配置文件
            if [[ $i -eq 1 ]]; then
                cp ${CONFIG_FILE} ${CONFIG_FILE}.bak
            fi
            
            # 创建 dokodemo-door 入站配置
            dokodemo_config=$(cat <<EOF
{
    "tag": "dokodemo-in-${port}",
    "port": ${port},
    "protocol": "dokodemo-door",
    "settings": {
        "address": "127.0.0.1",
        "port": ${internal_port},
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
EOF
)

            # 创建 vless 入站配置
            vless_config=$(cat <<EOF
{
    "listen": "127.0.0.1",
    "port": ${internal_port},
    "protocol": "vless",
    "settings": {
        "clients": [
            {
                "id": "${uuid}",
                "flow": "xtls-rprx-vision"
            }
        ],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "dest": "${server_name}:443",
            "serverNames": [
                "${server_name}"
            ],
            "privateKey": "${private_key}",
            "shortIds": ${short_ids_json},
            "publicKey": "${public_key}"
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": [
            "http",
            "tls",
            "quic"
        ],
        "routeOnly": true
    }
}
EOF
)

            # 添加路由规则
            routing_rule_domain=$(cat <<EOF
{
    "inboundTag": [
        "dokodemo-in-${port}"
    ],
    "domain": [
        "${server_name}"
    ],
    "outboundTag": "direct"
}
EOF
)

            routing_rule_block=$(cat <<EOF
{
    "inboundTag": [
        "dokodemo-in-${port}"
    ],
    "outboundTag": "block"
}
EOF
)
            
            # 检查是否需要添加必要的出站配置
            outbounds_count=$(jq '.outbounds | length' ${CONFIG_FILE})
            if [ "$outbounds_count" -eq 0 ]; then
                # 添加必要的出站配置
                outbounds_config=$(cat <<EOF
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
)
                # 添加出站配置
                jq --argjson outbounds "$outbounds_config" '.outbounds = $outbounds' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
                mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
            fi
            
            # 添加入站配置
            jq --argjson dokodemo "$dokodemo_config" --argjson vless "$vless_config" \
            '.inbounds += [$dokodemo, $vless]' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
            mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
            
            # 添加路由规则
            if jq -e '.routing' ${CONFIG_FILE} > /dev/null; then
                # 检查是否已存在路由规则
                if jq -e '.routing.rules' ${CONFIG_FILE} > /dev/null; then
                    jq --argjson rule_domain "$routing_rule_domain" --argjson rule_block "$routing_rule_block" \
                    '.routing.rules += [$rule_domain, $rule_block]' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
                    mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
                else
                    jq --argjson rule_domain "$routing_rule_domain" --argjson rule_block "$routing_rule_block" \
                    '.routing.rules = [$rule_domain, $rule_block]' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
                    mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
                fi
            else
                # 需要创建完整的路由配置
                routing_config=$(cat <<EOF
{
    "rules": [
        ${routing_rule_domain},
        ${routing_rule_block}
    ]
}
EOF
)
                jq --argjson routing "$routing_config" '.routing = $routing' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
                mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
            fi
            
            # 显示客户端配置信息
            echo -e "\n${GREEN}第 $i 个 REALITY 节点已添加成功!${PLAIN}"
            echo -e "${YELLOW}=== 客户端配置信息 ===${PLAIN}"
            echo -e "${GREEN}协议: VLESS${PLAIN}"
            echo -e "${GREEN}地址: $(curl -s https://api.ipify.org)${PLAIN}"
            echo -e "${GREEN}端口: ${port}${PLAIN}"
            echo -e "${GREEN}UUID: ${uuid}${PLAIN}"
            echo -e "${GREEN}流控: xtls-rprx-vision${PLAIN}"
            echo -e "${GREEN}传输协议: tcp${PLAIN}"
            echo -e "${GREEN}安全层: reality${PLAIN}"
            echo -e "${GREEN}SNI: ${server_name}${PLAIN}"
            echo -e "${GREEN}PublicKey: ${public_key}${PLAIN}"
            echo -e "${GREEN}ShortID: $(echo $short_ids_json | jq -r '.[1]')${PLAIN}"
            
            # 生成分享链接
            share_link="vless://${uuid}@$(curl -s https://api.ipify.org):${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=$(echo $short_ids_json | jq -r '.[1]')#REALITY-${port}"
            echo -e "${GREEN}分享链接: ${share_link}${PLAIN}"
        else
            echo -e "${RED}配置文件不存在，请先安装xray！${PLAIN}"
            return
        fi
    done
    
    # 重启xray服务应用所有更改
    echo -e "\n${GREEN}正在重启 Xray 服务应用所有更改...${PLAIN}"
    systemctl restart xray
    
    echo -e "${GREEN}所有 REALITY 节点已成功添加并应用！${PLAIN}"
}

# 添加 Shadowsocks 节点(单用户)
add_shadowsocks() {
    echo -e "${GREEN}添加 Shadowsocks 节点...${PLAIN}"
    
    # 获取端口
    read -p "请输入端口号 [默认: 8388]: " port
    port=${port:-8388}
    
    # 生成随机密码
    default_password=$(openssl rand -base64 16)
    read -p "请输入用户密码 [默认随机: ${default_password}]: " password
    password=${password:-$default_password}
    
    # 获取加密方法
    echo "请选择加密方法:"
    echo "1. aes-128-gcm"
    echo "2. aes-256-gcm (推荐)"
    echo "3. chacha20-poly1305"
    echo "4. 2022-blake3-aes-128-gcm"
    read -p "请选择 [1-4, 默认: 2]: " method_choice
    
    case $method_choice in
        1) method="aes-128-gcm" ;;
        3) method="chacha20-poly1305" ;;
        4) method="2022-blake3-aes-128-gcm" ;;
        *) method="aes-256-gcm" ;;
    esac
    
    # 更新配置文件
    if [[ -f ${CONFIG_FILE} ]]; then
        # 创建 Shadowsocks 配置
        ss_config=$(cat <<EOF
{
  "protocol": "shadowsocks",
  "port": ${port},
  "settings": {
    "method": "${method}",
    "password": "${password}",
    "network": "tcp,udp"
  }
}
EOF
)
        
        # 备份配置文件
        cp ${CONFIG_FILE} ${CONFIG_FILE}.bak
        
        # 添加新的入站配置
        jq --argjson new_inbound "$ss_config" '.inbounds += [$new_inbound]' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
        
        # 确保有必要的出站配置
        outbounds_config=$(cat <<EOF
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
)
        
        # 如果没有出站配置，添加默认出站配置
        jq --argjson outbounds "$outbounds_config" 'if (.outbounds | length) == 0 then .outbounds = $outbounds else . end' ${CONFIG_FILE}.tmp > ${CONFIG_FILE}.tmp2
        mv ${CONFIG_FILE}.tmp2 ${CONFIG_FILE}
        
        # 重启xray服务
        systemctl restart xray
        
        # 显示客户端配置信息
        echo -e "\n${GREEN}Shadowsocks 节点已添加成功!${PLAIN}"
        echo -e "${YELLOW}=== 客户端配置信息 ===${PLAIN}"
        echo -e "${GREEN}服务器地址: $(curl -s https://api.ipify.org)${PLAIN}"
        echo -e "${GREEN}端口: ${port}${PLAIN}"
        echo -e "${GREEN}密码: ${password}${PLAIN}"
        echo -e "${GREEN}加密方法: ${method}${PLAIN}"
        
        # 新增：询问用户输入IP和端口
        read -p "请输入要生成SS链接的服务器IP [默认: $(curl -s https://api.ipify.org)]: " custom_ip
        if [[ -z "$custom_ip" ]]; then
            custom_ip=$(curl -s https://api.ipify.org)
        fi
        read -p "请输入要生成SS链接的端口 [默认: ${port}]: " custom_port
        if [[ -z "$custom_port" ]]; then
            custom_port=${port}
        fi
        # 生成SS URI
        ss_uri=$(echo -n "${method}:${password}@${custom_ip}:${custom_port}" | base64 -w 0)
        echo -e "\n${GREEN}SS链接: ${PLAIN}ss://${ss_uri}#SS-${custom_port}-${method}"
    else
        echo -e "${RED}配置文件不存在，请先安装xray！${PLAIN}"
    fi
}

# 导出现有配置
export_config() {
    echo -e "${GREEN}导出现有节点配置...${PLAIN}"
    
    if [[ -f ${CONFIG_FILE} ]]; then
        # 获取入站配置数量
        inbound_count=$(jq '.inbounds | length' ${CONFIG_FILE})
        
        if [[ ${inbound_count} -eq 0 ]]; then
            echo -e "${YELLOW}当前没有配置任何节点！${PLAIN}"
            return
        fi
        
        echo -e "${YELLOW}当前配置的节点列表:${PLAIN}"
        
        # 显示节点列表
        declare -a node_list
        declare -a node_type
        
        # 使用专门的计数器来显示连续的索引
        count=0
        for ((i=0; i<${inbound_count}; i++)); do
            protocol=$(jq -r ".inbounds[$i].protocol" ${CONFIG_FILE})
            port=$(jq -r ".inbounds[$i].port" ${CONFIG_FILE})
            
            if [[ "$protocol" == "dokodemo-door" ]]; then
                tag=$(jq -r ".inbounds[$i].tag // \"\"" ${CONFIG_FILE})
                if [[ "$tag" == "dokodemo-in" || "$tag" =~ ^dokodemo-in-[0-9]+$ ]]; then
                    # REALITY节点的外部入口（支持单个和批量创建的节点）
                    internal_port=$(jq -r ".inbounds[$i].settings.port" ${CONFIG_FILE})
                    node_list+=($i)
                    node_type+=("reality")
                    echo -e "${GREEN}[${count}] REALITY节点 (外部端口: ${port})${PLAIN}"
                    count=$((count+1))
                else
                    node_list+=($i)
                    node_type+=("other")
                    echo -e "${GREEN}[${count}] ${protocol}节点 (端口: ${port})${PLAIN}"
                    count=$((count+1))
                fi
            elif [[ "$protocol" == "shadowsocks" ]]; then
                # Shadowsocks节点
                node_list+=($i)
                node_type+=("ss")
                echo -e "${GREEN}[${count}] Shadowsocks节点 (端口: ${port})${PLAIN}"
                count=$((count+1))
            elif [[ "$protocol" == "vless" ]]; then
                listen=$(jq -r ".inbounds[$i].listen // \"0.0.0.0\"" ${CONFIG_FILE})
                if [[ "$listen" == "127.0.0.1" ]]; then
                    # 这可能是REALITY的内部配置，跳过
                    continue
                else
                    node_list+=($i)
                    node_type+=("vless")
                    echo -e "${GREEN}[${count}] VLESS节点 (端口: ${port})${PLAIN}"
                    count=$((count+1))
                fi
            else
                node_list+=($i)
                node_type+=("other")
                echo -e "${GREEN}[${count}] ${protocol}节点 (端口: ${port})${PLAIN}"
                count=$((count+1))
            fi
        done
        
        if [[ ${#node_list[@]} -eq 0 ]]; then
            echo -e "${YELLOW}没有可导出的节点配置！${PLAIN}"
            return
        fi
        
        read -p "请选择要导出的节点 [0-$((${#node_list[@]}-1))]: " node_index
        
        # 验证输入
        if [[ ! "$node_index" =~ ^[0-9]+$ ]] || [[ $node_index -ge ${#node_list[@]} ]]; then
            echo -e "${RED}输入无效！请输入有效的节点编号。${PLAIN}"
            return
        fi
        
        selected_index=${node_list[$node_index]}
        selected_type=${node_type[$node_index]}
        
        echo -e "\n${YELLOW}===== 节点详细配置 =====${PLAIN}"
        
        # 根据节点类型获取详细配置
        if [[ "$selected_type" == "reality" ]]; then
            # REALITY节点
            port=$(jq -r ".inbounds[$selected_index].port" ${CONFIG_FILE})
            internal_port=$(jq -r ".inbounds[$selected_index].settings.port" ${CONFIG_FILE})
            
            # 查找对应的vless入站
            vless_index=-1
            for ((i=0; i<${inbound_count}; i++)); do
                protocol=$(jq -r ".inbounds[$i].protocol" ${CONFIG_FILE})
                inner_port=$(jq -r ".inbounds[$i].port" ${CONFIG_FILE})
                listen=$(jq -r ".inbounds[$i].listen // \"0.0.0.0\"" ${CONFIG_FILE})
                
                if [[ "$protocol" == "vless" && "$inner_port" == "$internal_port" && "$listen" == "127.0.0.1" ]]; then
                    vless_index=$i
                    break
                fi
            done
            
            if [[ $vless_index -ne -1 ]]; then
                uuid=$(jq -r ".inbounds[$vless_index].settings.clients[0].id" ${CONFIG_FILE})
                server_name=$(jq -r ".inbounds[$vless_index].streamSettings.realitySettings.serverNames[0]" ${CONFIG_FILE})
                public_key=$(jq -r ".inbounds[$vless_index].streamSettings.realitySettings.publicKey" ${CONFIG_FILE})
                short_id=$(jq -r ".inbounds[$vless_index].streamSettings.realitySettings.shortIds[1] // \"\"" ${CONFIG_FILE})
                
                echo -e "${GREEN}协议: ${PLAIN}VLESS+REALITY"
                echo -e "${GREEN}地址: ${PLAIN}$(curl -s https://api.ipify.org)"
                echo -e "${GREEN}端口: ${PLAIN}${port}"
                echo -e "${GREEN}UUID: ${PLAIN}${uuid}"
                echo -e "${GREEN}流控: ${PLAIN}xtls-rprx-vision"
                echo -e "${GREEN}传输协议: ${PLAIN}tcp"
                echo -e "${GREEN}安全层: ${PLAIN}reality"
                echo -e "${GREEN}SNI: ${PLAIN}${server_name}"
                echo -e "${GREEN}PublicKey: ${PLAIN}${public_key}"
                echo -e "${GREEN}ShortID: ${PLAIN}${short_id}"
                
                # 生成分享链接
                share_link="vless://${uuid}@$(curl -s https://api.ipify.org):${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}#REALITY-${port}"
                echo -e "\n${GREEN}分享链接: ${PLAIN}${share_link}"
            else
                echo -e "${RED}未找到对应的REALITY VLESS配置！${PLAIN}"
            fi
        elif [[ "$selected_type" == "ss" ]]; then
            # Shadowsocks节点
            port=$(jq -r ".inbounds[$selected_index].port" ${CONFIG_FILE})
            
            # 判断是单用户还是多用户
            if jq -e ".inbounds[$selected_index].settings.password" ${CONFIG_FILE} > /dev/null; then
                # 单用户配置
                method=$(jq -r ".inbounds[$selected_index].settings.method" ${CONFIG_FILE})
                password=$(jq -r ".inbounds[$selected_index].settings.password" ${CONFIG_FILE})
                
                echo -e "${GREEN}协议: ${PLAIN}Shadowsocks"
                echo -e "${GREEN}地址: ${PLAIN}$(curl -s https://api.ipify.org)"
                echo -e "${GREEN}端口: ${PLAIN}${port}"
                echo -e "${GREEN}密码: ${PLAIN}${password}"
                echo -e "${GREEN}加密方法: ${PLAIN}${method}"
                
                # 新增：询问用户输入IP和端口
                read -p "请输入要生成SS链接的服务器IP [默认: $(curl -s https://api.ipify.org)]: " custom_ip
                if [[ -z "$custom_ip" ]]; then
                    custom_ip=$(curl -s https://api.ipify.org)
                fi
                read -p "请输入要生成SS链接的端口 [默认: ${port}]: " custom_port
                if [[ -z "$custom_port" ]]; then
                    custom_port=${port}
                fi
                # 生成SS URI
                ss_uri=$(echo -n "${method}:${password}@${custom_ip}:${custom_port}" | base64 -w 0)
                echo -e "\n${GREEN}SS链接: ${PLAIN}ss://${ss_uri}#SS-${custom_port}-${method}"
            else
                # 多用户配置（保留兼容性）
                echo -e "${YELLOW}这是一个多用户Shadowsocks节点，已不再支持。${PLAIN}"
                echo -e "${YELLOW}原始配置如下:${PLAIN}"
                jq ".inbounds[$selected_index]" ${CONFIG_FILE}
            fi
        else
            # 其他节点类型，直接显示完整配置
            echo -e "${YELLOW}节点原始配置:${PLAIN}"
            jq ".inbounds[$selected_index]" ${CONFIG_FILE}
        fi
    else
        echo -e "${RED}配置文件不存在，请先安装xray！${PLAIN}"
    fi
}

# 删除节点
delete_node() {
    echo -e "${GREEN}删除节点...${PLAIN}"
    
    if [[ -f ${CONFIG_FILE} ]]; then
        # 获取入站配置数量
        inbound_count=$(jq '.inbounds | length' ${CONFIG_FILE})
        
        if [[ ${inbound_count} -eq 0 ]]; then
            echo -e "${YELLOW}当前没有配置任何节点！${PLAIN}"
            return
        fi
        
        # 创建节点列表，对配对的REALITY节点进行特殊处理
        declare -a node_list
        declare -a is_reality_pair
        declare -a reality_primary_index
        declare -a node_description
        
        # 首先检测REALITY节点对
        for ((i=0; i<${inbound_count}; i++)); do
            protocol=$(jq -r ".inbounds[$i].protocol" ${CONFIG_FILE})
            port=$(jq -r ".inbounds[$i].port" ${CONFIG_FILE})
            tag=$(jq -r ".inbounds[$i].tag // \"未命名\"" ${CONFIG_FILE})
            
            # 检查是否是dokodemo-door且是REALITY配置的一部分
            if [[ "$protocol" == "dokodemo-door" && ("$tag" == "dokodemo-in" || "$tag" =~ ^dokodemo-in-[0-9]+$) ]]; then
                # 查找关联的vless入站
                internal_port=$(jq -r ".inbounds[$i].settings.port" ${CONFIG_FILE})
                for ((j=0; j<${inbound_count}; j++)); do
                    if [[ $i -ne $j ]]; then
                        inner_protocol=$(jq -r ".inbounds[$j].protocol" ${CONFIG_FILE})
                        inner_port=$(jq -r ".inbounds[$j].port" ${CONFIG_FILE})
                        inner_listen=$(jq -r ".inbounds[$j].listen // \"0.0.0.0\"" ${CONFIG_FILE})
                        
                        # 检查是否为关联的vless REALITY入站
                        if [[ "$inner_protocol" == "vless" && "$inner_port" == "$internal_port" && "$inner_listen" == "127.0.0.1" ]]; then
                            security=$(jq -r ".inbounds[$j].streamSettings.security // \"none\"" ${CONFIG_FILE})
                            if [[ "$security" == "reality" ]]; then
                                # 找到REALITY配对
                                node_list+=($i)
                                is_reality_pair+=("true")
                                # 保存vless索引，以便后续删除时使用
                                reality_primary_index+=($j)
                                node_description+=("REALITY节点 [dokodemo-door端口:${port} + vless端口:${internal_port}]")
                                break
                            fi
                        fi
                    fi
                done
            elif [[ "$protocol" != "vless" || $(jq -r ".inbounds[$i].listen // \"0.0.0.0\"" ${CONFIG_FILE}) != "127.0.0.1" ]]; then
                # 不是REALITY节点的内部vless入站，添加到常规列表
                security=$(jq -r ".inbounds[$i].streamSettings.security // \"none\"" ${CONFIG_FILE})
                node_list+=($i)
                is_reality_pair+=("false")
                reality_primary_index+=(-1)
                node_description+=("${protocol}节点 [端口:${port}]")
            fi
        done
        
        echo -e "${YELLOW}当前配置的节点列表:${PLAIN}"
        
        # 显示可删除的节点
        for ((i=0; i<${#node_list[@]}; i++)); do
            echo -e "${GREEN}[$i] ${node_description[$i]}${PLAIN}"
        done
        
        read -p "请输入要删除的节点编号 [0-$((${#node_list[@]}-1))]: " delete_index
        
        # 验证输入
        if [[ ! "$delete_index" =~ ^[0-9]+$ ]] || [ "$delete_index" -ge "${#node_list[@]}" ]; then
            echo -e "${RED}输入无效！请输入有效的节点编号。${PLAIN}"
            return
        fi
        
        # 备份配置
        cp ${CONFIG_FILE} ${CONFIG_FILE}.bak
        
        # 获取对应的实际节点索引
        actual_index=${node_list[$delete_index]}
        
        # 检查是否是REALITY节点对
        if [[ "${is_reality_pair[$delete_index]}" == "true" ]]; then
            echo -e "${YELLOW}正在删除REALITY节点配对...${PLAIN}"
            
            # 找到dokodemo-door和对应的vless入站
            dokodemo_index=$actual_index
            vless_index=${reality_primary_index[$delete_index]}
            
            # 获取节点的tag来删除相应的路由规则
            dokodemo_tag=$(jq -r ".inbounds[$dokodemo_index].tag" ${CONFIG_FILE})
            internal_port=$(jq -r ".inbounds[$dokodemo_index].settings.port" ${CONFIG_FILE})
            
            # 获取删除前的配置内容，以创建临时配置
            temp_config=$(cat ${CONFIG_FILE})
            
            # 删除对应的路由规则 - 使用更精确的匹配
            server_name=$(jq -r ".inbounds[$vless_index].streamSettings.realitySettings.serverNames[0]" <<< "$temp_config")
            
            # 先删除与该节点相关的路由规则
            temp_config=$(jq "del(.routing.rules[] | select(.inboundTag != null and .inboundTag[0] == \"$dokodemo_tag\"))" <<< "$temp_config")
            
            # 删除入站配置 - 处理索引变化的情况
            if [[ $vless_index -lt $dokodemo_index ]]; then
                # 如果vless入站的索引小于dokodemo入站，先删除vless入站
                echo -e "${GREEN}删除vless配置 (索引: $vless_index)...${PLAIN}"
                temp_config=$(jq "del(.inbounds[$vless_index])" <<< "$temp_config")
                # dokodemo_index索引需要减1，因为前面已经删掉了一项
                dokodemo_index=$((dokodemo_index-1))
                echo -e "${GREEN}删除dokodemo配置 (调整后索引: $dokodemo_index)...${PLAIN}"
                temp_config=$(jq "del(.inbounds[$dokodemo_index])" <<< "$temp_config")
            else
                # 否则先删除dokodemo入站
                echo -e "${GREEN}删除dokodemo配置 (索引: $dokodemo_index)...${PLAIN}"
                temp_config=$(jq "del(.inbounds[$dokodemo_index])" <<< "$temp_config")
                # vless_index索引需要减1，因为前面已经删掉了一项
                vless_index=$((vless_index-1))
                echo -e "${GREEN}删除vless配置 (调整后索引: $vless_index)...${PLAIN}"
                temp_config=$(jq "del(.inbounds[$vless_index])" <<< "$temp_config")
            fi
            
            # 将修改后的配置写回文件
            echo "$temp_config" > ${CONFIG_FILE}
            
            echo -e "${GREEN}已成功删除REALITY节点配对 (dokodemo-door和vless入站)以及相关路由规则！${PLAIN}"
        else
            # 普通节点直接删除
            echo -e "${YELLOW}正在删除${node_description[$delete_index]}...${PLAIN}"
            jq "del(.inbounds[${actual_index}])" ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
            mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
            echo -e "${GREEN}节点已成功删除！${PLAIN}"
        fi
        
        # 重启xray服务
        systemctl restart xray
        echo -e "${GREEN}已重启Xray服务，更改已生效。${PLAIN}"
    else
        echo -e "${RED}配置文件不存在，请先安装xray！${PLAIN}"
    fi
}

# 查看 Xray 日志
view_log() {
    echo -e "${GREEN}查看 Xray 日志...${PLAIN}"
    
    echo "请选择要查看的日志类型:"
    echo "1. 访问日志 (access.log)"
    echo "2. 错误日志 (error.log)"
    read -p "请选择 [1-2]: " log_choice
    
    case "$log_choice" in
        1)
            if [ -f "${LOG_DIR}/access.log" ]; then
                echo -e "${YELLOW}最近50行访问日志:${PLAIN}"
                tail -n 50 ${LOG_DIR}/access.log
            else
                echo -e "${RED}访问日志文件不存在！${PLAIN}"
            fi
            ;;
        2)
            if [ -f "${LOG_DIR}/error.log" ]; then
                echo -e "${YELLOW}最近50行错误日志:${PLAIN}"
                tail -n 50 ${LOG_DIR}/error.log
            else
                echo -e "${RED}错误日志文件不存在！${PLAIN}"
            fi
            ;;
        *)
            echo -e "${RED}输入无效！${PLAIN}"
            ;;
    esac
}

toggle_node() {
    echo -e "${GREEN}启用/禁用节点...${PLAIN}"
    [[ ! -f ${CONFIG_FILE} ]] && { echo -e "${RED}请先安装 Xray！${PLAIN}"; return; }

    # 确保 disabled_inbounds 字段存在
    jq 'if .disabled_inbounds? == null then . + {disabled_inbounds: []} else . end' \
        ${CONFIG_FILE} > ${CONFIG_FILE}.tmp && mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}

    # 构建已启用节点列表（把 Reality 成对处理）
    declare -a desc_enabled key_enabled
    # 1) Reality 节点
    while read -r tag; do
        port=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t).port' ${CONFIG_FILE})
        desc_enabled+=("REALITY 外部端口:${port}")
        key_enabled+=("reality::$tag")
    done < <(jq -r '.inbounds[] | select(.protocol=="dokodemo-door") | .tag' ${CONFIG_FILE})
    # 2) Shadowsocks
    while read -r port; do
        desc_enabled+=("Shadowsocks 端口:${port}")
        key_enabled+=("ss::$port")
    done < <(jq -r '.inbounds[] | select(.protocol=="shadowsocks") | .port' ${CONFIG_FILE})
    # 3) 独立 VLESS（listen≠127.0.0.1）
    while read -r port; do
        desc_enabled+=("VLESS 端口:${port}")
        key_enabled+=("vless::$port")
    done < <(jq -r '.inbounds[] | select(.protocol=="vless" and (.listen//"0.0.0.0")!="127.0.0.1") | .port' ${CONFIG_FILE})

    # 构建已禁用节点列表，同上
    declare -a desc_disabled key_disabled
    while read -r tag; do
        port=$(jq -r --arg t "$tag" '.disabled_inbounds[]|select(.tag==$t).port' ${CONFIG_FILE})
        desc_disabled+=("REALITY 外部端口:${port}")
        key_disabled+=("reality::$tag")
    done < <(jq -r '.disabled_inbounds[] | select(.protocol=="dokodemo-door") | .tag' ${CONFIG_FILE})
    while read -r port; do
        desc_disabled+=("Shadowsocks 端口:${port}")
        key_disabled+=("ss::$port")
    done < <(jq -r '.disabled_inbounds[] | select(.protocol=="shadowsocks") | .port' ${CONFIG_FILE})
    while read -r port; do
        desc_disabled+=("VLESS 端口:${port}")
        key_disabled+=("vless::$port")
    done < <(jq -r '.disabled_inbounds[] | select(.protocol=="vless" and (.listen//"0.0.0.0")!="127.0.0.1") | .port' ${CONFIG_FILE})

    # 打印菜单
    echo -e "\n${YELLOW}已启用节点:${PLAIN}"
    for i in "${!desc_enabled[@]}"; do
        echo -e "  [${i}] ${desc_enabled[$i]}"
    done
    echo -e "\n${YELLOW}已禁用节点:${PLAIN}"
    for i in "${!desc_disabled[@]}"; do
        echo -e "  [${i}] ${desc_disabled[$i]}"
    done

    # 用户选择
    read -p $'\n请选择操作 ([e] 启用已禁用节点 / [d] 禁用已启用节点): ' act
    case "$act" in
        d)
            read -p "请输入要禁用的编号: " idx
            sel="${key_enabled[$idx]}"
            ;;
        e)
            read -p "请输入要启用的编号: " idx
            sel="${key_disabled[$idx]}"
            ;;
        *)
            echo -e "${YELLOW}操作已取消。${PLAIN}"
            return
            ;;
    esac

    type="${sel%%::*}"
    key="${sel##*::}"

    # 根据类型成对移动
    case "$type" in
        reality)
            # dokodemo-door 入站的 tag 是 key，先取出两段 JSON
            item1=$(jq --arg t "$key" '.inbounds? // .disabled_inbounds? | map(select(.tag==$t))[0]' ${CONFIG_FILE})
            internal_port=$(jq -r --arg t "$key" '.inbounds? // .disabled_inbounds? | map(select(.tag==$t))[0].settings.port' ${CONFIG_FILE})
            item2=$(jq --arg p "$internal_port" '.inbounds? // .disabled_inbounds? | map(select(.protocol=="vless" and .port==$p and (.listen//"")=="127.0.0.1"))[0]' ${CONFIG_FILE})

            if [[ "$act" == "d" ]]; then
                # 从 inbounds 移出，加入 disabled_inbounds
                jq --argjson a "$item1" --argjson b "$item2" '
                  .inbounds -= [$a, $b] |
                  .disabled_inbounds += [$a, $b]
                ' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
            else
                # 从 disabled_inbounds 移出，加入 inbounds
                jq --argjson a "$item1" --argjson b "$item2" '
                  .disabled_inbounds -= [$a, $b] |
                  .inbounds += [$a, $b]
                ' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
            fi
            ;;
        ss|vless)
            # 单条记录 操作 port == key
            if [[ "$act" == "d" ]]; then
                jq --arg p "$key" '
                  (.inbounds[] | select(.port|tostring==$p)) as $it |
                  .inbounds -= [$it] |
                  .disabled_inbounds += [$it]
                ' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
            else
                jq --arg p "$key" '
                  (.disabled_inbounds[] | select(.port|tostring==$p)) as $it |
                  .disabled_inbounds -= [$it] |
                  .inbounds += [$it]
                ' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
            fi
            ;;
    esac

    mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
    echo -e "${GREEN}操作完成，正在重启 Xray...${PLAIN}"
    systemctl restart xray
    echo -e "${GREEN}已重启，生效完成！${PLAIN}"
}

# 查看当前Xray配置
view_config() {
    echo -e "${GREEN}查看当前Xray配置...${PLAIN}"
    
    if [[ -f ${CONFIG_FILE} ]]; then
        # 检查jq是否安装
        if ! command -v jq &> /dev/null; then
            echo -e "${YELLOW}jq工具未安装，正在安装...${PLAIN}"
            if [[ $release = "centos" ]]; then
                yum install -y jq
            else
                apt update -y && apt install -y jq
            fi
        fi
        
        # 获取基本信息
        echo -e "${BLUE}基本配置信息:${PLAIN}"
        
        # 获取日志级别
        log_level=$(jq -r '.log.loglevel' ${CONFIG_FILE})
        echo -e "${GREEN}日志级别: ${log_level}${PLAIN}"
        
        # 获取日志路径
        access_log=$(jq -r '.log.access' ${CONFIG_FILE})
        error_log=$(jq -r '.log.error' ${CONFIG_FILE})
        echo -e "${GREEN}访问日志: ${access_log}${PLAIN}"
        echo -e "${GREEN}错误日志: ${error_log}${PLAIN}"
        
        # 获取入站配置
        inbound_count=$(jq '.inbounds | length' ${CONFIG_FILE})
        echo -e "\n${BLUE}入站配置 (${inbound_count}个):${PLAIN}"
        
        # 创建节点列表
        declare -a normal_nodes
        declare -a reality_nodes
        
        # 识别节点类型
        for ((i=0; i<${inbound_count}; i++)); do
            protocol=$(jq -r ".inbounds[$i].protocol" ${CONFIG_FILE})
            port=$(jq -r ".inbounds[$i].port" ${CONFIG_FILE})
            tag=$(jq -r ".inbounds[$i].tag // \"未命名\"" ${CONFIG_FILE})
            listen=$(jq -r ".inbounds[$i].listen // \"0.0.0.0\"" ${CONFIG_FILE})
            
            # 检查是否是REALITY配对的一部分（支持单个和批量创建的节点）
            if [[ "$protocol" == "dokodemo-door" && ("$tag" == "dokodemo-in" || "$tag" =~ ^dokodemo-in-[0-9]+$) ]]; then
                # 找到关联的vless配置
                internal_port=$(jq -r ".inbounds[$i].settings.port" ${CONFIG_FILE})
                for ((j=0; j<${inbound_count}; j++)); do
                    if [[ $i -ne $j ]]; then
                        inner_protocol=$(jq -r ".inbounds[$j].protocol" ${CONFIG_FILE})
                        inner_port=$(jq -r ".inbounds[$j].port" ${CONFIG_FILE})
                        inner_listen=$(jq -r ".inbounds[$j].listen // \"0.0.0.0\"" ${CONFIG_FILE})
                        
                        if [[ "$inner_protocol" == "vless" && "$inner_port" == "$internal_port" && "$inner_listen" == "127.0.0.1" ]]; then
                            security=$(jq -r ".inbounds[$j].streamSettings.security // \"none\"" ${CONFIG_FILE})
                            if [[ "$security" == "reality" ]]; then
                                # REALITY配对
                                server_name=$(jq -r ".inbounds[$j].streamSettings.realitySettings.serverNames[0]" ${CONFIG_FILE})
                                uuid=$(jq -r ".inbounds[$j].settings.clients[0].id" ${CONFIG_FILE})
                                public_key=$(jq -r ".inbounds[$j].streamSettings.realitySettings.publicKey" ${CONFIG_FILE})
                                short_id=$(jq -r ".inbounds[$j].streamSettings.realitySettings.shortIds[1] // \"\"" ${CONFIG_FILE})
                                
                                reality_info="协议: VLESS+REALITY, 外部端口: ${port}, UUID: ${uuid:0:8}..., SNI: ${server_name}"
                                reality_nodes+=("$reality_info")
                                break
                            fi
                        fi
                    fi
                done
            elif [[ "$protocol" != "vless" || "$listen" != "127.0.0.1" ]]; then
                # 普通节点
                if [[ "$protocol" == "shadowsocks" ]]; then
                    # 检查是单用户还是多用户
                    if jq -e ".inbounds[$i].settings.password" ${CONFIG_FILE} > /dev/null; then
                        # 单用户
                        method=$(jq -r ".inbounds[$i].settings.method" ${CONFIG_FILE})
                        node_info="协议: Shadowsocks(单用户), 端口: ${port}, 加密方式: ${method}"
                    else
                        # 多用户
                        clients_count=$(jq ".inbounds[$i].settings.clients | length" ${CONFIG_FILE})
                        node_info="协议: Shadowsocks(多用户-${clients_count}个), 端口: ${port}"
                    fi
                else
                    node_info="协议: ${protocol}, 端口: ${port}"
                fi
                normal_nodes+=("$node_info")
            fi
        done
        
        # 显示REALITY节点
        if [[ ${#reality_nodes[@]} -gt 0 ]]; then
            echo -e "${YELLOW}REALITY节点:${PLAIN}"
            for ((i=0; i<${#reality_nodes[@]}; i++)); do
                echo -e "${GREEN}  [$i] ${reality_nodes[$i]}${PLAIN}"
            done
        fi
        
        # 显示普通节点
        if [[ ${#normal_nodes[@]} -gt 0 ]]; then
            echo -e "${YELLOW}其他节点:${PLAIN}"
            for ((i=0; i<${#normal_nodes[@]}; i++)); do
                echo -e "${GREEN}  [$i] ${normal_nodes[$i]}${PLAIN}"
            done
        fi
        
        # 获取出站配置
        outbound_count=$(jq '.outbounds | length' ${CONFIG_FILE})
        echo -e "\n${BLUE}出站配置 (${outbound_count}个):${PLAIN}"
        
        for ((i=0; i<${outbound_count}; i++)); do
            protocol=$(jq -r ".outbounds[$i].protocol" ${CONFIG_FILE})
            tag=$(jq -r ".outbounds[$i].tag // \"未命名\"" ${CONFIG_FILE})
            echo -e "${GREEN}  [$i] 协议: ${protocol}, 标签: ${tag}${PLAIN}"
        done
        
        # 检查路由规则
        echo -e "\n${BLUE}路由规则:${PLAIN}"
        if jq -e '.routing.rules' ${CONFIG_FILE} > /dev/null; then
            rules_count=$(jq '.routing.rules | length' ${CONFIG_FILE})
            echo -e "${GREEN}  规则数量: ${rules_count}${PLAIN}"
            
            for ((i=0; i<${rules_count}; i++)); do
                inbound_tag=$(jq -r ".routing.rules[$i].inboundTag // []" ${CONFIG_FILE})
                outbound_tag=$(jq -r ".routing.rules[$i].outboundTag // \"未指定\"" ${CONFIG_FILE})
                domain=$(jq -r ".routing.rules[$i].domain // []" ${CONFIG_FILE})
                
                echo -e "${GREEN}  [$i] 入站标签: ${inbound_tag}, 出站标签: ${outbound_tag}${PLAIN}"
                if [[ "$domain" != "[]" ]]; then
                    echo -e "${GREEN}      域名: ${domain}${PLAIN}"
                fi
            done
        else
            echo -e "${YELLOW}  未配置路由规则${PLAIN}"
        fi
        
        # 显示查看完整配置的选项
        echo -e "\n${YELLOW}是否查看完整配置文件内容? [y/n]: ${PLAIN}"
        read view_full
        
        if [[ "$view_full" == "y" || "$view_full" == "Y" ]]; then
            echo -e "${BLUE}完整配置文件内容:${PLAIN}"
            cat ${CONFIG_FILE} | jq
        fi
        
    else
        echo -e "${RED}配置文件不存在，请先安装xray！${PLAIN}"
    fi
}

# 使用nano编辑器修改xray配置文件
edit_config() {
    echo -e "${GREEN}使用nano编辑器修改Xray配置文件...${PLAIN}"
    
    if [[ -f ${CONFIG_FILE} ]]; then
        # 检查nano是否安装
        if ! command -v nano &> /dev/null; then
            echo -e "${YELLOW}nano编辑器未安装，正在安装...${PLAIN}"
            if [[ $release = "centos" ]]; then
                yum install -y nano
            else
                apt update -y && apt install -y nano
            fi
        fi
        
        # 创建配置文件备份
        cp ${CONFIG_FILE} ${CONFIG_FILE}.bak_$(date +%Y%m%d%H%M%S)
        echo -e "${YELLOW}已创建配置文件备份: ${CONFIG_FILE}.bak_$(date +%Y%m%d%H%M%S)${PLAIN}"
        
        # 使用nano编辑配置文件
        echo -e "${YELLOW}按任意键开始编辑配置文件...${PLAIN}"
        read -n 1 -s
        nano ${CONFIG_FILE}
        
        # 检查配置文件是否有效的JSON
        if jq empty ${CONFIG_FILE} 2>/dev/null; then
            echo -e "${GREEN}配置文件验证成功！${PLAIN}"
            echo -e "${YELLOW}是否重启Xray服务应用修改？[y/n]: ${PLAIN}"
            read restart_service
            
            if [[ "$restart_service" == "y" || "$restart_service" == "Y" ]]; then
                echo -e "${GREEN}正在重启Xray服务...${PLAIN}"
                systemctl restart xray
                if systemctl is-active --quiet xray; then
                    echo -e "${GREEN}Xray服务已成功重启！${PLAIN}"
                else
                    echo -e "${RED}Xray服务重启失败，请检查配置是否正确！${PLAIN}"
                    echo -e "${YELLOW}是否恢复之前的备份？[y/n]: ${PLAIN}"
                    read restore_backup
                    
                    if [[ "$restore_backup" == "y" || "$restore_backup" == "Y" ]]; then
                        cp ${CONFIG_FILE}.bak_$(date +%Y%m%d%H%M%S) ${CONFIG_FILE}
                        systemctl restart xray
                        echo -e "${GREEN}已恢复配置文件并重启服务！${PLAIN}"
                    fi
                fi
            else
                echo -e "${YELLOW}配置已修改但未重启服务，修改尚未生效。${PLAIN}"
            fi
        else
            echo -e "${RED}配置文件JSON格式无效！${PLAIN}"
            echo -e "${YELLOW}是否恢复之前的备份？[y/n]: ${PLAIN}"
            read restore_backup
            
            if [[ "$restore_backup" == "y" || "$restore_backup" == "Y" ]]; then
                cp ${CONFIG_FILE}.bak_$(date +%Y%m%d%H%M%S) ${CONFIG_FILE}
                echo -e "${GREEN}已恢复配置文件！${PLAIN}"
            else
                echo -e "${RED}请手动修复配置文件，否则Xray可能无法正常启动！${PLAIN}"
            fi
        fi
    else
        echo -e "${RED}配置文件不存在，请先安装xray！${PLAIN}"
    fi
}

# 更新当前脚本
update_script() {
    echo -e "${GREEN}开始更新脚本...${PLAIN}"
    
    # 获取当前脚本路径
    SCRIPT_PATH=$(readlink -f "$0")
    
    # GitHub 上脚本的原始链接
    GITHUB_RAW_URL="https://raw.githubusercontent.com/wzxzwhy/enable-fq-bbr/main/xray.sh"
    
    echo -e "${YELLOW}正在从 GitHub 下载最新版本...${PLAIN}"
    
    # 备份当前脚本
    BACKUP_PATH="${SCRIPT_PATH}.bak_$(date +%Y%m%d%H%M%S)"
    cp "$SCRIPT_PATH" "$BACKUP_PATH"
    echo -e "${YELLOW}已创建备份: ${BACKUP_PATH}${PLAIN}"
    
    # 直接下载并替换当前脚本
    if curl -s -o "$SCRIPT_PATH" "$GITHUB_RAW_URL"; then
        chmod +x "$SCRIPT_PATH"
        echo -e "${GREEN}脚本已成功更新！${PLAIN}"
        echo -e "${YELLOW}请重新执行脚本以应用更新。${PLAIN}"
        exit 0
    else
        echo -e "${RED}下载更新失败，正在恢复备份...${PLAIN}"
        cp "$BACKUP_PATH" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo -e "${GREEN}已恢复到备份版本。${PLAIN}"
    fi
}

# 显示菜单
show_menu() {
    clear
    echo -e "
  ${GREEN}╔═══════════════════════════════════════════════╗${PLAIN}
  ${GREEN}║              Xray 一键管理脚本               ║${PLAIN}
  ${GREEN}╚═══════════════════════════════════════════════╝${PLAIN}
  ${GREEN}————————————————— 基础选项 —————————————————${PLAIN}
  ${GREEN}1.${PLAIN} 显示 Xray 状态
  ${GREEN}2.${PLAIN} 安装/更新 Xray
  ${GREEN}3.${PLAIN} 卸载 Xray
  ${GREEN}————————————————— 节点管理 —————————————————${PLAIN}
  ${GREEN}4.${PLAIN} 添加多个 REALITY 节点
  ${GREEN}5.${PLAIN} 添加 Shadowsocks 节点(单用户)
  ${GREEN}6.${PLAIN} 导出现有节点配置
  ${GREEN}7.${PLAIN} 删除节点
  ${GREEN}8.${PLAIN} 启用/禁用节点
  ${GREEN}9.${PLAIN} 查看 Xray 日志
  ${GREEN}10.${PLAIN} 查看当前 Xray 配置
  ${GREEN}11.${PLAIN} 修改 Xray 配置文件
  ${GREEN}————————————————— 其他选项 —————————————————${PLAIN}
  ${GREEN}12.${PLAIN} 更新当前脚本
  ${GREEN}0.${PLAIN} 退出脚本
    "
    echo && read -p "请输入选择 [0-11]: " num
    
    case "${num}" in
        0) exit 0 ;;
        1) check_xray_status ;;
        2) install_update_xray ;;
        3) uninstall_xray ;;
        4) add_multiple_reality ;;
        5) add_shadowsocks ;;
        6) export_config ;;
        7) delete_node ;;
        8) toggle_node ;;
        9) view_log ;;
        10) view_config ;;
        11) edit_config ;;
        12) update_script ;;
        *) echo -e "${RED}请输入正确的数字 [0-12]${PLAIN}" ;;
    esac
}

# 执行主函数
main() {
    # 检查标记文件是否存在
    INIT_MARK_FILE="/usr/local/etc/xray/.init_completed"
    
    # 如果标记文件不存在，则执行初始化操作
    if [ ! -f ${INIT_MARK_FILE} ]; then
        echo -e "${GREEN}首次运行，正在进行系统检查和依赖安装...${PLAIN}"
        check_os
        install_dependencies
        
        # 创建标记文件
        mkdir -p $(dirname ${INIT_MARK_FILE})
        touch ${INIT_MARK_FILE}
        echo "$(date)" > ${INIT_MARK_FILE}
        echo -e "${GREEN}初始化完成！${PLAIN}"
    fi
    
    while true; do
        show_menu
        echo ""
        echo -e "${YELLOW}按任意键继续...${PLAIN}"
        read -n 1 -s key
    done
}
main