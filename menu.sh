#!/bin/bash
# ============================================================
#  全能协议管理中心 (Commander v9.0 System-Wide Fix)
#  - 架构: Xray / Sing-box / Hy2 / Tools 纵向分流
#  - 修复: 纯 IPv6 环境自适应修复 (DNS + GAI)
#  - 升级: 全局时间同步守护
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'
BLUE='\033[0;34m'

# ============================================================
#  GitHub Proxy Injector (Interactive Mode)
# ============================================================
echo -e "${YELLOW}======================================================${PLAIN}"
echo -e "${YELLOW} 是否使用 Cloudflare Worker 代理加速 GitHub 请求?${PLAIN}"
echo -e "${GRAY} (示例: https://my-worker.dev/ ) -- 务必以 https 开头${PLAIN}"
read -p "请输入代理链接 (默认为空/不使用，直接回车): " input_proxy

if [[ -n "$input_proxy" ]]; then
    if [[ "$input_proxy" != */ ]]; then input_proxy="${input_proxy}/"; fi
    export GH_PROXY_URL="$input_proxy"
    echo -e "${GREEN}>>> 已启用代理模式，目标: ${GH_PROXY_URL}${PLAIN}"
    function curl() {
        local args=()
        for arg in "$@"; do
            if [[ "$arg" =~ ^https?://([a-zA-Z0-9-]+\.)?github(usercontent)?\.com ]]; then
                [[ "$arg" != *"$GH_PROXY_URL"* ]] && arg="${GH_PROXY_URL}${arg}"
            fi
            args+=("$arg")
        done
        command curl "${args[@]}"
    }
    function wget() {
        local args=()
        for arg in "$@"; do
            if [[ "$arg" =~ ^https?://([a-zA-Z0-9-]+\.)?github(usercontent)?\.com ]]; then
                [[ "$arg" != *"$GH_PROXY_URL"* ]] && arg="${GH_PROXY_URL}${arg}"
            fi
            args+=("$arg")
        done
        command wget "${args[@]}"
    }
    export -f curl
    export -f wget
else
    echo -e "${GRAY}>>> 未输入代理，将使用直连模式 (Direct Mode)。${PLAIN}"
fi
echo -e "${YELLOW}======================================================${PLAIN}"
echo ""

# ==========================================
# 1. 核心配置
# ==========================================
URL_LIST_FILE="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST_FILE="/tmp/sh_url.txt"

FILE_XRAY_CORE="xray_core.sh"
FILE_XRAY_UNINSTALL="xray_uninstall_all.sh"
FILE_ADD_XHTTP="xray_vless_xhttp_reality.sh"
FILE_ADD_VISION="xray_vless_vision_reality.sh"
FILE_ADD_WS="xray_vless_ws_tls.sh"
FILE_ADD_TUNNEL="xray_vless_ws_tunnel.sh"
FILE_XRAY_WARP="xray_module_warp_native_route.sh"
FILE_XRAY_INFO="xray_get_node_details.sh"
FILE_XRAY_DEL="xray_module_node_del.sh"

FILE_SB_CORE="sb_install_core.sh"
FILE_SB_UNINSTALL="sb_uninstall.sh"
FILE_SB_ADD_ANYTLS="sb_anytls_reality.sh"
FILE_SB_ADD_VISION="sb_vless_vision_reality.sh"
FILE_SB_ADD_WS="sb_vless_ws_tls.sh"
FILE_SB_ADD_TUNNEL="sb_vless_ws_tunnel.sh"
FILE_SB_ADD_HY2="sb_hy2_deploy.sh"
FILE_SB_WARP="sb_module_warp_native_route.sh"
FILE_SB_INFO="sb_get_node_details.sh"
FILE_SB_DEL="sb_module_node_del.sh"

FILE_HY2="hy2.sh"
FILE_BOOST="sys_tools.sh"
FILE_CF_TUNNEL="install_cf_tunnel_debian.sh"
FILE_FIX_IPV6="fix_ipv6_dual_core.sh"

# ============================================================
#  [核心] 系统环境初始化与检测 (v9.0 Safe Logic)
# ============================================================
system_init_check() {
    echo -e "${YELLOW}>>> [系统初始化] 正在执行环境预处理...${PLAIN}"

    # --- 1. 全局时间同步 ---
    echo -e "${YELLOW}   > 正在校准系统时间...${PLAIN}"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true >/dev/null 2>&1
        systemctl enable systemd-timesyncd >/dev/null 2>&1
        systemctl start systemd-timesyncd >/dev/null 2>&1
    elif command -v ntpd >/dev/null 2>&1; then
        service ntpd start >/dev/null 2>&1
    else
        apt-get update -y >/dev/null 2>&1
        apt-get install -y systemd-timesyncd >/dev/null 2>&1
        systemctl enable systemd-timesyncd >/dev/null 2>&1
        systemctl start systemd-timesyncd >/dev/null 2>&1
    fi
    echo -e "${GREEN}   > 时间同步完成: $(date)${PLAIN}"

    # --- 2. 网络环境检测 ---
    echo -e "${YELLOW}   > 正在检测网络连通性 (Strict Mode)...${PLAIN}"
    local ipv4_check=$(curl -4 -s -m 2 http://ip.sb 2>/dev/null)
    if [[ "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${GREEN}   > 检测到有效 IPv4 出口 ($ipv4_check)。${PLAIN}"
        echo -e "${GREEN}   > 维持系统默认配置，跳过环境修改。${PLAIN}"
        return 0
    fi

    # === 纯 IPv6 特殊支线 ===
    echo -e "${YELLOW}======================================================${PLAIN}"
    echo -e "${RED}⚠️  检测到纯 IPv6 环境 (无 IPv4 链路)${PLAIN}"
    echo -e "${GRAY}   启动特殊适配策略: DNS 优化 + IPv6 优先${PLAIN}"
    echo -e "${YELLOW}======================================================${PLAIN}"

    # A. DNS 优化
    if [[ ! -f /etc/resolv.conf.bak ]]; then cp /etc/resolv.conf /etc/resolv.conf.bak; fi
    chattr -i /etc/resolv.conf >/dev/null 2>&1
    echo -e "nameserver 2001:4860:4860::8888\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf
    chattr +i /etc/resolv.conf >/dev/null 2>&1
    echo -e "${GREEN}   > DNS 已锁定为 Google/CF。${PLAIN}"

    # B. [修复] 强制系统级 IPv6 优先
    echo -e "${YELLOW}   > 正在调整地址选择策略 (/etc/gai.conf)...${PLAIN}"
    if [ ! -f /etc/gai.conf ]; then
        cat > /etc/gai.conf <<EOF
label  ::1/128       0
label  ::/0          1
label  2002::/16     2
label ::/96          3
label ::ffff:0:0/96  4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence ::/96          20
precedence ::ffff:0:0/96  10
EOF
    fi
    if ! grep -q "^precedence ::ffff:0:0/96  10" /etc/gai.conf; then
        sed -i '/^precedence ::ffff:0:0\/96/d' /etc/gai.conf
        echo "precedence ::ffff:0:0/96  10" >> /etc/gai.conf
        echo -e "${GREEN}   > 已降级 IPv4 优先级，强制 IPv6 直连。${PLAIN}"
    else
        echo -e "${GREEN}   > 策略已存在，跳过。${PLAIN}"
    fi
}

check_dir_clean() {
    local current_script=$(basename "$0")
    local file_count=$(ls -1 | grep -v "^$current_script$" | wc -l)
    if [[ "$file_count" -gt 0 ]]; then
        echo -e "${YELLOW}======================================================${PLAIN}"
        echo -e "${YELLOW} 检测到目录下存在 $file_count 个文件。${PLAIN}"
        echo -e "${RED} 警告：如果你手动上传了 fix_ipv6 等补丁，请务必选 n！${PLAIN}"
        echo -e ""
        read -p "是否清空目录并强制更新? (y/n, 默认 n): " clean_opt
        if [[ "$clean_opt" == "y" ]]; then
            ls | grep -v "^$current_script$" | xargs rm -rf
            echo -e "${GREEN}清理完成。${PLAIN}"; sleep 1
        fi
    fi
}

init_urls() {
    echo -e "${YELLOW}正在同步脚本列表...${PLAIN}"
    # 调用代理逻辑下载
    wget -T 15 -t 3 -qO "$LOCAL_LIST_FILE" "${URL_LIST_FILE}?t=$(date +%s)"
    if [[ $? -ne 0 ]]; then
        [[ -f "$LOCAL_LIST_FILE" ]] && echo -e "${YELLOW}网络异常，使用缓存列表。${PLAIN}" || { echo -e "${RED}错误: 无法获取列表。${PLAIN}"; exit 1; }
    else
        echo -e "${GREEN}同步完成。${PLAIN}"
    fi
}

get_url_by_name() { grep "^$1" "$LOCAL_LIST_FILE" | awk '{print $2}' | head -n 1; }

check_run() {
    local script_name="$1"
    local no_pause="$2"
    if [[ ! -f "$script_name" ]]; then
        echo -e "${YELLOW}正在下载组件 [$script_name] ...${PLAIN}"
        local script_url=$(get_url_by_name "$script_name")
        [[ -z "$script_url" ]] && { echo -e "${RED}错误: sh_url.txt 未找到记录。${PLAIN}"; read -p "按回车继续..."; return; }
        wget -qO "$script_name" "${script_url}?t=$(date +%s)"
        [[ $? -ne 0 ]] && { echo -e "${RED}下载失败。${PLAIN}"; read -p "按回车继续..."; return; }
        chmod +x "$script_name"
    fi
    ./"$script_name"
    [[ "$no_pause" != "true" ]] && { echo -e ""; read -p "操作结束，按回车键继续..."; }
}

menu_xray() {
    while true; do
        clear; echo -e "${BLUE}============= XRAY 核心系列 =============${PLAIN}"
        echo -e " ${GRAY}[环境管理]${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 安装/更新 Xray 核心 ${GRAY}[$FILE_XRAY_CORE]${PLAIN}"
        echo -e " ${SKYBLUE}2.${PLAIN} ${RED}卸载 Xray 服务${PLAIN}      ${GRAY}[$FILE_XRAY_UNINSTALL]${PLAIN}"
        echo -e " ----------------------------------------"
        echo -e " ${GRAY}[节点添加]${PLAIN}"
        echo -e " ${GREEN}3.${PLAIN} VLESS-Vision-Reality ${GRAY}[$FILE_ADD_VISION]${PLAIN}"
        echo -e " ${GREEN}4.${PLAIN} VLESS-WS-TLS (CDN)   ${GRAY}[$FILE_ADD_WS]${PLAIN}"
        echo -e " ${GREEN}5.${PLAIN} VLESS-WS-Tunnel      ${GRAY}[$FILE_ADD_TUNNEL]${PLAIN}"
        echo -e " ${GREEN}6.${PLAIN} VLESS-XHTTP-Reality  ${GRAY}[$FILE_ADD_XHTTP]${PLAIN}"
        echo -e " ----------------------------------------"
        echo -e " ${GRAY}[路由与维护]${PLAIN}"
        echo -e " ${SKYBLUE}7.${PLAIN} Native WARP (接管)   ${GRAY}[$FILE_XRAY_WARP]${PLAIN}"
        echo -e " ${SKYBLUE}8.${PLAIN} 查看节点链接         ${GRAY}[$FILE_XRAY_INFO]${PLAIN}"
        echo -e " ${SKYBLUE}9.${PLAIN} 删除指定节点         ${GRAY}[$FILE_XRAY_DEL]${PLAIN}"
        echo -e " ----------------------------------------"
        echo -e " ${GRAY}0. 返回主菜单${PLAIN}"
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_XRAY_CORE" ;; 2) check_run "$FILE_XRAY_UNINSTALL" ;;
            3) check_run "$FILE_ADD_VISION" ;; 4) check_run "$FILE_ADD_WS" ;;
            5) check_run "$FILE_ADD_TUNNEL" ;; 6) check_run "$FILE_ADD_XHTTP" ;;
            7) check_run "$FILE_XRAY_WARP" "true" ;; 8) check_run "$FILE_XRAY_INFO" ;; 9) check_run "$FILE_XRAY_DEL" ;;
            0) return ;; *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_singbox() {
    while true; do
        clear; echo -e "${BLUE}============= SING-BOX 核心系列 =============${PLAIN}"
        echo -e " ${GRAY}[环境管理]${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 安装/更新 Sing-box   ${GRAY}[$FILE_SB_CORE]${PLAIN}"
        echo -e " ${SKYBLUE}2.${PLAIN} ${RED}卸载 Sing-box 服务${PLAIN}   ${GRAY}[$FILE_SB_UNINSTALL]${PLAIN}"
        echo -e " ----------------------------------------"
        echo -e " ${GRAY}[节点添加]${PLAIN}"
        echo -e " ${GREEN}3.${PLAIN} AnyTLS-Reality       ${GRAY}[$FILE_SB_ADD_ANYTLS]${PLAIN}"
        echo -e " ${GREEN}4.${PLAIN} VLESS-Vision-Reality ${GRAY}[$FILE_SB_ADD_VISION]${PLAIN}"
        echo -e " ${GREEN}5.${PLAIN} VLESS-WS-TLS         ${GRAY}[$FILE_SB_ADD_WS]${PLAIN}"
        echo -e " ${GREEN}6.${PLAIN} VLESS-WS-Tunnel      ${GRAY}[$FILE_SB_ADD_TUNNEL]${PLAIN}"
        echo -e " ${GREEN}7.${PLAIN} Hysteria2 (智能部署) ${GRAY}[$FILE_SB_ADD_HY2]${PLAIN}"
        echo -e " ----------------------------------------"
        echo -e " ${GRAY}[路由与维护]${PLAIN}"
        echo -e " ${SKYBLUE}8.${PLAIN} Native WARP (接管)   ${GRAY}[$FILE_SB_WARP]${PLAIN}"
        echo -e " ${SKYBLUE}9.${PLAIN} 查看节点链接        ${GRAY}[$FILE_SB_INFO]${PLAIN}"
        echo -e " ${SKYBLUE}10.${PLAIN} 删除指定节点        ${GRAY}[$FILE_SB_DEL]${PLAIN}"
        echo -e " ----------------------------------------"
        echo -e " ${GRAY}0. 返回主菜单${PLAIN}"
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_SB_CORE" ;; 2) check_run "$FILE_SB_UNINSTALL" ;;
            3) check_run "$FILE_SB_ADD_ANYTLS" ;; 4) check_run "$FILE_SB_ADD_VISION" ;;
            5) check_run "$FILE_SB_ADD_WS" ;; 6) check_run "$FILE_SB_ADD_TUNNEL" ;;
            7) check_run "$FILE_SB_ADD_HY2" ;; 8) check_run "$FILE_SB_WARP" "true" ;; 
            9) check_run "$FILE_SB_INFO" ;; 10) check_run "$FILE_SB_DEL" ;;
            0) return ;; *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_system() {
    while true; do
        clear; echo -e "${BLUE}============= 系统优化工具 =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 系统维护 (BBR/Cert)  ${GRAY}[$FILE_BOOST]${PLAIN}"
        echo -e " ${SKYBLUE}2.${PLAIN} CF Tunnel (Argo)     ${GRAY}[$FILE_CF_TUNNEL]${PLAIN}"
        echo -e " ${SKYBLUE}3.${PLAIN} IPv6 启动修复补丁    ${GRAY}[$FILE_FIX_IPV6]${PLAIN}"
        echo -e " ----------------------------------------"
        echo -e " ${GRAY}0. 返回主菜单${PLAIN}"
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_BOOST" ;; 2) check_run "$FILE_CF_TUNNEL" ;; 3) check_run "$FILE_FIX_IPV6" ;;
            0) return ;; *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

show_main_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}      全能协议管理中心 (Commander v9.0)      ${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
        STATUS_TEXT=""
        pgrep -x "xray" >/dev/null && STATUS_TEXT+="Xray:${GREEN}运行 ${PLAIN}" || STATUS_TEXT+="Xray:${RED}停止 ${PLAIN}"
        pgrep -x "sing-box" >/dev/null && STATUS_TEXT+="| SB:${GREEN}运行 ${PLAIN}" || STATUS_TEXT+="| SB:${RED}停止 ${PLAIN}"
        echo -e " 系统状态: [$STATUS_TEXT]"
        echo -e "--------------------------------------------"
        echo -e " ${SKYBLUE}1.${PLAIN} XRAY 核心系列      ${GRAY}(Xray Core Series)${PLAIN}"
        echo -e " ${SKYBLUE}2.${PLAIN} SINGBOX 核心系列   ${GRAY}(Sing-box Core Series)${PLAIN}"
        echo -e " ${SKYBLUE}3.${PLAIN} 独立 HY2 协议      ${GRAY}[$FILE_HY2]${PLAIN}"
        echo -e " ${SKYBLUE}4.${PLAIN} 系统优化工具       ${GRAY}(System Tools)${PLAIN}"
        echo -e "--------------------------------------------"
        echo -e " ${GRAY}0. 退出脚本${PLAIN}"
        echo ""
        read -p "请选择操作 [0-4]: " main_choice
        case "$main_choice" in
            1) menu_xray ;; 2) menu_singbox ;; 3) check_run "$FILE_HY2" ;; 4) menu_system ;;
            0) exit 0 ;; *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 脚本启动
check_dir_clean
# [关键] 调用系统环境初始化 (时间 + 网络)
system_init_check

init_urls
show_main_menu
