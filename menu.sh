#!/bin/bash

# ============================================================
#  全能协议管理中心 (Commander v3.9.5 Fix)
#  - 修复: IPv6-Only 环境下的 NAT64 检测逻辑误报问题
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'
BLUE='\033[0;34m'

URL_LIST_FILE="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST_FILE="/tmp/sh_url.txt"

# [文件映射区域 - 保持不变]
FILE_XRAY_CORE="xray_core.sh"
FILE_XRAY_UNINSTALL="xray_uninstall_all.sh"
FILE_SB_CORE="sb_install_core.sh"
FILE_SB_UNINSTALL="sb_uninstall.sh"
FILE_WIREPROXY="warp_wireproxy_socks5.sh"
FILE_CF_TUNNEL="install_cf_tunnel_debian.sh"
FILE_ADD_XHTTP="xray_vless_xhttp_reality.sh"
FILE_ADD_VISION="xray_vless_vision_reality.sh"
FILE_ADD_WS="xray_vless_ws_tls.sh"
FILE_ADD_TUNNEL="xray_vless_ws_tunnel.sh"
FILE_NODE_INFO="xray_get_node_details.sh"
FILE_NODE_DEL="xray_module_node_del.sh"
FILE_SB_ADD_ANYTLS="sb_anytls_reality.sh"
FILE_SB_ADD_VISION="sb_vless_vision_reality.sh"
FILE_SB_ADD_WS="sb_vless_ws_tls.sh"
FILE_SB_ADD_TUNNEL="sb_vless_ws_tunnel.sh"
FILE_SB_ADD_HY2_SELF="sb_hy2_self.sh"
FILE_SB_ADD_HY2_ACME="sb_hy2_acme.sh"
FILE_SB_INFO="sb_get_node_details.sh"
FILE_SB_DEL="sb_module_node_del.sh"
FILE_HY2="hy2.sh"
FILE_NATIVE_WARP="xray_module_warp_native_route.sh"
FILE_SB_NATIVE_WARP="sb_module_warp_native_route.sh"
FILE_ATTACH="xray_module_attach_warp.sh"
FILE_DETACH="xray_module_detach_warp.sh"
FILE_BOOST="xray_module_boost.sh"

# --- 引擎函数 ---

# [修正] 检测 IPv6-Only 环境并询问是否修复
check_ipv6_environment() {
    # 1. 预检：如果 curl -4 1.1.1.1 能通，说明是原生双栈，直接通过
    if curl -4 -s --connect-timeout 2 https://1.1.1.1 >/dev/null 2>&1; then
        return
    fi

    # 2. 如果原生不通，检查是否已经配置了有效的 NAT64 (通过访问纯IPv4站点 ipv4.google.com)
    # 注意：这里不能加 -4，必须让 DNS64 发挥作用将域名解析为 IPv6
    if curl -s --connect-timeout 3 https://ipv4.google.com >/dev/null 2>&1; then
        # 已经能通了（可能是之前配置过，或者 DNS64 生效中），静默跳过
        return
    fi

    echo -e "${YELLOW}======================================================${PLAIN}"
    echo -e "${RED}⚠️  检测到当前环境为纯 IPv6 (IPv6-Only)！${PLAIN}"
    echo -e "${GRAY}当前机器无法访问 IPv4 网络，这将导致无法下载 GitHub 资源。${PLAIN}"
    echo -e "${GRAY}本脚本集成了 NAT64/DNS64 自动配置功能。${PLAIN}"
    echo -e ""
    read -p "是否立即配置 NAT64 以获得 IPv4 访问能力? (y/n, 默认 y): " fix_choice
    fix_choice=${fix_choice:-y}

    if [[ "$fix_choice" == "y" ]]; then
        echo -e "${YELLOW}正在配置 NAT64/DNS64...${PLAIN}"
        
        # 备份 DNS
        if [ ! -f "/etc/resolv.conf.bak.nat64" ]; then
            cp /etc/resolv.conf /etc/resolv.conf.bak.nat64
            echo -e "${GREEN}已备份原 DNS 至 /etc/resolv.conf.bak.nat64${PLAIN}"
        fi

        # 注入 DNS64 地址 (优先使用 August Internet，备用 Trex)
        # August: 2a09:c500::1 (通常更稳)
        # Trex: 2001:67c:2b0::4
        echo -e "nameserver 2a09:c500::1\nnameserver 2001:67c:2b0::4" > /etc/resolv.conf

        # 验证连接 (修正逻辑：不强制 -4，而是访问 IPv4 站点)
        echo -e "${YELLOW}正在验证连通性...${PLAIN}"
        sleep 2
        if curl -s --connect-timeout 5 https://ipv4.google.com >/dev/null 2>&1; then
            echo -e "${GREEN}🎉 成功！已获得 IPv4 访问能力。${PLAIN}"
        else
            echo -e "${RED}❌ 警告：NAT64 配置后仍无法连接。${PLAIN}"
            echo -e "${GRAY}可能原因：防火墙拦截 UDP 53，或 systemd-resolved 干扰。${PLAIN}"
            echo -e "建议尝试手动执行: echo 'nameserver 2a09:c500::1' > /etc/resolv.conf"
            read -p "按回车尝试继续运行脚本..."
        fi
        echo -e ""
    else
        echo -e "${GRAY}已跳过 NAT64 配置。${PLAIN}"
        echo -e ""
    fi
}

check_dir_clean() {
    local current_script=$(basename "$0")
    local file_count=$(ls -1 | grep -v "^$current_script$" | wc -l)
    if [[ "$file_count" -gt 0 ]]; then
        echo -e "${YELLOW}======================================================${PLAIN}"
        echo -e "${YELLOW} 检测到当前目录存在 $file_count 个历史文件。${PLAIN}"
        echo -e "为了确保脚本运行在最新状态，建议在【空文件夹】下运行。"
        echo -e ""
        read -p "是否清空当前目录并强制更新所有组件? (y/n, 默认 n): " clean_opt
        if [[ "$clean_opt" == "y" ]]; then
            ls | grep -v "^$current_script$" | xargs rm -rf
            echo -e "${GREEN}清理完成，即将下载最新组件。${PLAIN}"; sleep 1
        fi
        echo -e ""
    fi
}

init_urls() {
    echo -e "${YELLOW}正在同步最新脚本列表...${PLAIN}"
    wget -T 5 -qO "$LOCAL_LIST_FILE" "${URL_LIST_FILE}?t=$(date +%s)"
    if [[ $? -ne 0 ]]; then
        if [[ -f "$LOCAL_LIST_FILE" ]]; then 
            echo -e "${YELLOW}网络异常，使用本地缓存列表。${PLAIN}"
        else 
            echo -e "${RED}致命错误: 无法获取脚本列表。${PLAIN}"
            echo -e "请检查你的 IPv4/NAT64 连接是否正常。"
            exit 1
        fi
    else
        echo -e "${GREEN}同步完成。${PLAIN}"
    fi
}

get_url_by_name() {
    local fname="$1"
    grep "^$fname" "$LOCAL_LIST_FILE" | awk '{print $2}' | head -n 1
}

check_run() {
    local script_name="$1"
    local no_pause="$2"

    if [[ ! -f "$script_name" ]]; then
        echo -e "${YELLOW}正在获取组件 [$script_name] ...${PLAIN}"
        local script_url=$(get_url_by_name "$script_name")
        if [[ -z "$script_url" ]]; then echo -e "${RED}错误: sh_url.txt 中未找到该文件记录。${PLAIN}"; read -p "按回车继续..."; return; fi
        
        mkdir -p "$(dirname "$script_name")"
        wget -qO "$script_name" "${script_url}?t=$(date +%s)"
        if [[ $? -ne 0 ]]; then echo -e "${RED}下载失败。${PLAIN}"; read -p "按回车继续..."; return; fi
        chmod +x "$script_name"
        echo -e "${GREEN}获取成功。${PLAIN}"
    fi

    ./"$script_name"

    if [[ "$no_pause" != "true" ]]; then
        echo -e ""; read -p "操作结束，按回车键继续..."
    fi
}

# ==========================================
# 2. 菜单逻辑 (保持不变)
# ==========================================

menu_singbox_env() {
    while true; do
        clear
        echo -e "${BLUE}============= Sing-box 核心环境管理 =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 安装/重置 Sing-box 核心 (最新正式版)"
        echo -e " ${SKYBLUE}2.${PLAIN} ${RED}彻底卸载 Sing-box 服务${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo -e ""
        read -p "请选择: " sb_choice
        case "$sb_choice" in
            1) check_run "$FILE_SB_CORE" ;;
            2) check_run "$FILE_SB_UNINSTALL" ;;
            0) return ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_nodes_xray() {
    while true; do
        clear
        echo -e "${BLUE}============= Xray 节点配置管理 =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 新增: VLESS-XHTTP (Reality - 穿透强)"
        echo -e " ${SKYBLUE}2.${PLAIN} 新增: VLESS-Vision (Reality - 极稳定)"
        echo -e " ${SKYBLUE}3.${PLAIN} 新增: VLESS-WS-TLS (CDN / Nginx前置)"
        echo -e " ${SKYBLUE}4.${PLAIN} 新增: VLESS-WS-Tunnel (Tunnel穿透专用)"
        echo -e " ${SKYBLUE}5.${PLAIN} 查看: 当前节点链接 / 分享信息"
        echo -e " ${SKYBLUE}6.${PLAIN} ${RED}删除: 删除指定节点 / 清空配置${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo -e ""
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_ADD_XHTTP" ;;
            2) check_run "$FILE_ADD_VISION" ;;
            3) check_run "$FILE_ADD_WS" ;;
            4) check_run "$FILE_ADD_TUNNEL" ;;
            5) check_run "$FILE_NODE_INFO" ;;
            6) check_run "$FILE_NODE_DEL" ;;
            0) return ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_nodes_sb() {
    while true; do
        clear
        echo -e "${BLUE}============= Sing-box 节点配置管理 =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 新增: AnyTLS-Reality (Sing-box 专属 / 极度拟态)"
        echo -e " ${SKYBLUE}2.${PLAIN} 新增: VLESS-Vision-Reality (极稳定 - 推荐)"
        echo -e " ${SKYBLUE}3.${PLAIN} 新增: VLESS-WS-TLS (CDN / Nginx前置)"
        echo -e " ${SKYBLUE}4.${PLAIN} 新增: VLESS-WS-Tunnel (Tunnel穿透专用)"
        echo -e " ${SKYBLUE}5.${PLAIN} 新增: Hysteria2 (自签证书 - 极速/跳过验证)"
        echo -e " ${SKYBLUE}6.${PLAIN} 新增: Hysteria2 (ACME证书 - 推荐/标准HTTPS)"
        echo -e " ----------------------------------------------"
        echo -e " ${SKYBLUE}7.${PLAIN} 查看: 当前节点链接 / 分享信息"
        echo -e " ${SKYBLUE}8.${PLAIN} ${RED}删除: 删除指定节点 / 清空配置${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo -e ""
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_SB_ADD_ANYTLS" ;;
            2) check_run "$FILE_SB_ADD_VISION" ;;
            3) check_run "$FILE_SB_ADD_WS" ;;
            4) check_run "$FILE_SB_ADD_TUNNEL" ;;
            5) check_run "$FILE_SB_ADD_HY2_SELF" ;;
            6) check_run "$FILE_SB_ADD_HY2_ACME" ;;
            7) 
                if [[ ! -f "$FILE_SB_INFO" ]]; then
                    echo -e "${YELLOW}正在获取组件 [$FILE_SB_INFO] ...${PLAIN}"
                    local script_url=$(get_url_by_name "$FILE_SB_INFO")
                    if [[ -z "$script_url" ]]; then 
                        echo -e "${RED}错误: sh_url.txt 中未找到该文件记录。${PLAIN}"; 
                        read -p "按回车继续..."; continue 
                    fi
                    mkdir -p "$(dirname "$FILE_SB_INFO")"
                    wget -qO "$FILE_SB_INFO" "${script_url}?t=$(date +%s)" 
                    if [[ $? -ne 0 ]]; then 
                         echo -e "${RED}下载失败。${PLAIN}"; 
                         read -p "按回车继续..."; continue 
                    fi
                    chmod +x "$FILE_SB_INFO"
                    echo -e "${GREEN}获取成功。${PLAIN}"
                fi
                ./"$FILE_SB_INFO"
                echo -e ""; read -p "操作结束，按回车键继续..."
                ;;
            8) check_run "$FILE_SB_DEL" ;;
            0) return ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_routing_sb() {
    while true; do
        clear
        echo -e "${BLUE}============= Sing-box 核心路由管理 =============${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} Native WARP (原生 WireGuard 模式 - 推荐)"
        echo -e "    ${GRAY}- 自动注册账号，支持 ChatGPT/Netflix 分流${PLAIN}"
        echo -e " ${GREEN}2.${PLAIN} Wireproxy WARP (Socks5 模式 - 待开发)"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo -e ""
        read -p "请选择: " choice_sb_route
        case $choice_sb_route in
            1) check_run "$FILE_SB_NATIVE_WARP" "true" ;;
            2) echo -e "${RED}功能开发中...${PLAIN}"; sleep 2 ;;
            0) return ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效选择${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_core() {
    while true; do
        clear
        echo -e "${BLUE}============= 前置/核心管理 (Core) =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 安装/重置 Xray 核心环境"
        echo -e " ${SKYBLUE}2.${PLAIN} ${RED}彻底卸载 Xray 服务${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${SKYBLUE}3.${PLAIN} Sing-box 核心环境管理"
        echo -e " ----------------------------------------------"
        echo -e " ${SKYBLUE}4.${PLAIN} WireProxy (Warp 出口代理服务)"
        echo -e " ${SKYBLUE}5.${PLAIN} Cloudflare Tunnel (内网穿透)"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo -e ""
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_XRAY_CORE" ;;
            2) check_run "$FILE_XRAY_UNINSTALL" ;;
            3) menu_singbox_env ;;
            4) check_run "$FILE_WIREPROXY" ;;
            5) check_run "$FILE_CF_TUNNEL" ;;
            0) break ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_nodes() {
    while true; do
        clear
        echo -e "${BLUE}============= 节点配置管理 (Nodes) =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} Xray 核心节点管理 ${YELLOW}(成熟稳定)${PLAIN}"
        echo -e " ${SKYBLUE}2.${PLAIN} Sing-box 节点管理 ${YELLOW}(轻量高效)${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${SKYBLUE}3.${PLAIN} 独立 Hysteria 2 节点管理"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo -e ""
        read -p "请选择: " choice
        case "$choice" in
            1) menu_nodes_xray ;;
            2) menu_nodes_sb ;;
            3) check_run "$FILE_HY2" ;;
            0) break ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_routing() {
    while true; do
        clear
        echo -e "${BLUE}============= 路由与分流规则 (Routing) =============${PLAIN}"
        echo -e " [Xray 核心路由]"
        echo -e " ${GREEN}1. Native WARP (原生模式 - 推荐)${PLAIN}"
        echo -e "    ${GRAY}- 内核直连，支持 全局/分流/指定节点接管${PLAIN}"
        echo -e ""
        echo -e " ${YELLOW}2. Wireproxy WARP (传统挂载模式)${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " [Sing-box 核心路由]"
        echo -e " ${GREEN}3. Sing-box 路由管理 (WARP & 分流)${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo -e ""
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_NATIVE_WARP" "true" ;; 
            2) 
                while true; do
                    clear
                    echo -e "${YELLOW}>>> [传统模式] Wireproxy 挂载管理${PLAIN}"
                    echo -e " 1. 挂载 WARP/Socks5 (解锁流媒体)"
                    echo -e " 2. 解除 挂载 (恢复直连)"
                    echo -e " 0. 返回"
                    echo -e " 99. 返回总菜单"
                    echo -e ""
                    read -p "请选择: " sub_c
                    case "$sub_c" in
                        1) check_run "$FILE_ATTACH" ;;
                        2) check_run "$FILE_DETACH" ;;
                        0) break ;;
                        99) show_main_menu ;;
                    esac
                done
                ;;
            3) menu_routing_sb ;;
            0) break ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

show_main_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}      全能协议管理中心 (Commander v3.9.5)      ${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
        
        STATUS_TEXT=""
        if pgrep -x "xray" >/dev/null; then STATUS_TEXT+="Xray:${GREEN}运行 ${PLAIN}"; else STATUS_TEXT+="Xray:${RED}停止 ${PLAIN}"; fi
        if pgrep -x "sing-box" >/dev/null; then STATUS_TEXT+="| SB:${GREEN}运行 ${PLAIN}"; else STATUS_TEXT+="| SB:${RED}停止 ${PLAIN}"; fi
        
        echo -e " 系统状态: [$STATUS_TEXT]"
        echo -e "--------------------------------------------"
        echo -e " ${SKYBLUE}1.${PLAIN} 前置/核心管理 (Core & Infrastructure)"
        echo -e " ${SKYBLUE}2.${PLAIN} 节点配置管理 (Nodes)"
        echo -e " ${SKYBLUE}3.${PLAIN} 路由规则管理 (Routing & WARP) ${YELLOW}★${PLAIN}"
        echo -e " ${SKYBLUE}4.${PLAIN} 系统优化工具 (BBR/Cert/Logs)"
        echo -e "--------------------------------------------"
        echo -e " ${GRAY}0. 退出脚本${PLAIN}"
        echo -e ""
        read -p "请选择操作 [0-4]: " main_choice

        case "$main_choice" in
            1) menu_core ;;
            2) menu_nodes ;;
            3) menu_routing ;;
            4) check_run "$FILE_BOOST" ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 脚本启动流程
check_dir_clean
check_ipv6_environment
init_urls
show_main_menu
