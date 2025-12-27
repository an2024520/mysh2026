#!/bin/bash

# ============================================================
#  系统运维工具箱 v3.1 (2025 自用增强版)
#  - 恢复内置专属公钥便利功能（仅自用安全）
#  - Fail2Ban 安装/卸载改为用户选择
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}已备份: $file${PLAIN}"
    fi
}

# --- 1. BBR 加速 + 高并发优化 ---
enable_bbr() {
    echo -e "${YELLOW}正在配置 BBR 与网络优化参数...${PLAIN}"
    backup_file /etc/sysctl.conf

    sed -i '/net\.core\.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net\.ipv4\.tcp_ecn/d' /etc/sysctl.conf
    sed -i '/net\.core\.somaxconn/d' /etc/sysctl.conf

    local bbr_version="bbr"
    if command -v bc >/dev/null && [[ $(echo "$(uname -r | cut -d. -f1-2) >= 6.1" | bc) -eq 1 ]]; then
        if lsmod | grep -q bbr3 || modprobe tcp_bbr3 2>/dev/null; then
            bbr_version="bbr3"
        fi
    fi

    cat <<EOF >> /etc/sysctl.conf

# Network Optimization 2025
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $bbr_version
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 1
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
EOF

    sysctl -p >/dev/null

    backup_file /etc/security/limits.conf
    if ! grep -q "nofile 1048576" /etc/security/limits.conf; then
        cat <<EOF >> /etc/security/limits.conf

* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    fi

    echo -e "${GREEN}✅ BBR ($bbr_version) 与高并发优化完成${PLAIN}"
}

# --- 2. SSH 防断连优化 ---
fix_ssh_keepalive() {
    echo -e "${YELLOW}配置 SSH 保活参数...${PLAIN}"
    backup_file /etc/ssh/sshd_config

    sed -i '/ClientAliveInterval/d' /etc/ssh/sshd_config
    sed -i '/ClientAliveCountMax/d' /etc/ssh/sshd_config
    sed -i '/TCPKeepAlive/d' /etc/ssh/sshd_config

    cat <<EOF >> /etc/ssh/sshd_config

ClientAliveInterval 240
ClientAliveCountMax 3
TCPKeepAlive yes
EOF

    if sshd -t >/dev/null 2>&1; then
        systemctl restart sshd
        echo -e "${GREEN}✅ SSH 保活已更新${PLAIN}"
    else
        echo -e "${RED}❌ 配置错误${PLAIN}"
    fi
}

# --- 3. 高精度时间同步 (Chrony) ---
sync_time() {
    echo -e "${YELLOW}安装并配置 Chrony...${PLAIN}"
    if ! command -v chronyd >/dev/null 2>&1; then
        apt update && apt install -y chrony || yum install -y chrony || dnf install -y chrony
    fi

    backup_file /etc/chrony/chrony.conf
    cat >/etc/chrony/chrony.conf <<EOF
pool pool.ntp.org iburst
pool time.cloudflare.com iburst
pool time.google.com iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

    systemctl enable --now chronyd >/dev/null
    echo -e "${GREEN}✅ Chrony 已启用${PLAIN}"
}

# --- 4 & 5. view_certs / view_logs (保持不变) ---
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

view_logs() {
    echo -e "${BLUE}============= 服务运行日志 (最近 20 行) =============${PLAIN}"
    systemctl is-active --quiet xray && { echo -e "${YELLOW}>>> Xray${PLAIN}"; journalctl -u xray --no-pager -n 20; echo; }
    systemctl is-active --quiet sing-box && { echo -e "${YELLOW}>>> Sing-box${PLAIN}"; journalctl -u sing-box --no-pager -n 20; echo; }
    systemctl is-active --quiet hysteria-server && { echo -e "${YELLOW}>>> Hysteria 2${PLAIN}"; journalctl -u hysteria-server --no-pager -n 20; echo; }
    systemctl is-active --quiet cloudflared && { echo -e "${YELLOW}>>> Cloudflare Tunnel${PLAIN}"; journalctl -u cloudflared --no-pager -n 20; echo; }
    if ! systemctl is-active --quiet xray && ! systemctl is-active --quiet sing-box && ! systemctl is-active --quiet hysteria-server && ! systemctl is-active --quiet cloudflared; then
        echo -e "${RED}未检测到常见服务运行${PLAIN}"
    fi
}

# --- 6. Swap / ZRAM 虚拟内存管理 ---
manage_swap() {
    if [[ -d "/proc/vz" ]] || systemd-detect-virt 2>/dev/null | grep -Eq "lxc|docker|container"; then
        echo -e "${RED}检测到容器或 OpenVZ，不支持传统 Swap${PLAIN}"
        read -p "按回车继续..."
        return
    fi

    while true; do
        clear
        echo -e "${BLUE}========= 虚拟内存管理 (Swap / ZRAM) =========${PLAIN}"
        echo -e "当前状态:"
        swapon --show | cat || echo -e "${YELLOW}无传统 Swap${PLAIN}"
        if [[ -d /sys/block/zram0 ]]; then
            echo -e "${GREEN}ZRAM 已启用${PLAIN}"
        fi
        echo ""
        echo -e " ${GREEN}1.${PLAIN} 添加传统 Swap 文件"
        echo -e " ${GREEN}2.${PLAIN} 启用 ZRAM（推荐 SSD，低内存 VPS）"
        echo -e " ${RED}3.${PLAIN} 删除传统 Swap"
        echo -e " ${RED}4.${PLAIN} 禁用 ZRAM"
        echo -e " ${GRAY}0.${PLAIN} 返回上一级"
        echo ""
        read -p "请选择: " choice

        case "$choice" in
            1)
                read -p "请输入 Swap 大小 (MB，例如 1024): " size
                if ! [[ "$size" =~ ^[0-9]+$ ]] || [[ "$size" -le 0 ]]; then
                    echo -e "${RED}错误: 请输入有效的正整数！${PLAIN}"
                    read -p "按回车继续..."; continue
                fi
                if grep -q "swap" /etc/fstab; then
                    echo -e "${RED}错误: 已存在 Swap 配置，请先删除！${PLAIN}"
                    read -p "按回车继续..."; continue
                fi

                # 检查磁盘空间（简单防护）
                avail=$(df / | tail -1 | awk '{print $4}')
                if [[ $avail -lt $((size * 1024)) ]]; then
                    echo -e "${RED}警告: 根分区可用空间不足，可能创建失败！${PLAIN}"
                fi

                echo -e "${YELLOW}正在创建 ${size}MB Swap 文件...${PLAIN}"
                fallocate -l "${size}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size" status=progress
                chmod 600 /swapfile
                mkswap /swapfile
                swapon /swapfile
                echo '/swapfile none swap defaults 0 0' >> /etc/fstab
                echo -e "${GREEN}✅ ${size}MB Swap 添加成功！${PLAIN}"
                swapon --show
                ;;
            2)
                if [[ -d /sys/block/zram0 ]]; then
                    echo -e "${YELLOW}ZRAM 已存在${PLAIN}"
                else
                    modprobe zram
                    echo lz4 > /sys/block/zram0/comp_algorithm
                    echo 2G > /sys/block/zram0/disksize   # 可自行修改大小
                    mkswap /dev/zram0
                    swapon /dev/zram0 -p 32767           # 高优先级
                    echo '/dev/zram0 none swap defaults,pri=32767 0 0' >> /etc/fstab
                    echo -e "${GREEN}✅ ZRAM (2GB 压缩内存，高优先级) 已启用${PLAIN}"
                fi
                ;;
            3)
                if grep -q "swap" /etc/fstab; then
                    echo -e "${YELLOW}正在删除传统 Swap...${PLAIN}"
                    swapoff -a
                    sed -i '/swap/d' /etc/fstab
                    rm -f /swapfile
                    echo -e "${GREEN}✅ 传统 Swap 已成功删除${PLAIN}"
                else
                    echo -e "${RED}未检测到传统 Swap${PLAIN}"
                fi
                ;;
            4)
                if [[ -d /sys/block/zram0 ]]; then
                    swapoff /dev/zram0
                    echo 1 > /sys/block/zram0/reset
                    rmmod zram
                    sed -i '/zram/d' /etc/fstab
                    echo -e "${GREEN}✅ ZRAM 已禁用${PLAIN}"
                else
                    echo -e "${RED}未检测到 ZRAM${PLAIN}"
                fi
                ;;
            0) return ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
        read -p "按回车继续..."
    done
}

# --- 7. UDP 端口跳跃管理 (nftables 现代版) ---
manage_port_hopping() {
    if ! command -v nft >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 nftables...${PLAIN}"
        apt update && apt install -y nftables || yum install -y nftables || dnf install -y nftables
        systemctl enable nftables >/dev/null 2>&1
    fi

    # 确保 nat 表存在
    nft list table nat >/dev/null 2>&1 || nft add table nat

    while true; do
        clear
        echo -e "${BLUE}========= UDP 端口跳跃管理 (nftables) =========${PLAIN}"
        echo -e "功能: 将大范围 UDP 流量转发至真实监听端口"
        echo -e "----------------------------------------------------"
        echo -e " ${GREEN}1.${PLAIN} 添加跳跃规则"
        echo -e " ${RED}2.${PLAIN} 删除跳跃规则"
        echo -e " ${SKYBLUE}3.${PLAIN} 查看当前规则"
        echo -e " ${GRAY}0.${PLAIN} 返回上一级"
        echo ""
        read -p "请选择: " choice

        case "$choice" in
            1)
                read -p "请输入真实监听端口 (Target Port, 例 443): " target_port
                read -p "请输入跳跃起始端口 (Start Port, 例 20000): " start_port
                read -p "请输入跳跃结束端口 (End Port, 例 30000): " end_port
                if [[ -z "$target_port" || -z "$start_port" || -z "$end_port" ]]; then
                    echo -e "${RED}错误: 参数不能为空${PLAIN}"; sleep 2; continue
                fi
                if [[ $start_port -gt $end_port ]]; then
                    echo -e "${RED}错误: 起始端口不能大于结束端口${PLAIN}"; sleep 2; continue
                fi

                echo -e "${YELLOW}正在添加规则: UDP $start_port-$end_port -> $target_port${PLAIN}"
                nft add rule nat prerouting udp dport "$start_port"-"$end_port" redirect to :"$target_port"
                nft list ruleset > /etc/nftables.conf 2>/dev/null
                echo -e "${GREEN}✅ 规则添加成功并已持久化${PLAIN}"
                ;;
            2)
                echo -e "${YELLOW}当前 NAT 转发规则:${PLAIN}"
                nft -a list table nat
                read -p "请输入要删除的规则 handle 编号: " handle
                if [[ -n "$handle" ]]; then
                    nft delete rule nat prerouting handle "$handle"
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                    echo -e "${GREEN}✅ 规则已删除${PLAIN}"
                else
                    echo -e "${RED}未输入 handle，取消删除${PLAIN}"
                fi
                ;;
            3)
                echo -e "${YELLOW}当前所有 NAT 规则:${PLAIN}"
                nft list table nat
                ;;
            0) return ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
        read -p "按回车继续..."
    done
}

# --- 8. SSH 安全加固（恢复便利功能 + Fail2Ban 询问）---
configure_ssh_security() {
    backup_file /etc/ssh/sshd_config
    mkdir -p ~/.ssh && chmod 700 ~/.ssh

    echo -e "${YELLOW}=== SSH 公钥导入（自用专属保险通道）===${PLAIN}"
    read -p "GitHub 用户名（留空则手动）: " gh_user
    local pub_key=""

    if [[ -n "$gh_user" ]]; then
        pub_key=$(curl -sSf "https://github.com/${gh_user}.keys" || echo "")
        [[ -z "$pub_key" ]] && echo -e "${RED}拉取失败${PLAIN}"
    else
        read -p "粘贴公钥（直接回车使用你的内置专属公钥）: " input_key
        if [[ -n "$input_key" ]]; then
            pub_key="$input_key"
        else
            echo -e "${SKYBLUE}>>> 使用内置专属公钥（一键恢复访问）${PLAIN}"
            pub_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILdsaJ9MTQU28cyRJZ3s32V1u9YDNUYRJvCSkztBDGsW eddsa-key-20251218"
        fi
    fi

    if [[ -n "$pub_key" ]]; then
        backup_file ~/.ssh/authorized_keys  # 备份旧的 authorized_keys
        echo "$pub_key" > ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        echo -e "${GREEN}✅ 公钥已覆写（旧密钥已清除）${PLAIN}"
    fi

    read -p "是否禁用密码登录？(y/n): " disable_pass
    if [[ "$disable_pass" == "y" ]]; then
        sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
        sed -i '/^PubkeyAuthentication/d' /etc/ssh/sshd_config
        echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
        echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
        echo -e "${GREEN}✅ 已禁用密码登录${PLAIN}"
    fi

    # === Fail2Ban 用户选择 ===
    echo -e "\n${YELLOW}=== Fail2Ban 防暴力破解 ===${PLAIN}"
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "当前状态: ${GREEN}已安装${PLAIN}"
        read -p "是否卸载 Fail2Ban？(y/n，默认n): " uninstall_f2b
        if [[ "$uninstall_f2b" == "y" ]]; then
            apt purge -y fail2ban || yum remove -y fail2ban || dnf remove -y fail2ban
            rm -rf /etc/fail2ban
            echo -e "${GREEN}✅ Fail2Ban 已卸载${PLAIN}"
            sshd -t && systemctl restart sshd
            echo -e "${GREEN}SSH 配置完成${PLAIN}"
            return
        fi
    else
        echo -e "当前状态: ${RED}未安装${PLAIN}"
    fi

    read -p "是否安装 Fail2Ban？(y/n，默认n): " install_f2b
    if [[ "$install_f2b" == "y" ]]; then
        apt install -y fail2ban || yum install -y fail2ban || dnf install -y fail2ban
        cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
maxretry = 5
bantime = 3600
findtime = 600
EOF
        systemctl enable --now fail2ban
        echo -e "${GREEN}✅ Fail2Ban 已安装并启用${PLAIN}"
    else
        echo -e "${GRAY}跳过 Fail2Ban 安装${PLAIN}"
    fi

    sshd -t && systemctl restart sshd
    echo -e "${GREEN}SSH 安全加固完成！请在新窗口测试公钥登录${PLAIN}"
}

# 主菜单及其他函数保持不变（略，完整脚本请保留之前所有函数）

show_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}      系统运维工具箱 v3.1 (2025 自用版)      ${PLAIN}"
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
        echo -e " ${GREEN}8.${PLAIN} SSH 安全加固（含专属公钥恢复）"
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

# （manage_swap 和 manage_port_hopping 函数请从之前完整版复制进来）

show_menu
