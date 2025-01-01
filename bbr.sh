#!/bin/bash

# 检查是否是 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行此脚本！"
    exit 1
fi

# 更新系统并安装必要的工具
echo "更新系统并安装必要工具..."
apt update && apt upgrade -y
apt install -y iproute2

# 设置 TCP 拥塞控制为 BBR
echo "启用 BBR 拥塞控制算法..."
sysctl_conf="/etc/sysctl.conf"

# 检查并写入配置
if ! grep -q "net.core.default_qdisc=fq" $sysctl_conf; then
    echo "net.core.default_qdisc=fq" >> $sysctl_conf
fi

if ! grep -q "net.ipv4.tcp_congestion_control=bbr" $sysctl_conf; then
    echo "net.ipv4.tcp_congestion_control=bbr" >> $sysctl_conf
fi

# 重新加载 sysctl 配置
sysctl -p

# 检查是否启用成功
echo "验证设置是否生效..."
if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "BBR 启用成功！"
else
    echo "BBR 启用失败，请检查配置。"
    exit 1
fi

if sysctl net.core.default_qdisc | grep -q "fq"; then
    echo "FQ 调度算法启用成功！"
else
    echo "FQ 调度算法启用失败，请检查配置。"
    exit 1
fi

# 加载 BBR 内核模块（防止模块未加载）
echo "加载 BBR 内核模块..."
modprobe tcp_bbr

echo "脚本执行完成，FQ 和 BBR 已成功启用！"
