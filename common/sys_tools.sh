#!/bin/bash

# ============================================================
#  模块五：系统运维工具箱 (System Tools)
#  - 状态: v2.0 (BBR / SSH防断 / 时间同步 / 证书 / 全日志)
#  - 适用: Xray / Sing-box / Cloudflare Tunnel
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
BLUE='\033[0;34m'

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# ==========================================
# 功能函数定义
# ==========================================

# --- 1. 系统内核加速 (BBR + Ulimit) ---
enable_bbr() {
    echo -e "${YELLOW}正在配置 BBR 拥塞控制与系统参数...${PLAIN}"
    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak

    # 清理旧配置
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_window_scaling/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_ecn/d' /etc/sysctl.conf

    # 写入新配置 (默认关闭 ECN 以防断流)
    cat <<EOF >> /etc/sysctl.conf
# === Network Optimization ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 0
# ============================
EOF
    sysctl -p > /dev/null 2>&1

    # 优化 Ulimit
    if ! grep -q "soft nofile 65535" /etc/security/limits.conf; then
        echo "* soft nofile 65535" >> /etc/security/limits.conf
        echo "* hard nofile 65535" >> /etc/security/limits.conf
        echo "root soft nofile 65535" >> /etc/security/limits.conf
        echo "root hard nofile 65535" >> /etc/security/limits.conf
    fi

    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$bbr_status" == "bbr" ]]; then
        echo -e "${GREEN}✅ BBR 加速: [已开启]${PLAIN}"
        echo -e "${GREEN}✅ 连接数限制: [已解除]${PLAIN}"
    else
        echo -e "${RED}❌ BBR 开启失败，请检查内核版本。${PLAIN}"
    fi
}

# --- 2. SSH 防断连修复 (Web SSH 优化) ---
fix_ssh_keepalive() {
    echo -e "${YELLOW}正在配置 SSH 心跳保活 (Web SSH 防断连)...${PLAIN}"
    sed -i '/ClientAliveInterval/d' /etc/ssh/sshd_config
    sed -i '/ClientAliveCountMax/d' /etc/ssh/sshd_config
    echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
    echo "ClientAliveCountMax 10" >> /etc/ssh/sshd_config
    systemctl restart sshd
    echo -e "${GREEN}✅ SSH 配置已更新。请重新连接以生效。${PLAIN}"
}

# --- 3. 系统时间同步 ---
sync_time() {
    echo -e "${YELLOW}正在同步系统时间...${PLAIN}"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true
        echo -e "${GREEN}✅ 已开启 NTP 自动同步。${PLAIN}"
        timedatectl status | grep "Local time"
    else
        apt-get install -y ntpdate >/dev/null 2>&1 || yum install -y ntpdate >/dev/null 2>&1
        ntpdate pool.ntp.org
        echo -e "${GREEN}✅ 时间同步完成。${PLAIN}"
    fi
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

# --- 5. 全能日志查看器 (增强版) ---
view_logs() {
    echo -e "${BLUE}============= 服务运行日志 (实时最近 20 行) =============${PLAIN}"
    
    # Xray Log
    if systemctl is-active --quiet xray; then
        echo -e "${YELLOW}>>> Xray Core:${PLAIN}"
        journalctl -u xray --no-pager -n 20
        echo ""
    fi
    
    # Sing-box Log
    if systemctl is-active --quiet sing-box; then
        echo -e "${YELLOW}>>> Sing-box Core:${PLAIN}"
        journalctl -u sing-box --no-pager -n 20
        echo ""
    fi
    
    # Cloudflare Tunnel Log (服务名通常为 cloudflared)
    if systemctl is-active --quiet cloudflared; then
        echo -e "${YELLOW}>>> Cloudflare Tunnel:${PLAIN}"
        journalctl -u cloudflared --no-pager -n 20
        echo ""
    fi
    
    # 检测是否全空
    if ! systemctl is-active --quiet xray && ! systemctl is-active --quiet sing-box && ! systemctl is-active --quiet cloudflared; then
         echo -e "${RED}未检测到 Xray / Sing-box / Cloudflared 服务运行。${PLAIN}"
    fi
}

# ==========================================
# 主菜单
# ==========================================
show_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}        系统运维工具箱 (System Tools)        ${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 开启 BBR 加速 + 解除连接数限制"
        echo -e " ${SKYBLUE}2.${PLAIN} 修复 SSH 自动断开 ${YELLOW}(Web SSH 推荐)${PLAIN}"
        echo -e " ${SKYBLUE}3.${PLAIN} 强制同步系统时间 ${YELLOW}(修复节点连不上)${PLAIN}"
        echo -e " --------------------------------------------"
        echo -e " ${SKYBLUE}4.${PLAIN} 查看 ACME 证书路径"
        echo -e " ${SKYBLUE}5.${PLAIN} 查看运行日志 ${YELLOW}(Xray/SB/CF)${PLAIN}"
        echo -e " --------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo ""
        read -p "请选择操作: " choice
        case "$choice" in
            1) enable_bbr; read -p "按回车继续..." ;;
            2) fix_ssh_keepalive; read -p "按回车继续..." ;;
            3) sync_time; read -p "按回车继续..." ;;
            4) view_certs; read -p "按回车继续..." ;;
            5) view_logs; read -p "按回车继续..." ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

show_menu
