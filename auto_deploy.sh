#!/bin/bash
# ============================================================
#  Commander Auto-Deploy (v2.1 端口隔离修正版)
#  - 核心改进: 修复 PORT 全局污染，实现多协议独立端口配置
# ============================================================

# --- 基础定义 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
RED='\033[0;31m'
PLAIN='\033[0m'

URL_LIST="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST="/tmp/sh_url.txt"

# --- 1. 执行引擎 (Execution Engine) ---

init_urls() {
    wget -qO "$LOCAL_LIST" "$URL_LIST"
}

run() {
    local script=$1
    if [ ! -f "$script" ]; then
        local url
        url=$(grep "^$script" "$LOCAL_LIST" | awk '{print $2}' | head -1)
        if [[ -z "$url" ]]; then
            echo -e "${RED}[错误] 无法找到脚本: $script${PLAIN}"
            return 1
        fi
        echo -e "   > 下载: $script ..."
        wget -qO "$script" "$url" && chmod +x "$script"
    fi
    # 注意：这里不需要显式传递变量，Shell 的行内注入会自动将变量传给 ./$script
    ./"$script"
}

deploy_logic() {
    echo -e "${GREEN}>>> 启动 Commander 自动化部署引擎...${PLAIN}"
    init_urls
    
    # ----------------------------------------------------
    # 模块 A: Argo Tunnel
    # ----------------------------------------------------
    if [[ "$INSTALL_ARGO" == "true" ]]; then
        echo -e "${GREEN}>>> [Argo] 配置 Tunnel...${PLAIN}"
        # Argo 脚本可能未来需要 ARGO_AUTH / ARGO_DOMAIN 变量
        run "install_cf_tunnel_debian.sh"
    fi

    # ----------------------------------------------------
    # 模块 B: Sing-box 体系
    # ----------------------------------------------------
    if [[ "$INSTALL_SB" == "true" ]]; then
        echo -e "${GREEN}>>> [Sing-box] 部署核心...${PLAIN}"
        run "sb_install_core.sh"
        
        # [关键修改] 使用行内注入，PORT 变量仅对当前 run 命令有效
        
        # 1. Vision 协议
        if [[ "$DEPLOY_SB_VISION" == "true" ]]; then
            echo -e "${GREEN}>>> [Sing-box] 部署 Vision (端口: ${VAR_SB_VISION_PORT})...${PLAIN}"
            PORT=$VAR_SB_VISION_PORT run "sb_vless_vision_reality.sh"
        fi
        
        # 2. Hysteria2 (示例：如果未来有此脚本)
        if [[ "$DEPLOY_SB_HY2" == "true" ]]; then
            echo -e "${GREEN}>>> [Sing-box] 部署 Hysteria2 (端口: ${VAR_SB_HY2_PORT})...${PLAIN}"
            # 假设 Hy2 脚本读取 PORT 变量作为监听端口
            PORT=$VAR_SB_HY2_PORT run "sb_hy2.sh" 
        fi
        
        # 3. WebSocket (示例)
        if [[ "$DEPLOY_SB_WS" == "true" ]]; then
             echo -e "${GREEN}>>> [Sing-box] 部署 WS (端口: ${VAR_SB_WS_PORT})...${PLAIN}"
             PORT=$VAR_SB_WS_PORT run "sb_vless_ws_tls.sh"
        fi
    fi

    # ----------------------------------------------------
    # 模块 C: Xray 体系
    # ----------------------------------------------------
    if [[ "$INSTALL_XRAY" == "true" ]]; then
        echo -e "${GREEN}>>> [Xray] 部署核心...${PLAIN}"
        run "xray_core.sh"
        
        # 1. Vision 协议 (Xray 独立端口)
        if [[ "$DEPLOY_XRAY_VISION" == "true" ]]; then
            echo -e "${GREEN}>>> [Xray] 部署 Vision (端口: ${VAR_XRAY_VISION_PORT})...${PLAIN}"
            PORT=$VAR_XRAY_VISION_PORT run "xray_vless_vision_reality.sh"
        fi
    fi

    echo -e "${GREEN}>>> 所有自动化任务执行完毕。${PLAIN}"
}

# --- 2. 向导模块 (Wizard Module) ---

start_wizard() {
    clear
    echo -e "${SKYBLUE}==============================================${PLAIN}"
    echo -e "${SKYBLUE}    Commander Auto-Deploy 配置向导 v2.1    ${PLAIN}"
    echo -e "${SKYBLUE}==============================================${PLAIN}"
    
    # === 全局配置 ===
    echo -e "${YELLOW}[1] 全局配置${PLAIN}"
    read -p "全局 UUID (留空随机): " input_uuid
    [[ -n "$input_uuid" ]] && export UUID="$input_uuid"
    
    read -p "Reality 域名 (留空默认): " input_dest
    [[ -n "$input_dest" ]] && export REALITY_DOMAIN="$input_dest"
    echo ""

    # === Argo 配置 ===
    read -p "是否配置 Argo? (y/n): " do_argo
    if [[ "$do_argo" == "y" ]]; then
        export INSTALL_ARGO=true
        read -p "Argo Token: " argo_token
        export ARGO_AUTH="$argo_token"
        read -p "固定域名: " argo_dom
        export ARGO_DOMAIN="$argo_dom"
    fi
    echo ""

    # === Sing-box 配置 ===
    echo -e "${YELLOW}[2] Sing-box 协议选择${PLAIN}"
    read -p "安装 Sing-box? (y/n): " do_sb
    if [[ "$do_sb" == "y" ]]; then
        export INSTALL_SB=true
        
        # Vision 端口询问
        read -p "  > 添加 Vision 节点? (y/n): " sb_vis
        if [[ "$sb_vis" == "y" ]]; then
            export DEPLOY_SB_VISION=true
            read -p "    监听端口 (默认 443): " p
            export VAR_SB_VISION_PORT="${p:-443}"
        fi
        
        # Hy2 端口询问 (预留)
        # read -p "  > 添加 Hysteria2 节点? (y/n): " sb_hy2
        # if [[ "$sb_hy2" == "y" ]]; then
        #     export DEPLOY_SB_HY2=true
        #     read -p "    监听端口 (默认 8443): " p
        #     export VAR_SB_HY2_PORT="${p:-8443}"
        # fi
    fi
    echo ""
    
    # === Xray 配置 ===
    echo -e "${YELLOW}[3] Xray 协议选择${PLAIN}"
    read -p "安装 Xray? (y/n): " do_xray
    if [[ "$do_xray" == "y" ]]; then
        export INSTALL_XRAY=true
        
        # Xray Vision 端口询问
        read -p "  > 添加 Vision 节点? (y/n): " xray_vis
        if [[ "$xray_vis" == "y" ]]; then
            export DEPLOY_XRAY_VISION=true
            read -p "    监听端口 (默认 1443): " p
            export VAR_XRAY_VISION_PORT="${p:-1443}"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}>>> 配置收集完成。${PLAIN}"
    sleep 1
}

# --- 3. 入口判断 ---

export AUTO_SETUP=true

# 判断是否有外部变量输入 (高级模式)
if [[ -n "$INSTALL_SB" ]] || [[ -n "$INSTALL_XRAY" ]] || [[ -n "$INSTALL_ARGO" ]]; then
    deploy_logic
else
    start_wizard
    deploy_logic
fi
