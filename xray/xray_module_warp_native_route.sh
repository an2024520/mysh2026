#!/bin/bash

# ============================================================
#  Xray WARP Native Route 管理面板 (v3.2 Ultimate-Final)
#  - 核心: 1:1 复刻 Sing-box 版本菜单逻辑与交互体验
#  - 修复: 解决纯 IPv6 环境下因缺失 IPv4 内网地址导致的断连问题
#  - 增强: 自动补全 WARP 内网 IPv4/IPv6 地址
#  - 逻辑: 严格遵循“配置即最终态”原则 (先清空后写入)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

# 检查 Root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ============================================================
# 0. 全局初始化
# ============================================================
CONFIG_FILE=""
PATHS=("/usr/local/etc/xray/config.json" "/etc/xray/config.json" "$HOME/xray/config.json")
for p in "${PATHS[@]}"; do [[ -f "$p" ]] && CONFIG_FILE="$p" && break; done

# 容错：如果是手动模式且找不到配置，允许进入菜单（但在操作时会报错）
if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="/usr/local/etc/xray/config.json" # 默认回落
fi

BACKUP_FILE="${CONFIG_FILE}.bak"
CRED_FILE="/etc/xray/warp_credentials.conf"

check_dependencies() {
    if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}安装必要依赖...${PLAIN}"
        apt-get update >/dev/null 2>&1
        apt-get install -y jq curl python3 wireguard-tools >/dev/null 2>&1 || yum install -y jq curl python3 wireguard-tools >/dev/null 2>&1
    fi
}

# ============================================================
# 1. 基础功能函数
# ============================================================

check_env() {
    FINAL_ENDPOINT="engage.cloudflareclient.com:2408"
    FINAL_ENDPOINT_IP=""
    local ipv4_check=$(curl -4 -s -m 5 http://ip.sb 2>/dev/null)
    if [[ ! "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local ep_ip="2606:4700:d0::a29f:c001"
        FINAL_ENDPOINT="[${ep_ip}]:2408"
        FINAL_ENDPOINT_IP="${ep_ip}"
    fi
    export FINAL_ENDPOINT FINAL_ENDPOINT_IP
}

register_warp() {
    echo -e "${YELLOW}正在连接 Cloudflare API 注册...${PLAIN}"
    if ! command -v wg &> /dev/null; then apt-get install -y wireguard-tools >/dev/null 2>&1; fi
    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    
    # [修复] 同时获取 v4 和 v6
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    
    if [[ "$v6" == "null" || -z "$v6" ]]; then echo -e "${RED}注册失败。${PLAIN}"; return 1; fi
    
    local res_str=$(python3 -c "import base64, json; d=base64.b64decode('$client_id'); print(','.join([str(x) for x in d[0:3]]))" 2>/dev/null)
    
    mkdir -p "$(dirname "$CRED_FILE")"
    echo "WARP_PRIV_KEY=\"$priv_key\"" > "$CRED_FILE"
    echo "WARP_IPV4=\"$v4/32\"" >> "$CRED_FILE"   # 保存 v4
    echo "WARP_IPV6=\"$v6/128\"" >> "$CRED_FILE"  # 保存 v6
    echo "WARP_RESERVED=\"$res_str\"" >> "$CRED_FILE"
    echo -e "${GREEN}注册成功！凭证已保存。${PLAIN}"
    
    # 注册完自动加载
    export WG_KEY="$priv_key" WG_IPV4="$v4/32" WG_IPV6="$v6/128" WG_RESERVED="$res_str"
}

manual_warp() {
    # [修复] 增加 IPv4 输入
    read -p "私钥: " k
    read -p "IPv4地址 (e.g. 172.16.0.2/32): " v4
    read -p "IPv6地址 (e.g. 2606:.../128): " v6
    read -p "Reserved: " r
    
    mkdir -p "$(dirname "$CRED_FILE")"
    echo "WARP_PRIV_KEY=\"$k\"" > "$CRED_FILE"
    echo "WARP_IPV4=\"$v4\"" >> "$CRED_FILE"
    echo "WARP_IPV6=\"$v6\"" >> "$CRED_FILE"
    echo "WARP_RESERVED=\"$r\"" >> "$CRED_FILE"
    
    export WG_KEY="$k" WG_IPV4="$v4" WG_IPV6="$v6" WG_RESERVED="$r"
    echo -e "${GREEN}凭证已手动录入。${PLAIN}"
}

load_credentials() {
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE"
        export WG_KEY="$WARP_PRIV_KEY" WG_IPV4="$WARP_IPV4" WG_IPV6="$WARP_IPV6" WG_RESERVED="$WARP_RESERVED"
        return 0
    elif [[ -n "$WARP_PRIV_KEY" ]]; then
        export WG_KEY="$WARP_PRIV_KEY" WG_IPV4="$WARP_IPV4" WG_IPV6="$WARP_IPV6" WG_RESERVED=$(echo "$WARP_RESERVED" | tr -d '[] ')
        return 0
    else
        return 1
    fi
}

ensure_warp_exists() {
    if [[ ! -f "$CONFIG_FILE" ]]; then echo -e "${RED}错误: 找不到 config.json${PLAIN}"; return 1; fi
    if ! load_credentials; then echo -e "${RED}错误: 未找到凭证，请先配置账号(选项1)。${PLAIN}"; return 1; fi
    check_env
    return 0
}

# ============================================================
# 2. 核心注入逻辑 (配置即最终态)
# ============================================================

apply_routing_rule() {
    local rule_json="$1"
    echo -e "${YELLOW}正在应用路由规则...${PLAIN}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"

    # [配置即最终态] 1. 彻底清理旧的 WARP Outbound 和 Rules
    jq '.outbounds |= map(select(.tag != "warp-out")) | .routing.rules |= map(select(.outboundTag != "warp-out"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 2. 重新注入 Outbound
    local res_json="[${WG_RESERVED}]"
    
    # [修复] 构造包含 v4 和 v6 的地址数组
    # 兼容性处理: 如果 v4 为空，则只填 v6 (防止旧凭证报错)
    local addr_json="[\"$WG_IPV6\"]"
    if [[ -n "$WG_IPV4" ]]; then
        addr_json="[\"$WG_IPV6\",\"$WG_IPV4\"]"
    fi
    
    jq --arg key "$WG_KEY" --argjson addr "$addr_json" --argjson res "$res_json" --arg ep "$FINAL_ENDPOINT" \
       '.outbounds += [{ 
            "tag": "warp-out", 
            "protocol": "wireguard", 
            "settings": { "secretKey": $key, "address": $addr, "peers": [{ "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": $ep, "keepAlive": 15 }], "reserved": $res, "mtu": 1280 } 
       }]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 3. 构造防环回规则
    # [修复] 自动检测直连 Tag (freedom/direct)
    local direct_tag="direct"
    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then
        if jq -e '.outbounds[] | select(.tag == "freedom")' "$CONFIG_FILE" >/dev/null 2>&1; then
            direct_tag="freedom"
        fi
    fi

    local anti_loop_ips="[]"
    [[ -n "$FINAL_ENDPOINT_IP" ]] && anti_loop_ips="[\"${FINAL_ENDPOINT_IP}\"]"
    local anti_loop=$(jq -n --argjson i "$anti_loop_ips" --arg tag "$direct_tag" '{ "type": "field", "domain": ["engage.cloudflareclient.com", "cloudflare.com"], "ip": $i, "outboundTag": $tag }')

    # 4. 组合新规则 (防环回 + 策略规则)
    if [[ -n "$rule_json" ]]; then
         jq --argjson r1 "$anti_loop" --argjson r2 "$rule_json" '.routing.rules = [$r1, $r2] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
         jq --argjson r1 "$anti_loop" '.routing.rules = [$r1] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi

    # 重启验证
    if systemctl restart xray; then
        echo -e "${GREEN}策略已更新，Xray 重启成功。${PLAIN}"
    else
        echo -e "${RED}Xray 重启失败，回滚配置...${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart xray
    fi
}

# ============================================================
# 3. 模式逻辑 (对齐 Sing-box)
# ============================================================

mode_stream() {
    ensure_warp_exists || return
    apply_routing_rule "$(jq -n '{ "type": "field", "domain": ["geosite:netflix","geosite:disney","geosite:openai","geosite:google","geosite:youtube"], "outboundTag": "warp-out" }')"
}

mode_global() {
    ensure_warp_exists || return
    echo -e " a. 仅 IPv4  b. 仅 IPv6  c. 双栈全接管"
    read -p "选择模式: " sub
    
    local warp_rule=""
    case "$sub" in
        a) warp_rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "ip": ["0.0.0.0/0"], "outboundTag": "warp-out" }') ;;
        b) warp_rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "ip": ["::/0"], "outboundTag": "warp-out" }') ;;
        *) warp_rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "outboundTag": "warp-out" }') ;;
    esac
    
    apply_routing_rule "$warp_rule"
    echo -e "${GREEN}全局接管策略已应用 (防环回已置顶)。${PLAIN}"
}

mode_specific_node() {
    ensure_warp_exists || return
    # 动态读取 Xray 配置文件中的入站 Tag
    echo -e "${YELLOW}正在读取节点列表...${PLAIN}"
    local node_list=$(jq -r '.inbounds[] | "\(.tag) | \(.protocol)"' "$CONFIG_FILE" | grep -v "api" | nl)
    
    if [[ -z "$node_list" ]]; then
        echo -e "${RED}未找到有效入站节点 (Inbounds)。${PLAIN}"
        return
    fi
    
    echo "$node_list"
    echo -e "${GRAY}(支持多选，用空格分隔，例如: 1 3)${PLAIN}"
    read -p "输入节点序号: " selection
    
    local tags_json="[]"
    for num in $selection; do
        local tag=$(echo "$node_list" | sed -n "${num}p" | awk -F'|' '{print $1}' | awk '{print $1}')
        [[ -n "$tag" ]] && tags_json=$(echo "$tags_json" | jq --arg t "$tag" '. + [$t]')
    done
    
    if [[ "$tags_json" == "[]" ]]; then
        echo -e "${YELLOW}未选择任何节点，取消操作。${PLAIN}"
        return
    fi
    
    echo -e "${GREEN}选中节点: $tags_json${PLAIN}"
    apply_routing_rule "$(jq -n --argjson ib "$tags_json" '{ "type": "field", "inboundTag": $ib, "outboundTag": "warp-out" }')"
}

uninstall_warp() {
    echo -e "${YELLOW}正在卸载 WARP 配置...${PLAIN}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    jq '.outbounds |= map(select(.tag != "warp-out")) | .routing.rules |= map(select(.outboundTag != "warp-out"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    systemctl restart xray
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# ============================================================
# 4. 菜单界面 (1:1 复刻)
# ============================================================

show_menu() {
    check_dependencies
    while true; do
        clear
        local st="${RED}未配置${PLAIN}"
        if [[ -f "$CONFIG_FILE" ]]; then
            if jq -e '.outbounds[]? | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
                st="${GREEN}已配置 (v3.2 Ultimate)${PLAIN}"
            fi
        fi

        echo -e "================ Xray Native WARP 管理面板 ================"
        echo -e " 当前状态: [$st]"
        echo -e "----------------------------------------------------"
        echo -e " 1. 配置 WARP 凭证 (自动/手动)"
        echo -e " 2. 查看当前凭证信息"
        echo -e " 3. 模式一：流媒体分流 (推荐)"
        echo -e " 4. 模式二：全局接管"
        echo -e " 5. 模式三：指定节点接管"
        echo -e " 7. 卸载/清除 WARP 配置"
        echo -e " 0. 返回上级菜单"
        echo ""
        read -p "请选择: " choice
        
        case "$choice" in
            1) 
                echo -e "1. 自动注册  2. 手动录入"
                read -p "选: " t
                [[ "$t" == "1" ]] && register_warp || manual_warp
                read -p "按回车继续..." 
                ;;
            2) 
                if load_credentials; then
                    echo -e "PrivKey: $WG_KEY"
                    echo -e "IPv4: $WG_IPV4"
                    echo -e "IPv6: $WG_ADDR"
                    echo -e "Reserved: $WG_RESERVED"
                else
                    echo -e "${RED}未找到凭证。${PLAIN}"
                fi
                read -p "按回车继续..." 
                ;;
            3) mode_stream; read -p "按回车继续..." ;;
            4) mode_global; read -p "按回车继续..." ;;
            5) mode_specific_node; read -p "按回车继续..." ;;
            7) uninstall_warp; read -p "按回车继续..." ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 5. 入口逻辑
# ============================================================

auto_main() {
    echo -e "${GREEN}>>> [Auto] 正在应用 WARP 配置...${PLAIN}"
    if [[ -z "$WARP_PRIV_KEY" ]]; then register_warp; fi
    ensure_warp_exists || exit 1
    
    # 自动模式参数映射
    local rule=""
    case "$WARP_MODE_SELECT" in
        2) # 自动模式的2对应全局IPv4 (默认策略)
           rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "ip": ["0.0.0.0/0"], "outboundTag": "warp-out" }') ;;
        3) # 指定Tag
           [[ -n "$WARP_INBOUND_TAGS" ]] && rule=$(jq -n --argjson t "$(echo "$WARP_INBOUND_TAGS" | jq -R 'split(",")')" '{ "type": "field", "inboundTag": $t, "outboundTag": "warp-out" }') ;;
        4) # 真正的全双栈
           rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "outboundTag": "warp-out" }') ;;
        *) # 默认流媒体
           rule=$(jq -n '{ "type": "field", "domain": ["geosite:netflix","geosite:disney","geosite:openai","geosite:google","geosite:youtube"], "outboundTag": "warp-out" }') ;;
    esac
    apply_routing_rule "$rule"
}

if [[ "$AUTO_SETUP" == "true" ]]; then
    check_dependencies
    auto_main
else
    show_menu
fi
