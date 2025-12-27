#!/bin/bash

# ============================================================
#  系统运维工具箱 v3.0 (优化增强版 - 2025)
#  - 基于原脚本全面改进：安全性、兼容性、现代化
#  - 新增：BBRv3 支持、Chrony 时间同步、ZRAM 选项、nftables 端口跳跃、Fail2Ban 集成
#  - 改进：全面备份、错误处理、输入验证、动态优化
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'

# 严格模式
set -euo pipefail

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 备份函数
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}已备份: $file${PLAIN}"
    fi
}

# ==========================================
# 功能函数定义
# ==========================================

# --- 1. 系统内核加速 (BBRv3 + 优化参数) ---
enable_bbr() {
    echo -e "${YELLOW}正在检测并配置最佳 BBR 拥塞控制...${PLAIN}"
    backup_file /etc/sysctl.conf

    # 清理旧配置
    sed -i '/net\.core\.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net\.ipv4\.tcp_ecn/d' /etc/sysctl.conf
    sed -i '/net\.core\.somaxconn/d' /etc/sysctl.conf

    # 检测内核版本并选择最佳 BBR（注：BBRv3 目前仍需特定内核或模块，普通发行版多为 bbr）
    local kernel_version=$(uname -r | cut -d. -f1-2)
    local bbr_version="bbr"

    if command -v bc >/dev/null && [[ $(echo "$kernel_version >= 6.1" | bc) -eq 1 ]]; then
        if lsmod | grep -q bbr3 || modprobe tcp_bbr3 2>/dev/null; then
            bbr_version="bbr3"
            echo -e "${GREEN}检测到 BBRv3 支持，已启用！${PLAIN}"
        fi
    fi

    cat <<EOF >> /etc/sysctl.conf

# === Network Optimization (2025 Best Practice) ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $bbr_version
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 1
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
EOF

    sysctl -p >/dev/null

    # 优化 Ulimit（高并发推荐值）
    backup_file /etc/security/limits.conf
    if ! grep -q "nofile 1048576" /etc/security/limits.conf; then
        cat <<EOF >> /etc/security/limits.conf

* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    fi

    local current_bbr=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    echo -e "${GREEN}✅ 当前拥塞控制: $current_bbr${PLAIN}"
    echo -e "${GREEN}✅ 文件描述符限制已提升至 1048576${PLAIN}"
    echo -e "${GREEN}✅ 网络参数优化完成${PLAIN}"
}

# --- 2. SSH 防断连优化 ---
fix_ssh_keepalive() {
    echo -e "${YELLOW}正在配置 SSH 保活参数（推荐 Web SSH）...${PLAIN}"
    backup_file /etc/ssh/sshd_config

    sed -i '/ClientAliveInterval/d' /etc/ssh/sshd_config
    sed -i '/ClientAliveCountMax/d' /etc/ssh/sshd_config
    sed -i '/TCPKeepAlive/d' /etc/ssh/sshd_config

    cat <<EOF >> /etc/ssh/sshd_config

# KeepAlive Settings
ClientAliveInterval 240
ClientAliveCountMax 3
TCPKeepAlive yes
EOF

    if sshd -t >/dev/null 2>&1; then
        systemctl restart sshd
        echo -e "${GREEN}✅ SSH 保活配置已更新（240s 心跳，超时断开）${PLAIN}"
        echo -e "${SKYBLUE}建议客户端 ~/.ssh/config 添加：ServerAliveInterval 60${PLAIN}"
    else
        echo -e "${RED}❌ SSH 配置语法错误，请检查！${PLAIN}"
    fi
}

# --- 3. 系统时间同步 (优先 Chrony) ---
sync_time() {
    echo -e "${YELLOW}正在配置高精度时间同步（Chrony）...${PLAIN}"

    if ! command -v chronyd >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 Chrony...${PLAIN}"
        if command -v apt >/dev/null; then
            apt update && apt install -y chrony
        elif command -v yum >/dev/null || command -v dnf >/dev/null; then
            yum install -y chrony || dnf install -y chrony
        else
            echo -e "${RED}不支持的包管理器${PLAIN}"
            return 1
        fi
    fi

    backup_file /etc/chrony/chrony.conf

    cat >/etc/chrony/chrony.conf <<EOF
# 高精度 NTP 池 (2025 推荐)
pool pool.ntp.org iburst
pool time.cloudflare.com iburst
pool time.google.com iburst

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

    systemctl enable --now chronyd >/dev/null
    sleep 3
    echo -e "${GREEN}✅ Chrony 时间同步已启用${PLAIN}"
    chronyc tracking | grep -E "Reference ID|Stratum|Last offset"
}

# --- 4. 查看 ACME 证书 ---
view_certs() {
    echo -e "${BLUE}============= 已申请的 SSL 证书 =============${PLAIN}"
    local cert_root="/root/.acme.sh"
    if [ -d "$cert_root" ]; then
        ls -d $cert_root/*/ | grep -v "_ecc" | while read dir; do
            domain=$(basename "$dir")
            if [[ "$domain" != "http.header" && "$domain" != "acme.sh" ]]; then
                echo -e "域名: ${SKYBLUE}$domain${PLAIN}"
                echo -e "路径: ${YELLOW}$dir${PLAIN}"
                echo "-----------------------------------------------"
            fi
        done
    else
        echo -e "${RED}未检测到 acme.sh 目录。${PLAIN}"
    fi
}

# --- 5. 全能日志查看器 ---
view_logs() {
    echo -e "${BLUE}============= 服务运行日志 (实时最近 20 行) =============${PLAIN}"
    
    if systemctl is-active --quiet xray; then
        echo -e "${YELLOW}>>> Xray Core:${PLAIN}"
        journalctl -u xray --no-pager -n 20
        echo ""
    fi
    
    if systemctl is-active --quiet sing-box; then
        echo -e "${YELLOW}>>> Sing-box Core:${PLAIN}"
        journalctl -u sing-box --no-pager -n 20
        echo ""
    fi

    if systemctl is-active --quiet hysteria-server; then
        echo -e "${YELLOW}>>> Hysteria 2 Official:${PLAIN}"
        journalctl -u hysteria-server --no-pager -n 20
        echo ""
    fi
    
    if systemctl is-active --quiet cloudflared; then
        echo -e "${YELLOW}>>> Cloudflare Tunnel:${PLAIN}"
        journalctl -u cloudflared --no-pager -n 20
        echo ""
    fi
    
    if ! systemctl is-active --quiet xray && ! systemctl is-active --quiet sing-box \
       && ! systemctl is-active --quiet hysteria-server && ! systemctl is-active --quiet cloudflared; then
         echo -e "${RED}未检测到常见代理服务运行。${PLAIN}"
    fi
}

# --- 6. Swap / ZRAM 虚拟内存管理 ---
manage_swap() {
    if [[ -d "/proc/vz" ]] || systemd-detect-virt 2>/dev/null | grep -Eq "lxc|docker|container"; then
        echo -e "${RED}检测到容器或 OpenVZ，不支持传统 Swap${PLAIN}"
    fi

    while true; do
        clear
        echo -e "${BLUE}========= 虚拟内存管理 (Swap / ZRAM) =========${PLAIN}"
        swapon --show || echo -e "${YELLOW}无传统 Swap${PLAIN}"
        [[ -d /sys/block/zram0 ]] && echo -e "${GREEN}ZRAM 已启用${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 添加传统 Swap 文件"
        echo -e " ${GREEN}2.${PLAIN} 启用 ZRAM（推荐 SSD）"
        echo -e " ${RED}3.${PLAIN} 删除传统 Swap"
        echo -e " ${RED}4.${PLAIN} 禁用 ZRAM"
        echo -e " ${GRAY}0.${PLAIN} 返回"
        read -p "请选择: " choice
        case "$choice" in
            1)  # 添加 Swap（同原逻辑，优化为 fallocate 优先）
                read -p "Swap 大小 (MB): " size
                [[ ! "$size" =~ ^[0-9]+$ || "$size" -le 0 ]] && { echo -e "${RED}无效${PLAIN}"; continue; }
                grep -q swap /etc/fstab && { echo -e "${RED}已存在，请先删除${PLAIN}"; continue; }
                fallocate -l "${size}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size"
                chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
                echo '/swapfile none swap defaults 0 0' >> /etc/fstab
                echo -e "${GREEN}✅ ${size}MB Swap 添加成功${PLAIN}"
                ;;
            2)  # 启用 ZRAM
                modprobe zram
                echo lz4 > /sys/block/zram0/comp_algorithm
                echo 2G > /sys/block/zram0/disksize
                mkswap /dev/zram0; swapon /dev/zram0
                echo '/dev/zram0 none swap defaults 0 0' >> /etc/fstab
                echo -e "${GREEN}✅ ZRAM (2GB) 已启用${PLAIN}"
                ;;
            3)  # 删除 Swap
                swapoff -a; sed -i '/swap/d' /etc/fstab; rm -f /swapfile
                echo -e "${GREEN}✅ Swap 已删除${PLAIN}"
                ;;
            4)  # 禁用 ZRAM
                swapoff /dev/zram0; echo 1 > /sys/block/zram0/reset; rmmod zram
                sed -i '/zram/d' /etc/fstab
                echo -e "${GREEN}✅ ZRAM 已禁用${PLAIN}"
                ;;
            0) return ;;
        esac
        read -p "按回车继续..."
    done
}

# --- 7. 端口跳跃管理 (nftables) ---
manage_port_hopping() {
    command -v nft >/dev/null || { apt install -y nftables || yum install -y nftables; }

    while true; do
        clear
        echo -e "${BLUE}========= UDP 端口跳跃 (nftables) =========${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 添加规则   ${RED}2.${PLAIN} 删除规则   ${SKYBLUE}3.${PLAIN} 查看规则   ${GRAY}0.${PLAIN} 返回"
        read -p "请选择: " choice
        case "$choice" in
            1)
                read -p "真实端口: " target; read -p "起始端口: " start; read -p "结束端口: " end
                nft add rule nat prerouting udp dport "$start"-"$end" redirect to :"$target"
                nft list ruleset > /etc/nftables.conf
                echo -e "${GREEN}✅ 规则添加并持久化${PLAIN}"
                ;;
            2)
                nft -a list table nat
                read -p "输入 handle 编号: " handle
                nft delete rule nat prerouting handle "$handle"
                nft list ruleset > /etc/nftables.conf
                ;;
            3) nft list table nat ;;
            0) return ;;
        esac
        read -p "按回车继续..."
    done
}

# --- 8. SSH 安全加固 + Fail2Ban ---
configure_ssh_security() {
    backup_file /etc/ssh/sshd_config
    mkdir -p ~/.ssh && chmod 700 ~/.ssh

    echo -e "${YELLOW}导入公钥${PLAIN}"
    read -p "GitHub 用户名（留空手动）: " gh_user
    if [[ -n "$gh_user" ]]; then
        pub_key=$(curl -sSf "https://github.com/${gh_user}.keys")
    else
        read -p "粘贴公钥（回车跳过）: " pub_key
    fi
    [[ -n "$pub_key" ]] && echo "$pub_key" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo -e "${GREEN}✅ 公钥导入成功${PLAIN}"

    read -p "禁用密码登录？(y/n): " disable_pass
    [[ "$disable_pass" == "y" ]] && {
        sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
        sed -i '/^PubkeyAuthentication/d' /etc/ssh/sshd_config
        echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
        echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
        echo -e "${GREEN}✅ 已禁用密码登录${PLAIN}"
    }

    echo -e "${YELLOW}安装 Fail2Ban${PLAIN}"
    apt install -y fail2ban || yum install -y fail2ban || dnf install -y fail2ban
    cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
maxretry = 5
bantime = 3600
findtime = 600
EOF
    systemctl enable --now fail2ban
    echo -e "${GREEN}✅ Fail2Ban 已启用${PLAIN}"

    sshd -t && systemctl restart sshd
    echo -e "${GREEN}SSH 加固完成！请在新窗口测试登录${PLAIN}"
}

# ==========================================
# 主菜单
# ==========================================
show_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}      系统运维工具箱 v3.0 (2025 优化版)      ${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} BBR 加速 + 高并发优化"
        echo -e " ${SKYBLUE}2.${PLAIN} SSH 防断连优化"
        echo -e " ${SKYBLUE}3.${PLAIN} 高精度时间同步 (Chrony)"
        echo -e " --------------------------------------------"
        echo -e " ${SKYBLUE}4.${PLAIN} 查看 ACME 证书"
        echo -e " ${SKYBLUE}5.${PLAIN} 查看服务日志"
        echo -e " ${SKYBLUE}6.${PLAIN} 虚拟内存管理 (Swap/ZRAM)"
        echo -e " --------------------------------------------"
        echo -e " ${GREEN}7.${PLAIN} UDP 端口跳跃 (nftables)"
        echo -e " ${GREEN}8.${PLAIN} SSH 安全加固 + Fail2Ban"
        echo -e " --------------------------------------------"
        echo -e " ${GRAY}0.${PLAIN} 退出"
        read -p "请选择: " choice
        case "$choice" in
            1) enable_bbr ;;
            2) fix_ssh_keepalive ;;
            3) sync_time ;;
            4) view_certs ;;
            5) view_logs ;;
            6) manage_swap ;;
            7) manage_port_hopping ;;
            8) configure_ssh_security ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
        read -p "按回车继续..." </dev/tty
    done
}

show_menu
