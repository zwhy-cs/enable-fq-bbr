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
    
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    if [ $? -ne 0 ]; then
        red "设置默认CA失败，请检查错误信息"
        exit 1
    fi
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
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --force
    
    if [ $? -ne 0 ]; then
        red "证书申请失败，请检查域名和API设置是否正确"
        exit 1
    else
        green "证书申请成功!"
    fi
    
    # 创建证书目录
    certDir="/root/cert/$domain"
    mkdir -p $certDir
    
    # 安装证书到指定目录
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file       $certDir/private.key  \
        --fullchain-file $certDir/fullchain.crt
    
    if [ $? -eq 0 ]; then
        green "证书已安装至 $certDir"
        yellow "私钥路径: $certDir/private.key"
        yellow "证书路径: $certDir/fullchain.crt"
        
        # 设置证书自动续期并配置续期后的部署脚本
        yellow "配置证书自动续期..."
        cat > ~/renew-cert.sh << RENEW
#!/bin/bash
cp $certDir/private.key /etc/ssl/private/private.key
cp $certDir/fullchain.crt /etc/ssl/private/fullchain.cer
systemctl restart nginx
RENEW
        chmod +x ~/renew-cert.sh
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        ~/.acme.sh/acme.sh --renew -d "$domain" --force --renew-hook "~/renew-cert.sh"
        
        green "证书自动续期已配置，将每60天自动续期一次"
        
        # 保存域名变量供后续使用
        echo "$domain" > /tmp/domain_name.txt
    else
        red "证书安装失败，请检查错误信息"
        exit 1
    fi
}

# 安装Nginx
function installNginx() {
    yellow "开始安装Nginx..."
    
    if [ "$release" == "centos" ]; then
        sudo apt update && sudo apt upgrade -y && apt-get install -y gcc g++ libpcre3 libpcre3-dev zlib1g zlib1g-dev openssl libssl-dev wget sudo make curl socat cron && wget https://nginx.org/download/nginx-1.27.1.tar.gz && tar -xvf nginx-1.27.1.tar.gz && cd nginx-1.27.1 && ./configure --prefix=/usr/local/nginx --sbin-path=/usr/sbin/nginx --conf-path=/etc/nginx/nginx.conf --with-http_stub_status_module --with-http_ssl_module --with-http_realip_module --with-http_sub_module --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module --with-http_v2_module && make && make install && cd
    else
        sudo apt update && sudo apt upgrade -y && apt-get install -y gcc g++ libpcre3 libpcre3-dev zlib1g zlib1g-dev openssl libssl-dev wget sudo make curl socat cron && wget https://nginx.org/download/nginx-1.27.1.tar.gz && tar -xvf nginx-1.27.1.tar.gz && cd nginx-1.27.1 && ./configure --prefix=/usr/local/nginx --sbin-path=/usr/sbin/nginx --conf-path=/etc/nginx/nginx.conf --with-http_stub_status_module --with-http_ssl_module --with-http_realip_module --with-http_sub_module --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module --with-http_v2_module && make && make install && cd
    fi
    
    if [ $? -ne 0 ]; then
        red "Nginx安装失败，请检查错误信息"
        exit 1
    fi
    
    # 创建nginx systemd服务文件
    yellow "创建nginx.service文件..."
    cat > /etc/systemd/system/nginx.service << EOF
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
    systemctl daemon-reload
    
    systemctl enable nginx
    
    green "Nginx安装成功!"
    
    # 创建Nginx日志目录
    mkdir -p /usr/local/nginx/logs/
    
    # 检查目录是否存在
    if [ ! -d "/etc/nginx/conf.d" ]; then
        mkdir -p /etc/nginx/conf.d
    fi
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
    
    # 检查证书文件是否存在
    certDir="/root/cert/$domain"
    if [ ! -f "$certDir/private.key" ] || [ ! -f "$certDir/fullchain.crt" ]; then
        red "证书文件不存在，请先申请证书"
        exit 1
    fi
    
    # 创建证书目录
    mkdir -p /etc/ssl/private/
    cp $certDir/private.key /etc/ssl/private/private.key
    cp $certDir/fullchain.crt /etc/ssl/private/fullchain.cer
    
    # 读取用户输入
    read -p "请输入要反向代理的目标网站(默认为www.lovelive-anime.jp): " targetSite
    targetSite=${targetSite:-www.lovelive-anime.jp}
    
    # 安装GeoIP依赖
    yellow "安装GeoIP依赖..."
    apt-get update && apt-get install -y geoip-database libgeoip-dev

    # 创建Nginx配置文件
    cat > /etc/nginx/nginx.conf << EOF
user root;
worker_processes auto;

error_log /usr/local/nginx/logs/error.log notice;
pid /usr/local/nginx/logs/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format main '[\$time_local] \$proxy_protocol_addr "\$http_referer" "\$http_user_agent"';
    access_log /usr/local/nginx/logs/access.log main;

    # 加载GeoIP模块
    geoip_country /usr/share/GeoIP/GeoIP.dat;

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
        listen                     127.0.0.1:8003 ssl http2 proxy_protocol;

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
            # 禁止中国大陆IP访问
            if ($geoip_country_code = "CN") {
                return 403;
            }
            
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
    systemctl restart nginx
    
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

# 主函数
function main() {
    yellow "Cloudflare API SSL证书自动申请与Nginx配置脚本"
    yellow "适用于Reality的dest域名配置"
    echo "-------------------------------------"
    
    echo "请选择要执行的操作:"
    echo "1. 申请SSL证书"
    echo "2. 安装并配置Nginx"
    echo "3. 全部执行(申请证书+安装配置Nginx)"
    echo "4. 仅配置Nginx(已有证书)"
    read -p "请输入选项[1-4]: " choice
    
    case "$choice" in
        1)
            installAcme
            setCFAPI
            issueSSL
            ;;
        2)
            installNginx
            configureNginx
            ;;
        3)
            installAcme
            setCFAPI
            issueSSL
            installNginx
            configureNginx
            ;;
        4)
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
