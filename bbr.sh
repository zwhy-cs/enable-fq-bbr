##########################################
# 安装必要软件包（使用 apt-get 安装） #
##########################################
echo "开始安装必要的软件包..."
apt-get update && apt-get install -y iperf3 unzip wget python3 nano

#####################
# 修改 DNS 配置部分 #
#####################
echo "开始修改 DNS 配置..."
cat <<EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

##############################
# 修改 sysctl 配置（fq、bbr） #
##############################
echo "开始修改 sysctl 配置..."
# 备份原有 sysctl 配置文件
if [ -f /etc/sysctl.conf ]; then
  cp /etc/sysctl.conf /etc/sysctl.conf.bak
else
  touch /etc/sysctl.conf
fi

# 直接覆盖 sysctl.conf 内容
cat <<EOF > /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_wmem = 4096 16384 50000000
net.ipv4.tcp_rmem = 4096 87380 50000000
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.rmem_max = 50000000
net.core.wmem_max = 50000000
EOF

# 使 sysctl 配置生效
sysctl -p
echo "sysctl 配置已覆盖并生效！"

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
