#!/bin/bash
set -euo pipefail

CONF_FILE="/etc/systemd/resolved.conf"
RESOLV_LINK="/etc/resolv.conf"
STUB_FILE="/run/systemd/resolve/stub-resolv.conf"
DHCLIENT_HOOK_DIR="/etc/dhcp/dhclient-enter-hooks.d"
DHCLIENT_HOOK_FILE="${DHCLIENT_HOOK_DIR}/nodnsupdate"

echo "==> 检查并安装 systemd-resolved..."
if ! command -v resolvectl &> /dev/null; then
    echo "==> 未检测到 systemd-resolved，正在尝试通过 apt 安装..."
    apt-get update
    apt-get install -y systemd-resolved
fi

# 1. 确保 systemd-resolved 已开启并运行
if ! systemctl is-active --quiet systemd-resolved; then
    echo "==> 启动并启用 systemd-resolved..."
    systemctl enable --now systemd-resolved
fi
# 2. 写入 /etc/systemd/resolved.conf
# 注：此配置使用了 Google Public DNS，如果是国内服务器，请根据实际网络环境替换
echo "==> 写入 resolved.conf..."
cat > "$CONF_FILE" << 'EOF'
[Resolve]
DNS=8.8.8.8#dns.google
FallbackDNS=8.8.4.4#dns.google
DNSOverTLS=yes
DNSSEC=no
EOF

# 3. 链路 resolv.conf → stub 模式 (处理潜在的 chattr 只读限制)
echo "==> 正在准备建立软链接: $RESOLV_LINK → $STUB_FILE"
if command -v chattr &> /dev/null; then
    # 解除只读保护属性（防范部分服务商默认加锁）
    chattr -i "$RESOLV_LINK" 2>/dev/null || true
fi

if [ "$(readlink -f "$RESOLV_LINK" 2>/dev/null)" != "$STUB_FILE" ]; then
    rm -f "$RESOLV_LINK"
    ln -sf "$STUB_FILE" "$RESOLV_LINK"
    echo "==> 软链接建立成功"
else
    echo "==> resolv.conf 已是 stub 模式，跳过链接操作"
fi

# 4. 屏蔽 dhclient 覆盖 resolv.conf
mkdir -p "$DHCLIENT_HOOK_DIR"
cat > "$DHCLIENT_HOOK_FILE" << 'EOF'
#!/bin/sh
make_resolv_conf() { :; }
EOF
chmod +x "$DHCLIENT_HOOK_FILE"

# 5. 重启服务使配置生效
echo "==> 重启 systemd-resolved..."
systemctl restart systemd-resolved

# 6. 验证
echo ""
echo "============================================"
echo "  配置完成 — 验证结果"
echo "============================================"
echo ""

echo "[resolv.conf 软链接状态]"
ls -l "$RESOLV_LINK"
echo ""

echo "[resolv.conf 实际内容]"
cat "$RESOLV_LINK"
echo ""

echo "[resolvectl status 状态]"
resolvectl status || true
echo ""
