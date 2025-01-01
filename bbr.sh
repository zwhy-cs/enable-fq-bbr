#!/bin/bash

# 检查是否是root用户
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行此脚本！"
    exit 1
fi

# 更新系统并安装必要的工具
echo "更新系统和安装必要的工具..."
apt update && apt upgrade -y
apt install -y iproute2

# 启用BBR拥塞控制算法
echo "启用BBR拥塞控制算法..."
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

# 刷新系统配置
sysctl -p

# 检查BBR是否启用
echo "检查BBR是否启用..."
sysctl net.ipv4.tcp_congestion_control

# 确保启用BBR时内核模块已经加载
if ! lsmod | grep -q "tcp_bbr"; then
    echo "加载BBR模块..."
    modprobe tcp_bbr
fi

# 设置TCP队列调度策略为FQ
echo "设置TCP队列调度策略为FQ..."
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr

# 查看设置是否生效
echo "当前网络设置："
sysctl -a | grep 'tcp'

# 提示完成
echo "FQ和BBR设置完成！"
