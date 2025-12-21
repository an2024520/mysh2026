#!/bin/bash

# ============================================================
#  Sing-box Native WARP 管理模块 (SB-Commander v3.9.1)
#  - 核心: WireGuard 原生出站 / 动态路由管理
#  - 特性: 智能路径 / 延迟加载Python / 纯Shell解码 / 纯净分流
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# ==========================================
# 1. 环境初始化与依赖检查
# ==========================================

# 智能查找 Sing-box 配置文件路径
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then
        CONFIG_FILE="$p"
        break
    fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未检测到 config.json 配置文件！${PLAIN}"
    echo -e "请确认 Sing-box 是否已安装，或手动指定路径。"
    exit 1
fi

# 检查基础依赖 (去除了 python3 的全局检查)
check_dependencies() {
    local missing=0
    if ! command -v jq &> /dev/null; then echo -e "${RED}缺失工具: jq${PLAIN}"; missing=1; fi
    if ! command -v curl &> /dev/null; then echo -e "${RED}缺失工具: curl${PLAIN}"; missing=1; fi
    # 增加对 od 的检查 (用于手动模式下的 Base64 解码，通常系统自带)
    if ! command -v od &> /dev/null; then echo -e "${YELLOW}提示: 缺失 od 工具 (用于免 Python 解码)${PLAIN}"; fi
    
    if [[ $missing -eq 1 ]]; then
        echo -e "${YELLOW}正在安装基础依赖...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y jq curl
        elif [ -x "$(command -v yum)" ]; then
            yum install -y jq curl
        fi
    fi
}

# 专门用于自动注册时的 Python 检查函数 (按需调用)
ensure_python() {
    if ! command -v python3 &> /dev/null; then
        echo -e "${YELLOW}自动注册算法需要 Python3 支持，正在安装...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y python3
        elif [ -x "$(command -v yum)" ]; then
            yum install -y python3
        fi
        
        if ! command -v python3 &> /dev/null; then
            echo -e "${RED}Python3 安装失败，无法进行自动注册计算。${PLAIN}"
            return 1
        fi
    fi
    return 0
}

# 重启 Sing-box
restart_sb() {
    echo -e "${YELLOW}重启 Sing-box 服务...${PLAIN}"
    if systemctl list-unit-files | grep -q sing-box; then
        systemctl restart sing-box
    else
        pkill -xf "sing-box run -c $CONFIG_FILE"
        nohup sing-box run -c "$CONFIG_FILE" > /dev/null 2>&1 &
    fi
    
    sleep 2
    if systemctl is-active --quiet sing-box || pgrep -x "sing-box" >/dev/null; then
        echo -e "${GREEN}服务重启成功。${PLAIN}"
    else
        echo -e "${RED}服务重启失败，请检查配置文件格式！${PLAIN}"
        echo -e "配置文件路径: $CONFIG_FILE"
    fi
}

# ==========================================
# 2. 核心功能：WARP 账号获取与计算
# ==========================================

# 纯 Shell 实现 Base64 转 Sing-box Reserved 数组
# 输入: Base64 字符串 (例如 c+kIBA==)
# 输出: [115,233,8]
base64_to_reserved_shell() {
    local input="$1"
    # 使用 base64 解码 -> od 转十进制 -> tr 格式化 -> sed 构建数组
    local decoded_nums=$(echo "$input" | base64 -d 2>/dev/null | od -An -t u1 | tr -s ' ' ',')
    # 清理前后逗号和空格
    decoded_nums=$(echo "$decoded_nums" | sed 's/^,//;s/,$//;s/ //g')
    
    if [[ -z "$decoded_nums" ]]; then
        echo "[]"
    else
        echo "[$decoded_nums]"
    fi
}

# 注册/生成 WARP 账号 (需要 Python)
register_warp() {
    # 仅在此处检查 Python
    ensure_python || return 1

    echo -e "${YELLOW}正在连接 Cloudflare API 注册免费账号...${PLAIN}"
    
    # 尝试安装 wg-tools 生成 Key (如果不存在)
    if ! command -v wg &> /dev/null; then
        echo -e "${YELLOW}安装 wireguard-tools 用于生成密钥...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then apt install -y wireguard-tools; fi
        if [ -x "$(command -v yum)" ]; then yum install -y wireguard-tools; fi
    fi

    if ! command -v wg &> /dev/null; then
        echo -e "${RED}无法安装 wireguard-tools，无法自动生成密钥。${PLAIN}"
        return 1
    fi

    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local peer_pub=$(echo "$result" | jq -r '.config.peers[0].public_key')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    
    if [[ "$v4" == "null" || -z "$v4" ]]; then
        echo -e "${RED}注册失败，API 未返回有效 IP。请重试。${PLAIN}"
        return 1
    fi
    
    # 使用 Python 计算 Reserved (取 client_id 解码后的前3字节)
    local reserved_json=$(python3 -c "import base64, json; decoded = base64.b64decode('$client_id'); print(json.dumps([x for x in decoded[0:3]]))" 2>/dev/null)
    
    echo -e "${GREEN}注册成功!${PLAIN}"
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

# 手动录入账号 (无需 Python，纯 Shell 尝试解码)
manual_warp() {
    echo -e "===================================================="
    echo -e "请准备好你的 WARP 账号信息 (WireGuard 格式)"
    echo -e "===================================================="
    
    read -p "私钥 (Private Key): " priv_key
    read -p "公钥 (Peer Public Key, 留空默认为官方Key): " peer_pub
    if [[ -z "$peer_pub" ]]; then
        peer_pub="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    fi
    
    read -p "本机 IPv4 (如 172.16.0.2/32, 留空不填): " v4
    read -p "本机 IPv6 (如 2606:4700:..., 留空不填): " v6
    
    echo -e "Reserved 值 (非常重要!)"
    echo -e " - 格式 A (Base64): c+kIBA=="
    echo -e " - 格式 B (CSV): 115,233,8"
    read -p "请输入 Reserved: " res_input
    
    local reserved_json="[]"
    
    if [[ "$res_input" == *","* ]]; then
        # CSV 直接转 JSON 数组
        reserved_json="[$res_input]"
    else
        # 尝试使用纯 Shell (od) 解码 Base64，避免下载 Python
        reserved_json=$(base64_to_reserved_shell "$res_input")
        
        # 如果纯 Shell 解码失败 (例如系统没有 od)，则回退提示安装 Python
        if [[ "$reserved_json" == "[]" || "$reserved_json" == "null" ]]; then
             echo -e "${YELLOW}Shell 解码失败，尝试使用 Python 解码...${PLAIN}"
             ensure_python
             if command -v python3 &> /dev/null; then
                reserved_json=$(python3 -c "import base64, json; decoded = base64.b64decode('$res_input'); print(json.dumps([x for x in decoded]))" 2>/dev/null)
             else
                echo -e "${RED}无法解析 Reserved 值，请使用 CSV 格式 (如 1,2,3) 重试。${PLAIN}"
                return
             fi
        fi
    fi
    
    echo -e "解析到的 Reserved: ${GREEN}$reserved_json${PLAIN}"
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

# 写入配置文件 (Config.json)
write_warp_config() {
    local priv="$1"
    local pub="$2"
    local v4="$3"
    local v6="$4"
    local res="$5"
    
    local addr_json="[]"
    if [[ -n "$v4" && "$v4" != "null" ]]; then
        addr_json=$(echo "$addr_json" | jq --arg ip "$v4" '. + [$ip]')
    fi
    if [[ -n "$v6" && "$v6" != "null" ]]; then
        addr_json=$(echo "$addr_json" | jq --arg ip "$v6" '. + [$ip]')
    fi
    
    # 构建 Outbound JSON
    local warp_json=$(jq -n \
        --arg priv "$priv" \
        --arg pub "$pub" \
        --argjson addr "$addr_json" \
        --argjson res "$res" \
        '{
            "type": "wireguard",
            "tag": "WARP",
            "server": "engage.cloudflareclient.com",
            "server_port": 2408,
            "local_address": $addr,
            "private_key": $priv,
            "peers": [
                {
                    "server": "engage.cloudflareclient.com",
                    "server_port": 2408,
                    "public_key": $pub,
                    "reserved": $res
                }
            ]
        }')

    echo -e "${YELLOW}正在写入配置文件...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    # 1. 删除旧 WARP
    tmp=$(jq 'del(.outbounds[] | select(.tag == "WARP"))' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    # 2. 添加新 WARP
    tmp=$(jq --argjson new "$warp_json" '.outbounds += [$new]' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    echo -e "${GREEN}WARP 节点已写入配置。${PLAIN}"
    restart_sb
}

# ==========================================
# 3. 路由规则管理
# ==========================================

add_rule() {
    local name="$1"     # 显示名称
    local domains="$2"  # 域名列表字符串 "a.com b.com"
    local geosite="$3"  # Geosite Tag "netflix"
    
    echo -e "------------------------------------------------"
    echo -e "正在添加规则: ${SKYBLUE}$name${PLAIN} -> WARP"
    echo -e "------------------------------------------------"
    echo -e "请选择规则匹配模式:"
    echo -e "  1. ${GREEN}域名列表 (Domain List)${PLAIN} - [推荐] 稳定，不依赖 Geosite 文件"
    echo -e "  2. ${YELLOW}Geosite 规则集${PLAIN}       - 需确保本地有 geosite.db 或 rule_set"
    read -p "请选择 (1/2): " mode
    
    local new_rule=""
    
    if [[ "$mode" == "2" ]]; then
        # Geosite 模式
        new_rule=$(jq -n --arg g "$geosite" '{ "geosite": [$g], "outbound": "WARP" }')
    else
        # Domain List 模式
        new_rule=$(jq -n --arg d "$domains" '{ "domain_suffix": ($d | split(" ")), "outbound": "WARP" }')
    fi
    
    echo -e "${YELLOW}正在应用规则...${PLAIN}"
    local tmp=$(jq --argjson r "$new_rule" '.route.rules = [$r] + .route.rules' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    echo -e "${GREEN}规则添加成功。${PLAIN}"
    restart_sb
}

# 全局接管
set_global() {
    local type="$1" # v4, v6, dual
    local rule=""
    case "$type" in
        v4) rule=$(jq -n '{ "ip_version": 4, "outbound": "WARP" }') ;;
        v6) rule=$(jq -n '{ "ip_version": 6, "outbound": "WARP" }') ;;
        dual) rule=$(jq -n '{ "network": ["tcp","udp"], "outbound": "WARP" }') ;;
    esac
    
    local tmp=$(jq --argjson r "$rule" '.route.rules = [$r] + .route.rules' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    echo -e "${GREEN}全局规则已应用。${PLAIN}"
    restart_sb
}

# 移除 WARP 相关
uninstall_warp() {
    echo -e "${YELLOW}正在清理 WARP 配置与路由规则...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_uninstall"
    
    local tmp=$(jq 'del(.outbounds[] | select(.tag == "WARP"))' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    tmp=$(jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    echo -e "${GREEN}清理完成。已自动重启服务。${PLAIN}"
    restart_sb
}

# ==========================================
# 4. 菜单界面
# ==========================================

check_status() {
    if jq -e '.outbounds[] | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null; then
        echo -e "当前状态: ${GREEN}已配置 Native WARP${PLAIN}"
    else
        echo -e "当前状态: ${RED}未配置${PLAIN}"
    fi
}

menu() {
    check_dependencies
    clear
    echo -e "===================================================="
    echo -e "   Sing-box Native WARP 托管脚本 (v3.9.1)"
    echo -e "   配置文件: ${SKYBLUE}$CONFIG_FILE${PLAIN}"
    echo -e "===================================================="
    check_status
    echo -e "----------------------------------------------------"
    echo -e "  1. ${GREEN}配置/重置 WARP 账号${PLAIN} (自动注册 / 手动录入)"
    echo -e "  2. ${GREEN}添加分流规则${PLAIN} (Netflix/OpenAI/Disney+)"
    echo -e "  3. ${GREEN}全局流量接管${PLAIN} (IPv4 / IPv6 / 双栈)"
    echo -e "  4. ${RED}卸载/移除 WARP${PLAIN}"
    echo -e "  0. 退出脚本"
    echo -e "----------------------------------------------------"
    read -p " 请选择: " choice
    
    case $choice in
        1)
            echo -e "  1. 自动注册 (免费账号, 需下载 Python)"
            echo -e "  2. 手动录入 (支持 Teams, 纯 Shell 模式)"
            read -p "  请选择: " reg_type
            if [[ "$reg_type" == "1" ]]; then register_warp; 
            elif [[ "$reg_type" == "2" ]]; then manual_warp; 
            else echo -e "${RED}无效选择${PLAIN}"; fi
            ;;
        2)
            echo -e "  a. 解锁 ChatGPT/OpenAI"
            echo -e "  b. 解锁 Netflix"
            echo -e "  c. 解锁 Disney+"
            echo -e "  d. 解锁 Telegram"
            echo -e "  e. 解锁 Google"
            read -p "  请选择目标: " rule_target
            case "$rule_target" in
                a) add_rule "OpenAI" "openai.com ai.com chatgpt.com" "openai" ;;
                b) add_rule "Netflix" "netflix.com nflxvideo.net nflxext.com nflxso.net" "netflix" ;;
                c) add_rule "Disney+" "disney.com disneyplus.com bamgrid.com" "disney" ;;
                d) add_rule "Telegram" "telegram.org t.me" "telegram" ;;
                e) add_rule "Google" "google.com googleapis.com gvt1.com youtube.com" "google" ;;
                *) echo -e "${RED}无效选择${PLAIN}" ;;
            esac
            ;;
        3)
            echo -e "  a. 仅接管 IPv4 流量"
            echo -e "  b. 仅接管 IPv6 流量"
            echo -e "  c. 双栈全局接管 (所有流量)"
            read -p "  请选择: " glob_type
            case "$glob_type" in
                a) set_global "v4" ;;
                b) set_global "v6" ;;
                c) set_global "dual" ;;
            esac
            ;;
        4) uninstall_warp ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${PLAIN}" ;;
    esac
    
    echo -e ""
    read -p "按回车键返回菜单..." 
    menu
}

menu
