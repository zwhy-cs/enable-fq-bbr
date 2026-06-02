#!/bin/bash
set -euo pipefail

#===========================================================================
# Debian 11 — systemd-resolved 一键配置脚本
# 策略：DNS over TLS + DNSSEC=no + stub 模式
# 用法：chmod +x setup-resolved.sh && ./setup-resolved.sh
#===========================================================================

CONF_FILE="/etc/systemd/resolved.conf"
RESOLV_LINK="/etc/resolv.conf"
STUB_FILE="/run/systemd/resolve/stub-resolv.conf"
DHCLIENT_HOOK_DIR="/etc/dhcp/dhclient-enter-hooks.d"
DHCLIENT_HOOK_FILE="${DHCLIENT_HOOK_DIR}/nodnsupdate"

echo "==> 检查当前状态..."

# 1. 确保 systemd-resolved 已安装并运行
if ! systemctl is-active --quiet systemd-resolved; then
    echo "==> 启动 systemd-resolved..."
    systemctl enable --now systemd-resolved
fi

# 2. 备份原配置（仅首次）
if [ ! -f "${CONF_FILE}.bak" ]; then
    cp "$CONF_FILE" "${CONF_FILE}.bak"
    echo "==> 已备份原配置到 ${CONF_FILE}.bak"
fi

# 3. 写入 /etc/systemd/resolved.conf
echo "==> 写入 resolved.conf..."
cat > "$CONF_FILE" << 'EOF'
[Resolve]
DNS=8.8.8.8#dns.google
FallbackDNS=8.8.4.4#dns.google
DNSOverTLS=yes
DNSSEC=no
EOF

# 4. 链路 resolv.conf → stub
if [ "$(readlink -f "$RESOLV_LINK" 2>/dev/null)" != "$STUB_FILE" ]; then
    echo "==> 建立软链接: $RESOLV_LINK → $STUB_FILE"
    rm -f "$RESOLV_LINK"
    ln -sf "$STUB_FILE" "$RESOLV_LINK"
else
    echo "==> resolv.conf 已是 stub 模式，跳过"
fi

mkdir -p "$DHCLIENT_HOOK_DIR"
cat > "$DHCLIENT_HOOK_FILE" << 'EOF'
#!/bin/sh
make_resolv_conf() { :; }
EOF
chmod +x "$DHCLIENT_HOOK_FILE"

# 5. 重启服务
echo "==> 重启 systemd-resolved..."
systemctl restart systemd-resolved

# 6. 验证
echo ""
echo "============================================"
echo "  配置完成 — 验证结果"
echo "============================================"
echo ""

echo "[resolv.conf]"
ls -l "$RESOLV_LINK"
echo ""

echo "[resolv.conf 内容]"
cat "$RESOLV_LINK"
echo ""

echo "[resolvectl status]"
resolvectl status
echo ""
