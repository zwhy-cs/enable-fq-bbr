sed -i 's/^#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf

#####################
# 修改 DNS 配置部分 #
#####################
echo "开始修改 DNS 配置..."
# 先解锁并处理可能的符号链接
chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
fi
cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 2001:4860:4860::8888
nameserver 2001:4860:4860::8844
EOF
# 写入后上锁，防止被修改
chattr +i /etc/resolv.conf || true

##########################################
# 安装必要软件包（使用 apt-get 安装） #
##########################################
echo "开始安装必要的软件包..."
apt update && apt install -y iperf3 unzip wget python3 nano dnsutils
apt install systemd-timesyncd -y
systemctl enable --now systemd-timesyncd


##############################
# 修改 sysctl 配置（fq、bbr） #
##############################
read -p "是否需要配置 TCP 窗口大小？(y/n, 默认 n): " config_tcp_win
if [[ "$config_tcp_win" =~ ^[Yy]$ ]]; then
    # 直接覆盖 sysctl.conf 内容 (包含 TCP 窗口等)
    cat <<EOF > /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_slow_start_after_idle=0
EOF
else
    # 仅写入 bbr 和 fq
    cat <<EOF > /etc/sysctl.conf
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
EOF
fi

# 使 sysctl 配置生效
sysctl -p
echo "sysctl 配置已覆盖并生效！"

#######################################
# 修改 MTU 配置 (可选)                #
#######################################
read -p "是否需要修改网卡 MTU 为 1400？(y/n, 默认 n): " config_mtu
if [[ "$config_mtu" =~ ^[Yy]$ ]]; then
    # 获取默认出口网卡名称
    MAIN_INTERFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
    if [ -n "$MAIN_INTERFACE" ]; then
        if [ -f /etc/network/interfaces ]; then
            if grep -q "mtu 1400" /etc/network/interfaces; then
                echo "MTU 1400 配置已在 /etc/network/interfaces 中。"
                ip link set dev $MAIN_INTERFACE mtu 1400
                echo "已确保接口 $MAIN_INTERFACE 的 MTU 1400 立即生效。"
            else
                sed -i "/iface $MAIN_INTERFACE/a \    mtu 1400" /etc/network/interfaces
                ip link set dev $MAIN_INTERFACE mtu 1400
                echo "已为网卡 $MAIN_INTERFACE 成功添加并立即生效 MTU 1400 配置。"
            fi
        else
            echo "未找到 /etc/network/interfaces 文件，无法自动修改 MTU。"
        fi
    else
        echo "未发现默认网卡，无法自动配置 MTU。"
    fi
fi

#######################################
# 执行 nxtrace 远程脚本（可选操作） #
#######################################
echo "开始执行 nxtrace 脚本..."
until timeout 5 bash -c 'curl -sL nxtrace.org/nt | bash'; do
    echo "脚本执行超过 5 秒，重新执行..."
done

########################
# 安装 tcping 工具 #
########################
wget -O /root/tcping.tar.gz \
  https://github.com/pouriyajamshidi/tcping/releases/download/v2.7.1/tcping-linux-amd64-static.tar.gz
cd /root
tar -xzf tcping.tar.gz
mv tcping /usr/local/bin/
chmod +x /usr/local/bin/tcping
echo "所有操作执行完毕！"

# 1. 定义 cron 表达式（每天 6:00 执行 reboot 和 开机 30 秒执行 dog）
# 格式：分 时 日 月 周 命令
CRON_JOB_REBOOT="0 6 * * * /sbin/reboot"
CRON_JOB_DOG="@reboot sleep 30 && echo \"0\" | /usr/local/bin/dog"

# 2. 检查任务是否已存在，不存在则添加
(crontab -l 2>/dev/null | grep -Fq "$CRON_JOB_REBOOT") || (crontab -l 2>/dev/null; echo "$CRON_JOB_REBOOT") | crontab -
(crontab -l 2>/dev/null | grep -Fq "$CRON_JOB_DOG") || (crontab -l 2>/dev/null; echo "$CRON_JOB_DOG") | crontab -
