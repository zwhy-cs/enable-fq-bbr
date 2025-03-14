#!/bin/bash
# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
  echo "请以root权限运行该脚本！"
  exit 1
fi

echo "开始修改DNS配置..."
# 备份原有的DNS配置文件
cp /etc/resolv.conf /etc/resolv.conf.bak
# 直接写入新的DNS配置（注意：如果系统使用其他DNS管理方式，该文件可能会被重写）
cat <<EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
echo "DNS配置已修改并备份至 /etc/resolv.conf.bak"

echo "开始修改 sysctl 配置..."
# 备份原有的 sysctl 配置文件
cp /etc/sysctl.conf /etc/sysctl.conf.bak

# 修改或添加 fq 与 bbr 配置
if grep -q "net.core.default_qdisc" /etc/sysctl.conf; then
  sed -i "s/.*net.core.default_qdisc.*/net.core.default_qdisc = fq/" /etc/sysctl.conf
else
  echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
fi

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

echo "所有配置已完成！"
