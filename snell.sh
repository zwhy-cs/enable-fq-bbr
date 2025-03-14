#!/bin/bash
# 一键安装 Snell v4 脚本（自动生成 PSK）
# 请确保在 root 权限下运行

set -e

# 配置变量（请根据实际情况修改）
SNELL_VERSION="4.0.0"  # 请确认版本号是否正确
# 注意：下面的下载链接请根据 GitHub 上 Snell 的最新版本调整
SNELL_DOWNLOAD_URL="https://github.com/snell/snell/releases/download/v${SNELL_VERSION}/snell-server-v${SNELL_VERSION}-linux-amd64.tar.gz"
INSTALL_DIR="/usr/local/bin"
CONFIG_FILE="/etc/snell.conf"
SYSTEMD_SERVICE="/etc/systemd/system/snell.service"
LOG_FILE="/var/log/snell.log"

# 获取用户输入的监听端口，默认8388
read -p "请输入监听端口(默认8388): " PORT
PORT=${PORT:-8388}

# 自动生成预共享密钥（PSK）
if ! command -v openssl &>/dev/null; then
    echo "错误：系统中未安装 openssl，请先安装 openssl 后重试。"
    exit 1
fi
PSK=$(openssl rand -hex 16)
echo "自动生成的预共享密钥(PSK)为: ${PSK}"

echo "开始安装 Snell v4..."

# 创建临时目录并下载 Snell 二进制文件
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
echo "正在下载 Snell v${SNELL_VERSION}..."
curl -L -o snell.tar.gz "$SNELL_DOWNLOAD_URL"

# 解压下载的文件
tar -xzf snell.tar.gz

# 检查并移动可执行文件
if [ -f "snell-server" ]; then
    mv snell-server ${INSTALL_DIR}/snell-server
    chmod +x ${INSTALL_DIR}/snell-server
else
    echo "错误：未找到 snell-server 可执行文件，请检查下载链接和版本号。"
    exit 1
fi

# 清理临时目录
cd /
rm -rf "$TMP_DIR"

# 生成配置文件
echo "正在创建配置文件 ${CONFIG_FILE}..."
cat > ${CONFIG_FILE} <<EOF
{
    "listen": ":${PORT}",
    "psk": "${PSK}",
    "log": "${LOG_FILE}"
}
EOF

# 创建日志文件
touch ${LOG_FILE}
chmod 644 ${LOG_FILE}

# 创建 systemd 服务文件
echo "正在创建 systemd 服务文件 ${SYSTEMD_SERVICE}..."
cat > ${SYSTEMD_SERVICE} <<EOF
[Unit]
Description=Snell v4 Server
After=network.target

[Service]
ExecStart=${INSTALL_DIR}/snell-server -c ${CONFIG_FILE}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 重新加载 systemd 并启动服务
echo "正在重新加载 systemd..."
systemctl daemon-reload
echo "启动 Snell 服务并设置为开机自启..."
systemctl enable snell
systemctl start snell

echo "Snell v4 安装并启动成功！"
echo "配置文件路径: ${CONFIG_FILE}"
echo "日志文件路径: ${LOG_FILE}"
echo "预共享密钥(PSK): ${PSK}"
