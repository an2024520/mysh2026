#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# Sing-box 配置文件路径，根据实际情况修改
CONFIG_FILE="/etc/sing-box/config.json"

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq 未安装，请先安装 jq (apt install jq / yum install jq)${PLAIN}"
    exit 1
fi

# 检查 WARP 是否已安装
check_warp_status() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件 $CONFIG_FILE 不存在!${PLAIN}"
        return 1
    fi
    # 检查 outbounds 中是否有 tag 为 WARP 的项
    is_installed=$(jq '.outbounds[] | select(.tag == "WARP")' "$CONFIG_FILE")
    if [[ -n "$is_installed" ]]; then
        return 0 # 已安装
    else
        return 1 # 未安装
    fi
}

# 注册 WARP 账号并获取配置
register_warp() {
    echo -e "${YELLOW}正在注册免费 WARP 账号...${PLAIN}"
    
    # 尝试安装 wg-tools 生成密钥，如果不想依赖 wg，可以使用 sing-box generate (需要新版 core)
    if ! command -v wg &> /dev/null; then
        echo -e "${YELLOW}正在安装 wireguard-tools 用于生成密钥...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y wireguard-tools
        elif [ -x "$(command -v yum)" ]; then
            yum install -y wireguard-tools
        fi
    fi

    if ! command -v wg &> /dev/null; then
        echo -e "${RED}无法安装 wireguard-tools，无法自动生成密钥。${PLAIN}"
        return 1
    fi

    # 生成密钥
    priv_key=$(wg genkey)
    pub_key=$(echo "$priv_key" | wg pubkey)

    # 注册账号
    install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    response=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")

    # 提取信息 (IPv6 reserved 字段较复杂，这里使用简化版直接连接，通常够用)
    # 获取被分配的 IP (V4/V6)
    v4=$(echo "$response" | jq -r '.config.interface.addresses.v4')
    v6=$(echo "$response" | jq -r '.config.interface.addresses.v6')
    peer_pub=$(echo "$response" | jq -r '.config.peers[0].public_key')
    peer_endpoint=$(echo "$response" | jq -r '.config.peers[0].endpoint.host')
    client_id=$(echo "$response" | jq -r '.config.client_id')
    
    # 构建 WARP Outbound JSON
    # 注意: Cloudflare 官方 Endpoint 通常是 engage.cloudflareclient.com:2408
    # 这里的 local_address 使用注册回来的 IP
    
    warp_json=$(jq -n \
        --arg priv "$priv_key" \
        --arg peer_pub "$peer_pub" \
        --arg v4 "$v4" \
        --arg v6 "$v6" \
        '{
            "type": "wireguard",
            "tag": "WARP",
            "server": "engage.cloudflareclient.com",
            "server_port": 2408,
            "local_address": [$v4, $v6],
            "private_key": $priv,
            "peers": [
                {
                    "server": "engage.cloudflareclient.com",
                    "server_port": 2408,
                    "public_key": $peer_pub
                }
            ]
        }')
        
    # 写入 config.json
    # 1. 先检查是否已有 WARP，有则先删
    tmp_config=$(jq 'del(.outbounds[] | select(.tag == "WARP"))' "$CONFIG_FILE")
    echo "$tmp_config" > "$CONFIG_FILE"
    
    # 2. 添加新的 WARP outbound
    tmp_config=$(jq --argjson new_outbound "$warp_json" '.outbounds += [$new_outbound]' "$CONFIG_FILE")
    echo "$tmp_config" > "$CONFIG_FILE"
    
    echo -e "${GREEN}WARP 账号注册并添加成功!${PLAIN}"
    restart_singbox
}

# 卸载 WARP
uninstall_warp() {
    echo -e "${YELLOW}正在移除 WARP 配置...${PLAIN}"
    # 移除 outbound
    tmp_config=$(jq 'del(.outbounds[] | select(.tag == "WARP"))' "$CONFIG_FILE")
    echo "$tmp_config" > "$CONFIG_FILE"
    
    # 移除所有指向 WARP 的路由规则
    tmp_config=$(jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE")
    echo "$tmp_config" > "$CONFIG_FILE"
    
    echo -e "${GREEN}WARP 已移除。${PLAIN}"
    restart_singbox
}

# 添加路由规则
# add_rule "geosite" "netflix" "WARP"
add_rule() {
    local type=$1
    local value=$2
    local outbound=$3
    
    echo -e "${YELLOW}正在添加规则: $type:$value -> $outbound ...${PLAIN}"
    
    # 构造规则 JSON
    # 这里演示最基础的 rule_set 或 domain/geosite 规则
    # 假设使用 geosite tag 匹配 (Sing-box 1.8+ 推荐用法)
    
    if [[ "$type" == "geosite" ]]; then
        # 检查是否已存在该 geosite 的 rule_set 定义，如果不存在可能需要添加 remote rule_set
        # 这里简化处理，直接添加 rule
        new_rule=$(jq -n --arg val "$value" --arg out "$outbound" '{ "geosite": [$val], "outbound": $out }')
    elif [[ "$type" == "domain_suffix" ]]; then
        new_rule=$(jq -n --arg val "$value" --arg out "$outbound" '{ "domain_suffix": [$val], "outbound": $out }')
    elif [[ "$type" == "ip" ]]; then
        if [[ "$value" == "4" ]]; then
             new_rule=$(jq -n --arg out "$outbound" '{ "ip_version": 4, "outbound": $out }')
        elif [[ "$value" == "6" ]]; then
             new_rule=$(jq -n --arg out "$outbound" '{ "ip_version": 6, "outbound": $out }')
        fi
    fi
    
    # 插入到 route.rules 的最前面(优先级最高)
    tmp_config=$(jq --argjson rule "$new_rule" '.route.rules = [$rule] + .route.rules' "$CONFIG_FILE")
    echo "$tmp_config" > "$CONFIG_FILE"
    
    echo -e "${GREEN}规则添加成功。${PLAIN}"
    restart_singbox
}

# 重启 Sing-box
restart_singbox() {
    echo -e "${YELLOW}重启 Sing-box 服务...${PLAIN}"
    systemctl restart sing-box
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}Sing-box 重启成功。${PLAIN}"
    else
        echo -e "${RED}Sing-box 重启失败，请检查配置!${PLAIN}"
    fi
}

# 二级菜单：Native WARP 管理
menu() {
    clear
    echo -e "----------------------------------------------------------------"
    echo -e "${GREEN}Sing-box Native WARP 管理${PLAIN}"
    echo -e "----------------------------------------------------------------"
    
    if check_warp_status; then
        echo -e "当前状态: ${GREEN}已安装 WARP${PLAIN}"
    else
        echo -e "当前状态: ${RED}未安装 WARP${PLAIN}"
    fi
    
    echo -e "----------------------------------------------------------------"
    echo -e "  ${GREEN}1.${PLAIN} 安装/重置 WARP (自动注册账号)"
    echo -e "  ${GREEN}2.${PLAIN} 卸载 WARP"
    echo -e "----------------------------------------------------------------"
    echo -e "  ${GREEN}3.${PLAIN} 解锁 Netflix (分流 -> WARP)"
    echo -e "  ${GREEN}4.${PLAIN} 解锁 ChatGPT/OpenAI (分流 -> WARP)"
    echo -e "  ${GREEN}5.${PLAIN} 解锁 Disney+ (分流 -> WARP)"
    echo -e "  ${GREEN}6.${PLAIN} 优先 IPv4 (IPv4 -> WARP)"
    echo -e "  ${GREEN}7.${PLAIN} 优先 IPv6 (IPv6 -> WARP)"
    echo -e "----------------------------------------------------------------"
    echo -e "  ${GREEN}0.${PLAIN} 返回上级菜单"
    echo -e "----------------------------------------------------------------"
    
    read -p " 请选择: " choice
    
    case $choice in
        1) register_warp ;;
        2) uninstall_warp ;;
        3) 
            check_warp_status && add_rule "geosite" "netflix" "WARP" || echo -e "${RED}请先安装 WARP!${PLAIN}"
            ;;
        4)
            check_warp_status && add_rule "geosite" "openai" "WARP" || echo -e "${RED}请先安装 WARP!${PLAIN}"
            ;;
        5)
            check_warp_status && add_rule "geosite" "disney" "WARP" || echo -e "${RED}请先安装 WARP!${PLAIN}"
            ;;
        6)
            check_warp_status && add_rule "ip" "4" "WARP" || echo -e "${RED}请先安装 WARP!${PLAIN}"
            ;;
        7)
            check_warp_status && add_rule "ip" "6" "WARP" || echo -e "${RED}请先安装 WARP!${PLAIN}"
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${PLAIN}" ;;
    esac
    
    echo -e ""
    read -p "按回车键继续..."
    menu
}

menu
