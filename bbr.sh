##########################################
# 安装必要软件包（使用 apt-get 安装） #
##########################################
echo "开始安装必要的软件包..."
apt-get update && apt-get install -y curl sudo wget python3 nano

#####################
# 修改 DNS 配置部分 #
#####################
echo "开始修改 DNS 配置..."

# 检测系统使用的 DNS 解析管理方式
if [ -d "/etc/systemd/resolved.conf.d" ]; then
  # 对于使用 systemd-resolved 的系统
  echo "检测到系统使用 systemd-resolved 管理 DNS..."
  mkdir -p /etc/systemd/resolved.conf.d
  cat <<EOF > /etc/systemd/resolved.conf.d/dns_servers.conf
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9 149.112.112.112
EOF
  systemctl restart systemd-resolved
  echo "已通过 systemd-resolved 设置 DNS"
elif [ -d "/etc/resolvconf/resolv.conf.d" ]; then
  # 对于使用 resolvconf 的系统
  echo "检测到系统使用 resolvconf 管理 DNS..."
  cp /etc/resolvconf/resolv.conf.d/head /etc/resolvconf/resolv.conf.d/head.bak
  cat <<EOF > /etc/resolvconf/resolv.conf.d/head
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
  resolvconf -u
  echo "已通过 resolvconf 设置 DNS，备份在 /etc/resolvconf/resolv.conf.d/head.bak"
else
  # 对于其他系统，使用传统方法但增加保护措施
  cp /etc/resolv.conf /etc/resolv.conf.bak
  cat <<EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
  # 设置文件不可变属性以防止被自动覆盖（如果 chattr 可用）
  if command -v chattr > /dev/null; then
    chattr +i /etc/resolv.conf
    echo "DNS 配置修改完成，并已设置为不可变以防止自动覆盖"
  else
    echo "DNS 配置修改完成，备份在 /etc/resolv.conf.bak（注意：该配置可能会被系统自动覆盖）"
  fi
fi

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

#########################################################
# 检查 SSH 是否启用密码登录，修改 SSH 端口为 60000 #
#########################################################
echo "检测 SSH 密码登录设置..."
# 通过 sshd -T 获取生效配置，如果 passwordauthentication 为 yes 则表示启用密码登录
if sshd -T 2>/dev/null | grep -q "^passwordauthentication yes$"; then
  echo "检测到 SSH 密码登录启用，正在修改 SSH 端口为 60000..."
  # 如果已存在 Port 配置，则修改为 60000，否则追加该配置
  if grep -q "^Port" /etc/ssh/sshd_config; then
    sed -i "s/^Port.*/Port 60000/" /etc/ssh/sshd_config
  else
    echo "Port 60000" >> /etc/ssh/sshd_config
  fi
  # 重启 SSH 服务（尝试使用 systemctl 管理的 ssh 或 sshd）
  if systemctl is-active --quiet ssh; then
    systemctl restart ssh
  elif systemctl is-active --quiet sshd; then
    systemctl restart sshd
  else
    echo "未检测到 systemctl 管理的 SSH 服务，请手动重启 SSH 服务。"
  fi
  echo "SSH 端口已修改为 60000。"
else
  echo "未检测到 SSH 密码登录启用，SSH 端口保持默认设置。"
fi

wget -O /root/tcping.tar.gz \
  https://github.com/pouriyajamshidi/tcping/releases/download/v2.7.1/tcping-linux-amd64-static.tar.gz
cd /root
tar -xzf tcping.tar.gz
mv tcping /usr/local/bin/
chmod +x /usr/local/bin/tcping
echo "所有操作执行完毕！"
