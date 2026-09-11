sed -i 's/^#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf
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
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
# 写入后上锁，防止被修改
chattr +i /etc/resolv.conf || true

##########################################
# 安装必要软件包（使用 apt-get 安装） #
##########################################
echo "开始安装必要的软件包..."
apt-get update && \
apt-get install -y unzip wget nano dnsutils python3 jq && \
DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3
apt install systemd-timesyncd -y
systemctl enable --now systemd-timesyncd


##############################
# 修改 sysctl 配置（fq、bbr） #
##############################
cat <<EOF > /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

sleep 1

sysctl -p
echo "sysctl 配置已覆盖并生效！"

#######################################
# 执行 nxtrace 远程脚本（可选操作） #
#######################################
echo "开始执行 nxtrace 脚本..."
until timeout 10 bash -c 'curl -sL nxtrace.org/nt | bash'; do
    echo "脚本执行超过 10 秒，重新执行..."
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

(crontab -l 2>/dev/null; echo '0 6 * * * /sbin/reboot') | crontab -

sleep 5

reboot
