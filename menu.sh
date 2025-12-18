#!/bin/bash

# ============================================================
#  全能协议管理中心 (Commander v3.4 - 动态链接 & 环境自洁)
#  - 基础设施: Warp / Cloudflare Tunnel
#  - 核心协议: Xray / Hysteria 2
#  - 特性: 动态获取链接 / 开局环境检查 / 强制更新模式
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

# 脚本索引文件的下载地址
URL_LIST_FILE="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST_FILE="/tmp/sh_url.txt"

# [本地文件名定义]
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

# --- 函数: 环境清理与更新检查 (新增) ---
check_dir_clean() {
    local current_script=$(basename "$0")
    # 统计当前目录下除了脚本自己以外的文件数量
    local file_count=$(ls -1 | grep -v "^$current_script$" | wc -l)

    # 只有当目录下有其他文件时才询问
    if [[ "$file_count" -gt 0 ]]; then
        echo -e "${YELLOW}======================================================${PLAIN}"
        echo -e "${YELLOW} 检测到当前目录 [ $(pwd) ] 下存在 $file_count 个历史文件/杂项。${PLAIN}"
        echo -e "${YELLOW}======================================================${PLAIN}"
        echo -e "为了确保脚本运行在最新状态，建议在【空文件夹】下运行。"
        echo -e "您可以选择清空当前目录（保留本脚本），这等同于【强制更新】所有组件。"
        echo -e ""
        read -p "是否清空当前目录文件并重新下载? (y/n, 默认 n): " clean_opt
        
        if [[ "$clean_opt" == "y" ]]; then
            echo -e "${RED}警告: 即将删除 $(pwd) 下除 $current_script 外的所有文件！${PLAIN}"
            read -p "请再次确认 (输入 y 确认): " confirm_clean
            if [[ "$confirm_clean" == "y" ]]; then
                echo -e "${YELLOW}正在清理...${PLAIN}"
                # 遍历删除，确保不删自己
                ls | grep -v "^$current_script$" | xargs rm -rf
                echo -e "${GREEN}清理完成！${PLAIN}"
                echo -e "${GREEN}旧组件已移除，接下来的操作将自动下载最新版脚本。${PLAIN}"
                sleep 1
            else
                echo -e "操作取消。"
            fi
        else
            echo -e "${GRAY}保留现有文件继续运行... (如遇报错请尝试清空目录)${PLAIN}"
        fi
        echo -e ""
    fi
}

# --- 函数: 初始化链接列表 ---
init_urls() {
    echo -e "${YELLOW}正在同步最新脚本列表...${PLAIN}"
    wget -T 5 -qO "$LOCAL_LIST_FILE" "$URL_LIST_FILE"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}警告: 无法连接 GitHub 获取 sh_url.txt。${PLAIN}"
        if [[ -f "$LOCAL_LIST_FILE" ]]; then
            echo -e "${YELLOW}网络异常，将使用本地缓存的列表继续运行。${PLAIN}"
        else
            echo -e "${RED}致命错误: 无法获取脚本下载地址，且无本地缓存。程序退出。${PLAIN}"
            exit 1
        fi
    else
        echo -e "${GREEN}同步完成。${PLAIN}"
    fi
}

# --- 函数: 根据文件名查找 URL ---
get_url_by_name() {
    local fname="$1"
    local found_url=$(grep "^$fname" "$LOCAL_LIST_FILE" | awk '{print $2}' | head -n 1)
    echo "$found_url"
}

# --- 函数: 检查/下载/运行 ---
check_run() {
    local script_name="$1"
    
    # 如果文件不存在(或已被清理)，则下载
    if [[ ! -f "$script_name" ]]; then
        echo -e "${YELLOW}脚本 [$script_name] 本地不存在，正在获取最新版...${PLAIN}"
        
        local script_url=$(get_url_by_name "$script_name")
        
        if [[ -z "$script_url" ]]; then
            echo -e "${RED}错误: 在 sh_url.txt 中未找到 [$script_name] 的记录。${PLAIN}"
            read -p "按回车键返回..."
            return
        fi
        
        wget -O "$script_name" "$script_url"
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}下载失败！请检查网络。${PLAIN}"
            read -p "按回车键返回..."
            return
        fi
        echo -e "${GREEN}下载成功！${PLAIN}"
    fi

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

# 1. 开局先检查环境是否干净 (询问是否清理/更新)
check_dir_clean

# 2. 同步最新的脚本链接
init_urls

# 3. 进入主循环
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
