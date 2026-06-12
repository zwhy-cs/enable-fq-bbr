#!/bin/bash
set -euo pipefail

# 配置路径（采用 drop-in 配置目录，不破坏主 resolved.conf）
CONF_DIR="/etc/systemd/resolved.conf.d"
CONF_FILE="${CONF_DIR}/custom-dns.conf"
RESOLV_LINK="/etc/resolv.conf"
STUB_FILE="/run/systemd/resolve/stub-resolv.conf"
DHCLIENT_HOOK_DIR="/etc/dhcp/dhclient-enter-hooks.d"
DHCLIENT_HOOK_FILE="${DHCLIENT_HOOK_DIR}/nodnsupdate"

echo "==> 检查并安装 systemd-resolved..."
if ! command -v resolvectl &> /dev/null; then
    if command -v apt-get &> /dev/null; then
        echo "==> 未检测到 systemd-resolved，正在通过 apt 安装..."
        apt-get update
        apt-get install -y systemd-resolved
    elif command -v dnf &> /dev/null; then
        echo "==> 未检测到 systemd-resolved，正在通过 dnf 安装..."
        dnf install -y systemd-resolved
    else
        echo "==> [警告] 未检测到支持的包管理器，请确保已手动安装 systemd-resolved。"
    fi
fi

# 1. 确保 systemd-resolved 已开启并运行
if systemctl list-unit-files | grep -q systemd-resolved; then
    echo "==> 启动并启用 systemd-resolved..."
    systemctl unmask systemd-resolved 2>/dev/null || true
    systemctl enable --now systemd-resolved
else
    echo "==> [错误] 系统中未检测到 systemd-resolved 服务。" >&2
    exit 1
fi

# 2. 写入 drop-in 配置（增量配置，不覆盖全局设置）
# 注：
# - Domains=~. 确保全局 DNS 的路由优先级最高，彻底屏蔽 DHCP 带来的局域网 DNS 干扰
# - DNSOverTLS 改为 opportunistic（机会性加密）。如果 853 端口被封锁，会自动平滑降级到普通 53 端口，避免全机断网
echo "==> 写入 systemd-resolved 局部配置..."
mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" << 'EOF'
[Resolve]
DNS=8.8.8.8#dns.google
FallbackDNS=8.8.4.4#dns.google
Domains=~.
DNSOverTLS=opportunistic
DNSSEC=no
EOF

# 3. 链路 resolv.conf → stub 模式 (处理潜在的 chattr 只读限制)
echo "==> 正在准备建立软链接: $RESOLV_LINK → $STUB_FILE"
if command -v chattr &> /dev/null; then
    # 解除只读保护属性（防范部分服务商默认加锁）
    chattr -i "$RESOLV_LINK" 2>/dev/null || true
fi

# 轮询等待 stub 文件就绪（防止在服务初次启动时文件尚未生成就进行软链接）
for i in {1..5}; do
    [ -f "$STUB_FILE" ] && break
    echo "==> 等待 systemd-resolved 生成 stub 文件..."
    sleep 1
done

if [ "$(readlink -f "$RESOLV_LINK" 2>/dev/null)" != "$STUB_FILE" ]; then
    rm -f "$RESOLV_LINK"
    ln -sf "$STUB_FILE" "$RESOLV_LINK"
    echo "==> 软链接建立成功"
else
    echo "==> resolv.conf 已是 stub 模式，跳过链接操作"
fi

# 4. 屏蔽 dhclient 覆盖 resolv.conf（仅在目录存在时执行，防止创建无用垃圾目录）
if [ -d "$DHCLIENT_HOOK_DIR" ]; then
    echo "==> 写入 dhclient hook 屏蔽规则..."
    cat > "$DHCLIENT_HOOK_FILE" << 'EOF'
#!/bin/sh
make_resolv_conf() { :; }
EOF
    chmod +x "$DHCLIENT_HOOK_FILE"
fi

# 5. 重启服务使配置生效
echo "==> 重启 systemd-resolved..."
systemctl restart systemd-resolved

# 6. 验证
echo ""
echo "=================================================="
echo "               配置完成 — 验证结果"
echo "=================================================="
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
