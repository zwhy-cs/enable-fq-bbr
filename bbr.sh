#!/bin/bash
# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 权限运行该脚本！"
  exit 1
fi

#############################################################
# 修改 APT 源为官方源（覆盖 /etc/apt/sources.list 内容） #
#############################################################
echo "开始修改 APT 源为官方源..."
# 备份原有 sources.list 文件
cp /etc/apt/sources.list /etc/apt/sources.list.bak
# 写入官方源内容
cat <<EOF > /etc/apt/sources.list
# 官方主仓库
deb http://deb.debian.org/debian bullseye main
deb-src http://deb.debian.org/debian bullseye main

# 官方安全更新仓库
deb http://deb.debian.org/debian-security bullseye-security main
deb-src http://deb.debian.org/debian-security bullseye-security main

# 官方更新仓库（包含主要 bug 修复等）
deb http://deb.debian.org/debian bullseye-updates main
deb-src http://deb.debian.org/debian bullseye-updates main

# 官方回溯仓库（如需要最新软件包，但可能稳定性略低，可酌情启用）
deb http://deb.debian.org/debian bullseye-backports main
deb-src http://deb.debian.org/debian bullseye-backports main
EOF
echo "APT 源已修改为官方源，备份文件在 /etc/apt/sources.list.bak"

##########################################
# 安装必要软件包（使用 apt-get 安装） #
##########################################
echo "开始安装必要的软件包..."
apt-get update && apt-get install -y curl sudo wget python3 nano

#####################
# 修改 DNS 配置部分 #
#####################
echo "开始修改 DNS 配置..."
# 备份原有 DNS 配置文件
cp /etc/resolv.conf /etc/resolv.conf.bak
rm /etc/resolv.conf
# 设置 nameserver 为 1.1.1.1 和 8.8.8.8
cat <<EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
echo "DNS 配置修改完成，备份在 /etc/resolv.conf.bak"

##############################
# 修改 sysctl 配置（fq、bbr） #
##############################
echo "开始修改 sysctl 配置..."
# 备份原有 sysctl 配置文件
cp /etc/sysctl.conf /etc/sysctl.conf.bak
rm /etc/sysctl.conf

# 设置默认队列调度算法为 fq
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
echo "sysctl 配置修改并生效！"

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

echo "所有操作执行完毕！"
