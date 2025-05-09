#!/bin/bash

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# 输出带颜色的文本
function red() {
    echo -e "${RED}$1${PLAIN}"
}

function green() {
    echo -e "${GREEN}$1${PLAIN}"
}

function yellow() {
    echo -e "${YELLOW}$1${PLAIN}"
}

function blue() {
    echo -e "${BLUE}$1${PLAIN}"
}

# 安装sudo
function installSudo() {
    yellow "安装sudo..."
    apt install sudo -y
    if [ $? -ne 0 ]; then
        red "sudo安装失败，请检查错误信息"
        exit 1
    else
        green "sudo安装成功!"
    fi
}

# 安装acme.sh
function installAcme() {
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        yellow "安装acme.sh..."
        curl https://get.acme.sh | sh
        if [ $? -ne 0 ]; then
            red "acme.sh安装失败，请检查错误信息"
            exit 1
        fi
    else
        yellow "acme.sh已安装，更新到最新版本"
        ~/.acme.sh/acme.sh --upgrade
    fi
    
    # 添加软链接
    ln -s  /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
    
    # 切换CA机构
    acme.sh --set-default-ca --server letsencrypt
}

# 设置Cloudflare API凭证
function setCFAPI() {
    if [ -z "$CF_Key" ] || [ -z "$CF_Email" ]; then
        yellow "请设置Cloudflare API凭证"
        read -p "请输入Cloudflare Global API Key: " CF_Key
        read -p "请输入Cloudflare 邮箱: " CF_Email
        
        if [ -z "$CF_Key" ] || [ -z "$CF_Email" ]; then
            red "Cloudflare凭证不能为空"
            exit 1
        fi
        
        export CF_Key="$CF_Key"
        export CF_Email="$CF_Email"
    fi
}

# 申请证书
function issueSSL() {
    yellow "开始申请SSL证书"
    read -p "请输入域名: " domain
    
    if [ -z "$domain" ]; then
        red "域名不能为空"
        exit 1
    fi
    
    # 使用API模式申请证书
    acme.sh --issue --dns dns_cf -d "$domain"
    
    # 安装证书到指定目录，不添加重载命令，因为nginx可能尚未安装
    acme.sh --install-cert -d "$domain" --ecc \
        --key-file /etc/ssl/private/private.key  \
        --fullchain-file /etc/ssl/private/fullchain.cer \
        --reloadcmd "systemctl force-reload nginx"
    
}

# 安装Nginx
function installNginx() {
    yellow "开始安装Nginx..."
    
    sudo apt update && sudo apt upgrade -y && apt-get install -y gcc g++ libpcre3 libpcre3-dev zlib1g zlib1g-dev openssl libssl-dev wget sudo make curl socat cron && wget https://nginx.org/download/nginx-1.27.1.tar.gz && tar -xvf nginx-1.27.1.tar.gz && cd nginx-1.27.1 && ./configure --prefix=/usr/local/nginx --sbin-path=/usr/sbin/nginx --conf-path=/etc/nginx/nginx.conf --with-http_stub_status_module --with-http_ssl_module --with-http_realip_module --with-http_sub_module --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module --with-http_v2_module && make && make install && cd
    
    
    # 创建nginx systemd服务文件
    yellow "创建nginx.service文件..."
    cat > /lib/systemd/system/nginx.service << EOF
[Unit]
Description=A high performance web server and a reverse proxy server
Documentation=man:nginx(8)
After=network.target nss-lookup.target

[Service]
Type=forking
PIDFile=/usr/local/nginx/logs/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile /run/nginx.pid
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载systemd配置
    systemctl daemon-reload && systemctl enable nginx.service
}

# 配置Nginx
function configureNginx() {
    yellow "开始配置Nginx..."
    
    # 获取之前保存的域名
    if [ -f "/tmp/domain_name.txt" ]; then
        domain=$(cat /tmp/domain_name.txt)
    else
        read -p "请输入已申请证书的域名: " domain
        if [ -z "$domain" ]; then
            red "域名不能为空"
            exit 1
        fi
    fi
    
    
    # 读取用户输入
    read -p "请输入要反向代理的目标网站(默认为www.lovelive-anime.jp): " targetSite
    targetSite=${targetSite:-www.lovelive-anime.jp}
    
    # 创建Nginx配置文件
    cat > /etc/nginx/nginx.conf << EOF
user nginx;
worker_processes auto;

error_log /usr/local/nginx/logs/error.log notice;
pid /usr/local/nginx/logs/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format main '[\$time_local] \$proxy_protocol_addr "\$http_referer" "\$http_user_agent"';
    access_log /usr/local/nginx/logs/access.log main;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ""      close;
    }

    map \$proxy_protocol_addr \$proxy_forwarded_elem {
        ~^[0-9.]+\$        "for=\$proxy_protocol_addr";
        ~^[0-9A-Fa-f:.]+\$ "for=\"[\$proxy_protocol_addr]\"";
        default           "for=unknown";
    }

    map \$http_forwarded \$proxy_add_forwarded {
        "~^(,[ \\t]*)*([!#\$%&'*+.^_\`|~0-9A-Za-z-]+=([!#\$%&'*+.^_\`|~0-9A-Za-z-]+|\"([\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\t \\x21-\\x7E\\x80-\\xFF])*\"))?(;([!#\$%&'*+.^_\`|~0-9A-Za-z-]+=([!#\$%&'*+.^_\`|~0-9A-Za-z-]+|\"([\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\t \\x21-\\x7E\\x80-\\xFF])*\"))?)*([ \\t]*,([ \\t]*([!#\$%&'*+.^_\`|~0-9A-Za-z-]+=([!#\$%&'*+.^_\`|~0-9A-Za-z-]+|\"([\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\t \\x21-\\x7E\\x80-\\xFF])*\"))?(;([!#\$%&'*+.^_\`|~0-9A-Za-z-]+=([!#\$%&'*+.^_\`|~0-9A-Za-z-]+|\"([\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\t \\x21-\\x7E\\x80-\\xFF])*\"))?)*)?)*\$" "\$http_forwarded, \$proxy_forwarded_elem";
        default "\$proxy_forwarded_elem";
    }

    server {
        listen 80;
        listen [::]:80;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen                  127.0.0.1:8003 ssl default_server;

        ssl_reject_handshake    on;

        ssl_protocols           TLSv1.2 TLSv1.3;

        ssl_session_timeout     1h;
        ssl_session_cache       shared:SSL:10m;

        ssl_early_data          on;
    }

    server {
        listen                     127.0.0.1:8003 ssl proxy_protocol;
        http2                      on;
        set_real_ip_from           127.0.0.1;
        real_ip_header             proxy_protocol;

        server_name                $domain; # 填由 Nginx 加载的 SSL 证书中包含的域名，建议将域名指向服务端的 IP

        ssl_certificate            /etc/ssl/private/fullchain.cer;
        ssl_certificate_key        /etc/ssl/private/private.key;

        ssl_protocols              TLSv1.2 TLSv1.3;
        ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;

        ssl_session_tickets        on;

        ssl_stapling               on;
        ssl_stapling_verify        on;
        resolver                   1.1.1.1 valid=60s;
        resolver_timeout           2s;

        location / {
            sub_filter                            \$proxy_host \$host;
            sub_filter_once                       off;

            set \$website                          $targetSite;
            proxy_pass                            https://\$website;
            resolver                              1.1.1.1;

            proxy_set_header Host                 \$proxy_host;

            proxy_http_version                    1.1;
            proxy_cache_bypass                    \$http_upgrade;

            proxy_ssl_server_name                 on;

            proxy_set_header Upgrade              \$http_upgrade;
            proxy_set_header Connection           \$connection_upgrade;
            proxy_set_header X-Real-IP            \$proxy_protocol_addr;
            proxy_set_header Forwarded            \$proxy_add_forwarded;
            proxy_set_header X-Forwarded-For      \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto    \$scheme;
            proxy_set_header X-Forwarded-Host     \$host;
            proxy_set_header X-Forwarded-Port     \$server_port;

            proxy_connect_timeout                 60s;
            proxy_send_timeout                    60s;
            proxy_read_timeout                    60s;

            proxy_set_header Early-Data           \$ssl_early_data;
        }
    }
}
EOF

    # 检查配置文件是否正确
    nginx -t
    if [ $? -ne 0 ]; then
        red "Nginx配置文件有误，请检查"
        exit 1
    fi
    
    # 重启Nginx
    systemctl daemon-reload && systemctl enable nginx.service
    
    # 检查Nginx是否运行
    systemctl status nginx | grep "active (running)" > /dev/null
    if [ $? -eq 0 ]; then
        green "Nginx配置完成并成功启动!"
        green "您的网站已经可以通过 https://$domain 访问"
        yellow "该域名可以作为Reality的dest参数"
        yellow "注意：请确保您的域名已正确解析到服务器IP，且防火墙已放行80和443端口"
    else
        red "Nginx启动失败，请查看日志检查错误"
    fi
}

# 安装Xray

# 主函数
function main() {
    yellow "Reality自动部署脚本 (偷自己证书版)"
    yellow "适用于已有域名的Reality部署"
    echo "-------------------------------------"
    
    echo "请选择要执行的操作:"
    echo "1. 安装sudo"
    echo "2. 申请SSL证书"
    echo "3. 安装并配置Nginx"
    echo "4. 全部执行(sudo+证书+Nginx)"
    read -p "请输入选项[1-4]: " choice
    
    case "$choice" in
        1)
            installSudo
            ;;
        2)
            installAcme
            setCFAPI
            issueSSL
            ;;
        3)
            installNginx
            configureNginx
            ;;
        4)
            installSudo
            installAcme
            setCFAPI
            issueSSL
            installNginx
            configureNginx
            ;;
        *)
            red "无效选项，请重新运行脚本"
            exit 1
            ;;
    esac
}

main
