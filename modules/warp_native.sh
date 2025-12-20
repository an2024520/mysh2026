#!/bin/bash

# ============================================================
#  Native WARP 增强模块 (Standalone)
#  无需 Wireproxy，由 Xray/Singbox 内核直接连接 Cloudflare
# ============================================================

WARP_CONF_FILE="/etc/my_script/warp_native.conf"
mkdir -p "$(dirname "$WARP_CONF_FILE")"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[33m'
PLAIN='\033[0m'

# --- 核心功能函数 ---

check_warp_dependencies() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 Python3 (用于计算 WARP Reserved 值)...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y python3
        elif [ -f /etc/redhat-release ]; then
            yum install -y python3
        fi
    fi
}

get_warp_credentials() {
    check_warp_dependencies
    clear
    echo "========================================"
    echo "       Native WARP 凭证配置"
    echo "========================================"
    echo "1. 自动注册 (使用 wgcf 工具)"
    echo "2. 手动输入 (已有私钥和 Reserved)"
    echo "========================================"
    read -p "请选择 [1-2]: " choice

    local wp_key=""
    local wp_ip=""
    local wp_res=""

    if [ "$choice" == "1" ]; then
        echo "正在下载 wgcf 工具并注册账户..."
        local arch=$(uname -m)
        local wgcf_arch="amd64"
        case "$arch" in
            aarch64) wgcf_arch="arm64" ;;
            x86_64) wgcf_arch="amd64" ;;
            *) echo "不支持的架构: $arch"; read -p "按回车退出..."; return 1 ;;
        esac

        local tmp_dir=$(mktemp -d)
        pushd "$tmp_dir" >/dev/null || return

        wget -qO wgcf "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${wgcf_arch}"
        chmod +x wgcf
        
        echo "注册账户中..."
        ./wgcf register --accept-tos >/dev/null 2>&1
        ./wgcf generate >/dev/null 2>&1

        if [ ! -f wgcf-profile.conf ]; then
            echo -e "${RED}错误：WARP 注册失败，无法生成配置文件。${PLAIN}"
            popd >/dev/null; rm -rf "$tmp_dir"; read -p "按回车退出..."; return 1
        fi

        wp_key=$(grep 'PrivateKey' wgcf-profile.conf | cut -d ' ' -f 3 | tr -d '\n\r ')
        local raw_addr=$(grep 'Address' wgcf-profile.conf | cut -d '=' -f 2 | tr -d ' ')
        if [[ "$raw_addr" == *","* ]]; then
            wp_ip=$(echo "$raw_addr" | awk -F',' '{print $2}' | cut -d'/' -f1 | tr -d '\n\r ')
        else
            wp_ip=$(echo "$raw_addr" | cut -d'/' -f1 | tr -d '\n\r ')
        fi

        local client_id=$(grep "client_id" wgcf-account.toml | cut -d '"' -f 2)
        if [ -n "$client_id" ]; then
            wp_res=$(python3 -c "import base64; d=base64.b64decode('${client_id}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')")
        else
            wp_res="[]"
        fi

        echo -e "${GREEN}注册成功！${PLAIN}"
        echo "PrivateKey: $wp_key"
        echo "Reserved:   $wp_res"
        
        popd >/dev/null
        rm -rf "$tmp_dir"

    elif [ "$choice" == "2" ]; then
        read -p "请输入 WARP Private Key: " wp_key
        read -p "请输入 Reserved 值 (格式如 [123, 45, 67]): " wp_res
        wp_ip="2606:4700:110:8d8d:1845:c39f:2dd5:a03a"
    else
        return 1
    fi

    cat > "$WARP_CONF_FILE" <<EOF
WP_KEY="$wp_key"
WP_IP="$wp_ip"
WP_RES="$wp_res"
EOF
    echo -e "${GREEN}配置已保存至 $WARP_CONF_FILE${PLAIN}"
    read -p "按回车键继续..."
}

generate_warp_json() {
    local core_type="$1"
    if [ ! -f "$WARP_CONF_FILE" ]; then return 1; fi
    source "$WARP_CONF_FILE"

    local warp_addr_json
    if [[ "$WP_IP" =~ .*:.* ]]; then 
        warp_addr_json="\"172.16.0.2/32\", \"${WP_IP}/128\""
    else 
        warp_addr_json="\"${WP_IP}/32\", \"2606:4700:110:8d8d:1845:c39f:2dd5:a03a/128\""
    fi
    local pub_key="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    local endpoint_host="engage.cloudflareclient.com"

    if [ "$core_type" == "xray" ]; then
        cat <<EOF
{
  "tag": "warp-out",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${WP_KEY}",
    "address": [ ${warp_addr_json} ],
    "peers": [
      {
        "publicKey": "${pub_key}",
        "endpoint": "${endpoint_host}:2408",
        "reserved": ${WP_RES}
      }
    ]
  }
}
EOF
    elif [ "$core_type" == "singbox" ]; then
        cat <<EOF
{
  "type": "wireguard",
  "tag": "warp-out",
  "address": [ ${warp_addr_json} ],
  "private_key": "${WP_KEY}",
  "peers": [
    {
      "server": "${endpoint_host}",
      "server_port": 2408,
      "public_key": "${pub_key}",
      "reserved": ${WP_RES}
    }
  ]
}
EOF
    fi
}

# --- 交互菜单 (主入口) ---

show_warp_menu() {
    while true; do
        clear
        # 状态检测
        local status_text="${RED}未配置${PLAIN}"
        if [ -f "$WARP_CONF_FILE" ]; then status_text="${GREEN}已配置${PLAIN}"; fi
        
        echo -e "${GREEN}================ Native WARP 配置向导 ================${PLAIN}"
        echo -e " 当前状态: [WARP: $status_text]  [策略: 智能分流/全局/无]"
        echo -e "----------------------------------------------------"
        echo -e " [基础账号]"
        echo -e " 1. 注册/导入 WARP 账户 (自动/手动)"
        echo -e "    ${GRAY}(说明: 必须先获取账户才能开启后续模式)${PLAIN}"
        echo -e " 2. 查看当前账户配额与 IP 信息"
        echo -e ""
        echo -e " [策略模式 - 单选]"
        echo -e " 3. ${SKYBLUE}模式一：智能流媒体分流 (默认推荐)${PLAIN}"
        echo -e "    ${GRAY}(说明: 仅 Netflix/Disney+/ChatGPT/Google 走 WARP，其他直连)${PLAIN}"
        echo -e ""
        echo -e " 4. ${SKYBLUE}模式二：全局接管 (拯救 IP / 隐藏身份)${PLAIN}"
        echo -e "    ${GRAY}---> 进入子菜单 (IPv4 / IPv6 / 双栈接管)${PLAIN}"
        echo -e ""
        echo -e " 5. ${SKYBLUE}模式三：指定节点接管 (多节点共存)${PLAIN}"
        echo -e "    ${GRAY}(说明: 列出当前所有节点，选择特定端口强制走 WARP)${PLAIN}"
        echo -e ""
        echo -e " [维护]"
        echo -e " 7. ${RED}禁用/卸载 Native WARP (清除所有 WARP 路由)${PLAIN}"
        echo -e " 0. 返回上级菜单"
        echo -e "===================================================="
        read -p "请输入选项: " choice

        case "$choice" in
            1) get_warp_credentials ;;
            2) 
                if [ -f "$WARP_CONF_FILE" ]; then
                    source "$WARP_CONF_FILE"
                    echo -e "Private Key: ${YELLOW}$WP_KEY${PLAIN}"
                    echo -e "IPv6 Address: ${YELLOW}$WP_IP${PLAIN}"
                    echo -e "Reserved: ${YELLOW}$WP_RES${PLAIN}"
                else
                    echo "暂无配置信息。"
                fi
                read -p "按回车继续..."
                ;;
            3) echo "功能开发中... (即将对接 Xray 配置文件)"; sleep 2 ;;
            4) echo "功能开发中... (即将对接全局路由)"; sleep 2 ;;
            5) echo "功能开发中... (即将读取节点列表)"; sleep 2 ;;
            7) echo "功能开发中... (即将清理路由)"; sleep 2 ;;
            0) break ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# --- 脚本入口 ---
# 直接调用菜单，配合 check_run 使用
show_warp_menu
