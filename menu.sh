#!/bin/bash

# ============================================================
#  全能协议管理中心 (Commander v3.3 - 动态链接架构版)
#  - 基础设施: Warp / Cloudflare Tunnel
#  - 核心协议: Xray / Hysteria 2
#  - 特性: 支持从云端 sh_url.txt 动态获取脚本链接
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

# ==========================================
# 1. 核心配置与动态加载系统
# ==========================================

# [关键] 脚本索引文件的下载地址
# 以后所有脚本的 URL 都在这个 txt 里维护，menu.sh 不再写死链接
URL_LIST_FILE="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST_FILE="/tmp/sh_url.txt"

# [本地文件名定义]
# 这些名字必须与 sh_url.txt 第一列的名称完全一致(区分大小写)
FILE_WARP="warp_wireproxy_socks5.sh"
FILE_INSTALL_CF="install_cf_tunnel_debian.sh"

FILE_XRAY_CORE="xray_core.sh"
FILE_ADD_XHTTP="xray_vless_xhttp_reality.sh"
FILE_ADD_VISION="xray_vless_vision_reality.sh"
FILE_ADD_WS="xray_vless_ws_tls.sh"
FILE_ADD_TUNNEL="xray_vless_ws_tunnel.sh"

FILE_NODE_DEL="xray_module_node_del.sh"
FILE_NODE_INFO="xray_get_node_details.sh"
FILE_ATTACH="xray_module_attach_warp.sh"
FILE_DETACH="xray_module_detach_warp.sh"
FILE_BOOST="xray_module_boost.sh"
FILE_XRAY_UNINSTALL="xray_uninstall_all.sh"

FILE_HY2="hy2.sh"

# --- 函数: 初始化链接列表 ---
init_urls() {
    echo -e "${YELLOW}正在同步最新脚本列表...${PLAIN}"
    # 强制下载最新的 url 列表，超时设置为 5 秒
    wget -T 5 -qO "$LOCAL_LIST_FILE" "$URL_LIST_FILE"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}警告: 无法连接 GitHub 获取 sh_url.txt。${PLAIN}"
        if [[ -f "$LOCAL_LIST_FILE" ]]; then
            echo -e "${YELLOW}网络异常，将使用本地缓存的列表继续运行。${PLAIN}"
        else
            echo -e "${RED}致命错误: 无法获取脚本下载地址，且无本地缓存。程序退出。${PLAIN}"
            echo -e "请检查 VPS 网络连接或 GitHub 访问状态。"
            exit 1
        fi
    else
        echo -e "${GREEN}同步完成。${PLAIN}"
    fi
}

# --- 函数: 根据文件名查找 URL ---
get_url_by_name() {
    local fname="$1"
    # 在文件中查找以 fname 开头的行，提取第二列
    # 格式要求: 文件名 https://url...
    local found_url=$(grep "^$fname" "$LOCAL_LIST_FILE" | awk '{print $2}' | head -n 1)
    echo "$found_url"
}

# --- 函数: 检查/下载/运行 (核心) ---
check_run() {
    local script_name="$1"
    
    # 1. 如果文件不存在，则尝试下载
    if [[ ! -f "$script_name" ]]; then
        echo -e "${YELLOW}脚本 [$script_name] 本地不存在，正在查找下载地址...${PLAIN}"
        
        # 动态获取 URL
        local script_url=$(get_url_by_name "$script_name")
        
        if [[ -z "$script_url" ]]; then
            echo -e "${RED}错误: 在 sh_url.txt 中未找到 [$script_name] 的记录。${PLAIN}"
            echo -e "请检查 sh_url.txt 是否包含该文件名的配置。"
            read -p "按回车键返回..."
            return
        fi
        
        echo -e "下载地址: ${GRAY}$script_url${PLAIN}"
        wget -O "$script_name" "$script_url"
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}下载失败！请检查网络或 URL 有效性。${PLAIN}"
            read -p "按回车键返回..."
            return
        fi
        echo -e "${GREEN}下载成功！${PLAIN}"
    fi

    # 2. 赋予权限并运行
    chmod +x "$script_name"
    ./"$script_name"
    
    echo -e ""
    read -p "操作结束，按回车键继续..."
}

# ==========================================
# 2. 菜单逻辑
# ==========================================

# --- 基础设施子菜单 ---
menu_infra() {
    while true; do
        clear
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}      基础设施管理 (Infrastructure)      ${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${SKYBLUE}1.${PLAIN} Warp / WireProxy (出口代理)"
        echo -e "   ${GRAY}- 只有本地端口，用于给 Xray/Hy2 提供干净 IP / 解锁流媒体${PLAIN}"
        echo -e "${SKYBLUE}2.${PLAIN} Cloudflare Tunnel (内网穿透)"
        echo -e "   ${GRAY}- 将本地 Xray 端口映射到公网，无需公网 IP，自带 CDN${PLAIN}"
        echo -e "----------------------------------------"
        echo -e "${GRAY}0. 返回上一级${PLAIN}"
        echo -e ""
        read -p "请选择: " infra_choice

        case "$infra_choice" in
            1) check_run "$FILE_WARP" ;;
            2) check_run "$FILE_INSTALL_CF" ;;
            0) break ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# --- Xray 宇宙子菜单 ---
menu_xray() {
    while true; do
        clear
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}       Xray 宇宙 (The Xray Universe)     ${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${SKYBLUE}1.${PLAIN} 前置安装 / 环境重置"
        echo -e "${SKYBLUE}2.${PLAIN} 节点管理 (新增 / 删除 / 查看)"
        echo -e "${SKYBLUE}3.${PLAIN} 路由分流 (Warp / Socks5)"
        echo -e "${SKYBLUE}4.${PLAIN} 系统内核加速 (BBR + ECN)"
        echo -e "${RED}5.${PLAIN} 彻底卸载 Xray 服务"
        echo -e "----------------------------------------"
        echo -e "${GRAY}0. 返回上一级${PLAIN}"
        echo -e ""
        read -p "请选择操作 [0-5]: " xray_choice

        case "$xray_choice" in
            1)
                while true; do
                    clear
                    echo -e "${YELLOW}>>> [Xray] 子菜单：前置安装与环境${PLAIN}"
                    echo -e "  1. 安装/重置 Xray 核心环境 (Core)"
                    echo -e "  0. 返回上一级"
                    echo -e ""
                    read -p "请选择: " sub_choice_1
                    case "$sub_choice_1" in
                        1) check_run "$FILE_XRAY_CORE" ;;
                        0) break ;;
                        *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
                    esac
                done
                ;;
            2)
                while true; do
                    clear
                    echo -e "${YELLOW}>>> [Xray] 子菜单：节点管理${PLAIN}"
                    echo -e "  1. 新增节点: VLESS-XHTTP (Reality - 穿透强)"
                    echo -e "  2. 新增节点: VLESS-Vision (Reality - 极稳定)"
                    echo -e "  3. ${SKYBLUE}新增节点: VLESS-WS-TLS (CDN / Nginx前置)${PLAIN}"
                    echo -e "  4. ${SKYBLUE}新增节点: VLESS-WS-Tunnel (Cloudflare穿透)${PLAIN}"
                    echo -e "  5. 查看当前节点信息/分享链接"
                    echo -e "  6. ${RED}删除/清空 节点${PLAIN}"
                    echo -e "  0. 返回上一级"
                    echo -e ""
                    read -p "请选择: " sub_choice_2
                    case "$sub_choice_2" in
                        1) check_run "$FILE_ADD_XHTTP" ;;
                        2) check_run "$FILE_ADD_VISION" ;;
                        3) check_run "$FILE_ADD_WS" ;;
                        4) check_run "$FILE_ADD_TUNNEL" ;;
                        5) check_run "$FILE_NODE_INFO" ;;
                        6) check_run "$FILE_NODE_DEL" ;;
                        0) break ;;
                        *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
                    esac
                done
                ;;
            3)
                while true; do
                    clear
                    echo -e "${YELLOW}>>> [Xray] 子菜单：流量出口控制${PLAIN}"
                    echo -e "  1. 挂载 WARP/Socks5 (解锁流媒体/ChatGPT)"
                    echo -e "  2. 解除 挂载 (恢复直连/原生IP)"
                    echo -e "  0. 返回上一级"
                    echo -e ""
                    read -p "请选择: " sub_choice_3
                    case "$sub_choice_3" in
                        1) check_run "$FILE_ATTACH" ;;
                        2) check_run "$FILE_DETACH" ;;
                        0) break ;;
                        *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
                    esac
                done
                ;;
            4) check_run "$FILE_BOOST" ;;
            5) check_run "$FILE_XRAY_UNINSTALL" ;;
            0) break ;;
            *) echo -e "${RED}无效输入，请重试。${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 3. 主程序入口
# ==========================================

# 启动时先初始化链接列表
init_urls

while true; do
    clear
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    全能协议管理中心 (Total Commander)   ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${SKYBLUE}1.${PLAIN} 基础设施: Warp / Tunnel"
    echo -e "    ${GRAY}- 独立服务：IP 优选、流媒体解锁、内网穿透${PLAIN}"
    echo -e ""
    echo -e "${SKYBLUE}2.${PLAIN} Xray 协议簇"
    echo -e "    ${GRAY}- VLESS / Vision / XHTTP / WS / Reality${PLAIN}"
    echo -e ""
    echo -e "${SKYBLUE}3.${PLAIN} Hysteria 2 协议"
    echo -e "    ${GRAY}- UDP / 端口跳跃 / 极速抗封锁${PLAIN}"
    echo -e ""
    echo -e "----------------------------------------"
    echo -e "${GRAY}0. 退出系统${PLAIN}"
    echo -e ""
    read -p "请选择操作 [0-3]: " main_choice

    case "$main_choice" in
        1) menu_infra ;;
        2) menu_xray ;;
        3) check_run "$FILE_HY2" ;;
        0) echo -e "Bye~"; exit 0 ;;
        *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
    esac
done
