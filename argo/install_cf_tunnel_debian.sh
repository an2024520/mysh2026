#!/bin/bash

# ============================================================
#  Cloudflare Tunnel 安装助手 (v3.0 双核版)
#  - 模式 1: 官方 APT 源 (推荐，自动更新，校验完整)
#  - 模式 2: GitHub 二进制 (通用，无需添加源，适合纯净强迫症)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 检查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# ==========================================
# 核心函数定义
# ==========================================

# --- 方式一：APT 官方源安装 ---
install_via_apt() {
    echo -e "${GREEN}>>> 正在使用 [官方 APT 源] 模式安装...${PLAIN}"
    
    echo -e "${YELLOW}1. 安装基础依赖...${PLAIN}"
    apt update -y
    apt install -y curl sudo ca-certificates

    echo -e "${YELLOW}2. 添加 GPG 密钥与软件源...${PLAIN}"
    mkdir -p --mode=0755 /usr/share/keyrings
    # 删除旧的 key 防止冲突
    rm -f /usr/share/keyrings/cloudflare-public-v2.gpg
    
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}错误: GPG 密钥下载失败，请检查网络连接。${PLAIN}"
        return 1
    fi

    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list

    echo -e "${YELLOW}3. 更新源并安装 cloudflared...${PLAIN}"
    sudo apt-get update
    sudo apt-get install -y cloudflared
}

# --- 方式二：GitHub 二进制安装 ---
install_via_wget() {
    echo -e "${GREEN}>>> 正在使用 [GitHub 二进制] 模式安装...${PLAIN}"
    
    # 架构检测
    ARCH=$(dpkg --print-architecture)
    case $ARCH in
        amd64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return 1 ;;
    esac

    echo -e "${YELLOW}正在从 GitHub 下载 ($ARCH)...${PLAIN}"
    # 删除旧文件
    rm -f /usr/local/bin/cloudflared
    rm -f /usr/bin/cloudflared
    
    wget -O /usr/local/bin/cloudflared "$CF_URL"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败！GitHub 连接超时或文件不存在。${PLAIN}"
        return 1
    fi
    
    chmod +x /usr/local/bin/cloudflared
    # 建立软连接，确保 command -v 能找到
    ln -sf /usr/local/bin/cloudflared /usr/bin/cloudflared
}

# --- 通用：验证与配置 ---
configure_tunnel() {
    # 验证安装是否成功
    if ! command -v cloudflared &> /dev/null; then
        echo -e "${RED}错误: cloudflared 未安装成功，无法继续。${PLAIN}"
        exit 1
    fi

    VERSION=$(cloudflared --version)
    echo -e "${GREEN}程序就绪: $VERSION${PLAIN}"

    # 配置向导
    echo -e ""
    echo -e "${YELLOW}--- 配置 Tunnel ---${PLAIN}"
    echo -e "请在 Cloudflare Zero Trust 后台创建一个 Tunnel，并复制 Token。"
    echo -e ""
    read -p "请输入您的 Tunnel Token: " TOKEN

    if [[ -z "$TOKEN" ]]; then
        echo -e "${RED}未输入 Token，安装已中止。${PLAIN}"
        exit 0
    fi

    echo -e "${YELLOW}正在注册系统服务...${PLAIN}"
    
    # 清理旧服务
    cloudflared service uninstall >/dev/null 2>&1
    
    # 注册服务 (带超时保护)
    INSTALL_LOG=$(timeout 30s cloudflared service install "$TOKEN" 2>&1)
    INSTALL_STATUS=$?

    if [[ $INSTALL_STATUS -eq 0 ]]; then
        echo -e "${GREEN}服务注册成功！${PLAIN}"
        systemctl start cloudflared
        systemctl enable cloudflared
        
        sleep 2
        if systemctl is-active --quiet cloudflared; then
            echo -e "${GREEN}========================================${PLAIN}"
            echo -e "${GREEN}    Cloudflare Tunnel 启动成功！        ${PLAIN}"
            echo -e "${GREEN}========================================${PLAIN}"
        else
            echo -e "${RED}服务注册成功但启动失败。请检查日志。${PLAIN}"
        fi
    else
        echo -e "${RED}服务注册失败！${PLAIN}"
        echo -e "错误详情: ${INSTALL_LOG}"
        echo -e "请检查 Token 是否正确，或网络是否能连接 Cloudflare API。"
    fi
}

# ==========================================
# 主逻辑
# ==========================================

clear
echo -e "${GREEN}Cloudflare Tunnel 安装向导${PLAIN}"
echo -e "----------------------------------------"
echo -e "请选择安装方式："
echo -e "${SKYBLUE}1.${PLAIN} 官方 APT 源安装 ${YELLOW}(推荐)${PLAIN}"
echo -e "   - 优点: 官方维护、GPG校验安全、支持 apt upgrade 自动更新"
echo -e "   - 缺点: 对国内 VPS 可能连接源较慢"
echo -e ""
echo -e "${SKYBLUE}2.${PLAIN} GitHub 二进制安装"
echo -e "   - 优点: 简单粗暴、无需添加系统源、通用性强"
echo -e "   - 缺点: 需手动更新、依赖 GitHub 连接"
echo -e "----------------------------------------"
read -p "请输入选项 [1-2]: " install_choice

case "$install_choice" in
    1)
        install_via_apt
        if [[ $? -eq 0 ]]; then configure_tunnel; fi
        ;;
    2)
        install_via_wget
        if [[ $? -eq 0 ]]; then configure_tunnel; fi
        ;;
    *)
        echo -e "${RED}无效输入，退出。${PLAIN}"
        exit 1
        ;;
esac
