#!/bin/bash

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

set -e

# 配置变量
SNELL_VERSION="5.0.1"
CONF_DIR="/etc/snell"
CONF_FILE="${CONF_DIR}/snell-server.conf"
BIN_PATH="/usr/local/bin/snell-server"
SYSTEMD_SERVICE="/etc/systemd/system/snell.service"

# 2. 架构检测
ARCH=$(uname -m)
case ${ARCH} in
    x86_64)  SNELL_ARCH="amd64" ;;
    aarch64) SNELL_ARCH="aarch64" ;;
    armv7l)  SNELL_ARCH="armv7l" ;;
    i386|i686) SNELL_ARCH="i386" ;;
    *) echo "Error: Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

# 3. 下载并安装二进制文件
DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${SNELL_ARCH}.zip"
echo "Downloading Snell v${SNELL_VERSION} for ${SNELL_ARCH}..."
wget -O snell.zip "${DOWNLOAD_URL}"
unzip -o snell.zip
chmod +x snell-server
mv snell-server "${BIN_PATH}"
rm -f snell.zip

# 4. 生成配置
mkdir -p "${CONF_DIR}"
if [ ! -f "${CONF_FILE}" ]; then
    # 随机生成 20 位 PSK
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    # 随机生成 10000-59999 之间的端口
    RANDOM_PORT=$(shuf -i 10000-59999 -n 1)
    
    cat > "${CONF_FILE}" <<EOF
[snell-server]
listen = 0.0.0.0:${RANDOM_PORT}
psk = ${RANDOM_PSK}
ipv6 = false
EOF
    echo "Generated new configuration."
else
    echo "Configuration file already exists, skipping generation."
fi

# 5. 创建 Systemd 服务
cat > "${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Snell
After=network.target

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=65535
ExecStart=${BIN_PATH} -c ${CONF_FILE}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 6. 启动服务
systemctl daemon-reload
systemctl enable snell
systemctl restart snell

IP=$(curl ip.sb)
PORT=$(grep 'listen' ${CONF_FILE} | cut -d: -f2)
PSK=$(grep 'psk' ${CONF_FILE} | cut -d'=' -f2 | tr -d ' ')
echo -e "\n---------------- 部署完成 ----------------"
echo -e "Surge/Clash 配置行："
echo -e "ss= snell, ${IP}, ${PORT}, psk = ${PSK}, version = 5, reuse = true, block-quic = on"
echo -e "------------------------------------------\n"