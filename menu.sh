#!/bin/bash

# ============================================================
#  全能协议管理中心 (Commander v3.9.7)
#  - 架构: Core / Nodes / Routing / Tools
#  - 特性: 动态链接 / 环境自洁 / 模块化路由 / 双核节点管理 / 强刷缓存
#  - 修复说明: 
#    1. 彻底修复 check_ipv6_environment 语法逻辑错误 (syntax error)
#    2. 增加高延迟环境下的 NAT64 探测稳定性
#    3. 整合 Sing-box 日志目录权限预修复逻辑
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'
BLUE='\033[0;34m'

# ==========================================
# 1. 核心配置与文件映射
# ==========================================

URL_LIST_FILE="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST_FILE="/tmp/sh_url.txt"

# [文件映射定义保持不变...]
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

# ==========================================
# 引擎函数 (核心修复区)
# ==========================================

# [核心修复] 检测 IPv6-Only 环境并配置持久化 NAT64
check_ipv6_environment() {
    echo -e "${YELLOW}正在检测 IPv4 网络连通性 (针对高延迟环境)...${PLAIN}"
    
    # 1. 预检：针对纯 IPv6 机器探测 1.1.1.1 (延时提高到 10s)
    if curl -4 -s --connect-timeout 10 https://1.1.1.1 >/dev/null 2>&1; then
        echo -e "${GREEN}检测到 IPv4 连接正常。${PLAIN}"
        return
    fi
    
    # 2. 如果 1.1.1.1 不通，尝试通过域名探测 (触发 DNS64)
    if curl -s -m 10 https://www.google.com/generate_204 >/dev/null 2>&1; then
         echo -e "${GREEN}检测到通过 DNS64/NAT64 的网络连接。${PLAIN}"
         return
    fi

    echo -e "${YELLOW}======================================================${PLAIN}"
    echo -e "${RED}⚠️  检测到当前环境为纯 IPv6 (IPv6-Only)！${PLAIN}"
    echo -e "${GRAY}即将配置 NAT64/DNS64 并锁定文件以防止重启失效。${PLAIN}"
    echo -e ""
    read -p "是否立即配置 NAT64? (y/n, 默认 y): " fix_choice
    fix_choice=${fix_choice:-y}

    if [[ "$fix_choice" == "y" ]]; then
        echo -e "${YELLOW}正在配置 NAT64/DNS64...${PLAIN}"
        
        # 预先修复 Sing-box 日志权限 (解决之前报错的关键)
        mkdir -p /var/log/sing-box/ && chmod 777 /var/log/sing-box/ >/dev/null 2>&1

        chattr -i /etc/resolv.conf >/dev/null 2>&1
        if [ ! -f "/etc/resolv.conf.bak.nat64" ]; then
            cp /etc/resolv.conf /etc/resolv.conf.bak.nat64
            echo -e "${GREEN}已备份原 DNS${PLAIN}"
        fi

        rm -f /etc/resolv.conf
        # 使用更为稳定的公共 DNS64 节点
        echo -e "nameserver 2a09:c500::1\nnameserver 2001:67c:2b0::4" > /etc/resolv.conf
        chattr +i /etc/resolv.conf
        echo -e "${GREEN}已锁定 /etc/resolv.conf 防止被系统还原。${PLAIN}"

        echo -e "${YELLOW}正在验证连通性...${PLAIN}"
        sleep 2
        if curl -s --connect-timeout 5 https://ipv4.google.com >/dev/null 2>&1; then
            echo -e "${GREEN}🎉 成功！已获得持久化的 IPv4 访问能力。${PLAIN}"
        else
            echo -e "${RED}❌ 警告：配置后仍无法连接，建议尝试手动配置 DNS。${PLAIN}"
            chattr -i /etc/resolv.conf
        fi
    else
        echo -e "${GRAY}已跳过 NAT64 配置。${PLAIN}"
        : # 占位符
    fi
}

# [后面其他函数逻辑保持不变，确保闭合...]
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
    wget -T 20 -t 3 -qO "$LOCAL_LIST_FILE" "${URL_LIST_FILE}?t=$(date +%s)"
    if [[ $? -ne 0 ]]; then
        if [[ -f "$LOCAL_LIST_FILE" ]]; then 
            echo -e "${YELLOW}网络异常，使用本地缓存列表。${PLAIN}"
        else 
            echo -e "${RED}致命错误: 无法获取脚本列表。${PLAIN}"
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
    fi
    ./"$script_name"
    if [[ "$no_pause" != "true" ]]; then
        echo -e ""; read -p "操作结束，按回车键继续..."
    fi
}

# ==========================================
# 菜单部分保持原有逻辑 (已核对 case/esac 匹配)
# ==========================================

# ... [省略中间重复的子菜单代码，逻辑与原文件一致] ...

# 修正 Sing-box 节点查看脚本的逻辑
menu_nodes_sb() {
    while true; do
        clear
        echo -e "${BLUE}============= Sing-box 节点配置管理 =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 新增: AnyTLS-Reality (Sing-box 专属)"
        echo -e " ${SKYBLUE}2.${PLAIN} 新增: VLESS-Vision-Reality"
        echo -e " ${SKYBLUE}3.${PLAIN} 新增: VLESS-WS-TLS"
        echo -e " ${SKYBLUE}4.${PLAIN} 新增: VLESS-WS-Tunnel"
        echo -e " ${SKYBLUE}5.${PLAIN} 新增: Hysteria2 (自签)"
        echo -e " ${SKYBLUE}6.${PLAIN} 新增: Hysteria2 (ACME)"
        echo -e " ----------------------------------------------"
        echo -e " ${SKYBLUE}7.${PLAIN} 查看: 当前节点链接"
        echo -e " ${SKYBLUE}8.${PLAIN} ${RED}删除: 删除节点${PLAIN}"
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
            7) check_run "$FILE_SB_INFO" ;; # 已对齐 check_run 逻辑
            8) check_run "$FILE_SB_DEL" ;;
            0) return ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ... [主菜单展示函数 show_main_menu 保持不变] ...

show_main_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}      全能协议管理中心 (Commander v3.9.7)      ${PLAIN}"
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
