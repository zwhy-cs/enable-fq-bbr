#!/bin/bash
# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 权限运行该脚本！"
  exit 1
fi

# 修改 DNS 配置
echo "开始修改 DNS 配置..."
# 备份原有 DNS 配置文件
cp /etc/resolv.conf /etc/resolv.conf.bak
# 设置 nameserver 为 1.1.1.1 与 8.8.8.8
cat <<EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
echo "DNS 配置修改完成，并备份至 /etc/resolv.conf.bak"

# 安装必要的软件包（使用 apt-get 安装系统软件，不是 pip 安装）
echo "开始安装必要的软件包..."
apt-get update
apt-get install -y curl sudo wget python3

# 修改 sysctl 配置
echo "开始修改 sysctl 配置..."
# 备份原有 sysctl 配置文件
cp /etc/sysctl.conf /etc/sysctl.conf.bak

# 设置 fq 队列调度算法
if grep -q "net.core.default_qdisc" /etc/sysctl.conf; then
  sed -i "s/.*net.core.default_qdisc.*/net.core.default_qdisc = fq/" /etc/sysctl.conf
else
  echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
fi

# 设置 TCP 拥塞控制算法为 bbr
if grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
  sed -i "s/.*net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf
else
  echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
fi

# 禁用 IPv6 配置
if grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
  sed -i "s/.*net.ipv6.conf.all.disable_ipv6.*/net.ipv6.conf.all.disable_ipv6 = 1/" /etc/sysctl.conf
else
  echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
fi

if grep -q "net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf; then
  sed -i "s/.*net.ipv6.conf.default.disable_ipv6.*/net.ipv6.conf.default.disable_ipv6 = 1/" /etc/sysctl.conf
else
  echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
fi

if grep -q "net.ipv6.conf.lo.disable_ipv6" /etc/sysctl.conf; then
  sed -i "s/.*net.ipv6.conf.lo.disable_ipv6.*/net.ipv6.conf.lo.disable_ipv6 = 1/" /etc/sysctl.conf
else
  echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
fi

# 使 sysctl 配置生效
sysctl -p

echo "DNS 与 sysctl 配置修改完成！"

# 执行 nxtrace 脚本（请确认脚本来源可信）
echo "开始执行 nxtrace 脚本..."
curl -sL nxtrace.org/nt | bash

echo "所有操作执行完毕！"
