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
    
    # 如果配置文件不存在，创建一个基本配置
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

# 添加 Shadowsocks 节点(单用户)
add_shadowsocks() {
    echo -e "${GREEN}添加 Shadowsocks 节点...${PLAIN}"
    
    # 获取端口
    read -p "请输入端口号 [默认: 8388]: " port
    port=${port:-8388}
    
    # 生成随机密码
    default_password=$(openssl rand -base64 12)
    read -p "请输入用户密码 [默认随机: ${default_password}]: " password
    password=${password:-$default_password}
    
    # 获取加密方法
    echo "请选择加密方法:"
    echo "1. aes-128-gcm"
    echo "2. aes-256-gcm (推荐)"
    echo "3. chacha20-poly1305"
    read -p "请选择 [1-3, 默认: 2]: " method_choice
    
    case $method_choice in
        1) method="aes-128-gcm" ;;
        3) method="chacha20-poly1305" ;;
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
        
        # 生成SS URI
        ss_uri=$(echo -n "${method}:${password}@$(curl -s https://api.ipify.org):${port}" | base64 -w 0)
        echo -e "${GREEN}SS链接: ss://${ss_uri}#SS-${port}-${method}${PLAIN}"
    else
        echo -e "${RED}配置文件不存在，请先安装xray！${PLAIN}"
    fi
}

# 添加 Shadowsocks 节点(多用户)
add_shadowsocks_multi() {
    echo -e "${GREEN}添加多用户 Shadowsocks 节点...${PLAIN}"
    
    # 获取端口
    read -p "请输入端口号 [默认: 12345]: " port
    port=${port:-12345}
    
    # 初始化用户数组
    users_json="[]"
    
    # 询问用户数量
    read -p "请输入要添加的用户数量 [默认: 1]: " user_count
    user_count=${user_count:-1}
    
    # 添加用户
    for ((i=1; i<=user_count; i++)); do
        echo -e "\n${YELLOW}配置第 $i 个用户${PLAIN}"
        
        # 生成随机密码
        default_password=$(openssl rand -base64 12)
        read -p "请输入用户密码 [默认随机: ${default_password}]: " user_password
        user_password=${user_password:-$default_password}
        
        # 获取加密方法
        echo "请选择加密方法:"
        echo "1. aes-128-gcm"
        echo "2. aes-256-gcm (推荐)"
        echo "3. chacha20-poly1305"
        read -p "请选择 [1-3, 默认: 2]: " method_choice
        
        case $method_choice in
            1) method="aes-128-gcm" ;;
            3) method="chacha20-poly1305" ;;
            *) method="aes-256-gcm" ;;
        esac
        
        # 添加用户到JSON数组
        user_json=$(jq -n \
            --arg pwd "$user_password" \
            --arg mth "$method" \
            '{password: $pwd, method: $mth}')
        
        # 合并到用户数组
        users_json=$(echo $users_json | jq --argjson user "$user_json" '. += [$user]')
    done
    
    # 更新配置文件
    if [[ -f ${CONFIG_FILE} ]]; then
        # 创建 Shadowsocks 多用户配置
        ss_config=$(cat <<EOF
{
  "protocol": "shadowsocks",
  "port": ${port},
  "settings": {
    "clients": ${users_json},
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
        echo -e "\n${GREEN}多用户 Shadowsocks 节点已添加成功!${PLAIN}"
        echo -e "${YELLOW}=== 客户端配置信息 ===${PLAIN}"
        echo -e "${GREEN}服务器地址: $(curl -s https://api.ipify.org)${PLAIN}"
        echo -e "${GREEN}端口: ${port}${PLAIN}"
        
        # 显示每个用户的配置
        echo $users_json | jq -c '.[]' | while read -r user; do
            user_pwd=$(echo $user | jq -r '.password')
            user_method=$(echo $user | jq -r '.method')
            
            echo -e "\n${YELLOW}用户配置${PLAIN}"
            echo -e "${GREEN}密码: ${user_pwd}${PLAIN}"
            echo -e "${GREEN}加密方法: ${user_method}${PLAIN}"
            
            # 生成SS URI
            ss_uri=$(echo -n "${user_method}:${user_pwd}@$(curl -s https://api.ipify.org):${port}" | base64 -w 0)
            echo -e "${GREEN}SS链接: ss://${ss_uri}#SS-${port}-${user_method}${PLAIN}"
        done
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
        
        # 创建导出目录
        export_dir="/root/xray_config_export"
        mkdir -p ${export_dir}
        
        for ((i=0; i<${inbound_count}; i++)); do
            protocol=$(jq -r ".inbounds[$i].protocol" ${CONFIG_FILE})
            port=$(jq -r ".inbounds[$i].port" ${CONFIG_FILE})
            
            echo -e "${GREEN}[$i] 协议: ${protocol}, 端口: ${port}${PLAIN}"
            
            # 导出详细配置到文件
            jq ".inbounds[$i]" ${CONFIG_FILE} > ${export_dir}/node_${i}_${protocol}_${port}.json
            
            # 生成客户端配置信息
            if [[ "$protocol" == "vless" ]]; then
                security=$(jq -r ".inbounds[$i].streamSettings.security" ${CONFIG_FILE})
                
                # 针对REALITY配置生成客户端信息
                if [[ "$security" == "reality" ]]; then
                    uuid=$(jq -r ".inbounds[$i].settings.clients[0].id" ${CONFIG_FILE})
                    server_name=$(jq -r ".inbounds[$i].streamSettings.realitySettings.serverNames[0]" ${CONFIG_FILE})
                    private_key=$(jq -r ".inbounds[$i].streamSettings.realitySettings.privateKey" ${CONFIG_FILE})
                    short_id=$(jq -r ".inbounds[$i].streamSettings.realitySettings.shortIds[1]" ${CONFIG_FILE})
                    
                    # 通过私钥计算公钥
                    public_key=$(jq -r ".inbounds[$i].streamSettings.realitySettings.publicKey" ${CONFIG_FILE})
                    
                    echo -e "\n${YELLOW}==== REALITY 客户端配置 ====${PLAIN}" > ${export_dir}/client_${i}_reality.txt
                    echo -e "协议: VLESS" >> ${export_dir}/client_${i}_reality.txt
                    echo -e "地址: $(curl -s https://api.ipify.org)" >> ${export_dir}/client_${i}_reality.txt
                    echo -e "端口: ${port}" >> ${export_dir}/client_${i}_reality.txt
                    echo -e "UUID: ${uuid}" >> ${export_dir}/client_${i}_reality.txt
                    echo -e "流控: xtls-rprx-vision" >> ${export_dir}/client_${i}_reality.txt
                    echo -e "传输协议: tcp" >> ${export_dir}/client_${i}_reality.txt
                    echo -e "安全层: reality" >> ${export_dir}/client_${i}_reality.txt
                    echo -e "SNI: ${server_name}" >> ${export_dir}/client_${i}_reality.txt
                    echo -e "PublicKey: ${public_key}" >> ${export_dir}/client_${i}_reality.txt
                    echo -e "ShortID: ${short_id}" >> ${export_dir}/client_${i}_reality.txt
                    
                    echo -e "${GREEN}已导出 REALITY 客户端配置到 ${export_dir}/client_${i}_reality.txt${PLAIN}"
                    
                    # 生成分享链接
                    share_link="vless://${uuid}@$(curl -s https://api.ipify.org):${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}#REALITY-${port}"
                    echo -e "${GREEN}分享链接: ${share_link}${PLAIN}" >> ${export_dir}/client_${i}_reality.txt
                fi
            elif [[ "$protocol" == "shadowsocks" ]]; then
                method=$(jq -r ".inbounds[$i].settings.method" ${CONFIG_FILE})
                password=$(jq -r ".inbounds[$i].settings.password" ${CONFIG_FILE})
                
                echo -e "\n${YELLOW}==== Shadowsocks 客户端配置 ====${PLAIN}" > ${export_dir}/client_${i}_ss.txt
                echo -e "地址: $(curl -s https://api.ipify.org)" >> ${export_dir}/client_${i}_ss.txt
                echo -e "端口: ${port}" >> ${export_dir}/client_${i}_ss.txt
                echo -e "密码: ${password}" >> ${export_dir}/client_${i}_ss.txt
                echo -e "加密方法: ${method}" >> ${export_dir}/client_${i}_ss.txt
                
                echo -e "${GREEN}已导出 Shadowsocks 客户端配置到 ${export_dir}/client_${i}_ss.txt${PLAIN}"
                
                # 生成SS URI
                ss_uri=$(echo -n "${method}:${password}@$(curl -s https://api.ipify.org):${port}" | base64 -w 0)
                echo -e "${GREEN}SS链接: ss://${ss_uri}#SS-${port}${PLAIN}" >> ${export_dir}/client_${i}_ss.txt
            fi
        done
        
        echo -e "\n${GREEN}所有配置已导出至 ${export_dir} 目录！${PLAIN}"
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
        
        echo -e "${YELLOW}当前配置的节点列表:${PLAIN}"
        
        for ((i=0; i<${inbound_count}; i++)); do
            protocol=$(jq -r ".inbounds[$i].protocol" ${CONFIG_FILE})
            port=$(jq -r ".inbounds[$i].port" ${CONFIG_FILE})
            
            echo -e "${GREEN}[$i] 协议: ${protocol}, 端口: ${port}${PLAIN}"
        done
        
        read -p "请输入要删除的节点编号 [0-$((inbound_count-1))]: " node_index
        
        # 验证输入
        if [[ ! "$node_index" =~ ^[0-9]+$ ]] || [ "$node_index" -ge "$inbound_count" ]; then
            echo -e "${RED}输入无效！请输入有效的节点编号。${PLAIN}"
            return
        fi
        
        # 备份配置
        cp ${CONFIG_FILE} ${CONFIG_FILE}.bak
        
        # 删除指定的入站配置
        jq "del(.inbounds[$node_index])" ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
        mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}
        
        # 重启xray服务
        systemctl restart xray
        
        echo -e "${GREEN}节点已成功删除！${PLAIN}"
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
  ${GREEN}4.${PLAIN} 添加 REALITY 节点
  ${GREEN}5.${PLAIN} 添加 Shadowsocks 节点(单用户)
  ${GREEN}6.${PLAIN} 添加 Shadowsocks 节点(多用户)
  ${GREEN}7.${PLAIN} 导出现有节点配置
  ${GREEN}8.${PLAIN} 删除节点
  ${GREEN}9.${PLAIN} 查看 Xray 日志
  ${GREEN}————————————————— 其他选项 —————————————————${PLAIN}
  ${GREEN}0.${PLAIN} 退出脚本
    "
    echo && read -p "请输入选择 [0-7]: " num
    
    case "${num}" in
        0) exit 0 ;;
        1) check_xray_status ;;
        2) install_update_xray ;;
        3) uninstall_xray ;;
        4) add_reality ;;
        5) add_shadowsocks ;;
        6) add_shadowsocks_multi ;;
        7) export_config ;;
        *) echo -e "${RED}请输入正确的数字 [0-7]${PLAIN}" ;;
    esac
}

# 执行主函数
# 主函数
main() {
    check_os
    install_dependencies
    
    while true; do
        show_menu
        echo ""
        echo -e "${YELLOW}按任意键继续...${PLAIN}"
        read -n 1 -s key
    done
}
main
