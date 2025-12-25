#!/bin/bash

# ============================================================
#  Xray WARP Native Route 管理面板 (v3.0 Ultimate-Menu)
#  - 架构: 管理面板 (Menu) + 模块化功能
#  - 对齐: 1:1 复刻 Sing-box 版本的交互体验与功能逻辑
#  - 特性: 状态自检、独立注册、模式热切换、卸载清理
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
# 1. 核心功能函数
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
    
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    if [[ "$v6" == "null" || -z "$v6" ]]; then echo -e "${RED}注册失败。${PLAIN}"; return 1; fi
    
    local res_str=$(python3 -c "import base64, json; d=base64.b64decode('$client_id'); print(','.join([str(x) for x in d[0:3]]))" 2>/dev/null)
    
    mkdir -p "$(dirname "$CRED_FILE")"
    echo "WARP_PRIV_KEY=\"$priv_key\"" > "$CRED_FILE"
    echo "WARP_IPV6=\"$v6/128\"" >> "$CRED_FILE"
    echo "WARP_RESERVED=\"$res_str\"" >> "$CRED_FILE"
    echo -e "${GREEN}注册成功！凭证已保存。${PLAIN}"
    
    # 注册完自动加载
    export WG_KEY="$priv_key" WG_ADDR="$v6/128" WG_RESERVED="$res_str"
}

manual_warp() {
    read -p "私钥: " k; read -p "IPv6地址: " a; read -p "Reserved: " r
    mkdir -p "$(dirname "$CRED_FILE")"
    echo "WARP_PRIV_KEY=\"$k\"" > "$CRED_FILE"
    echo "WARP_IPV6=\"$a\"" >> "$CRED_FILE"
    echo "WARP_RESERVED=\"$r\"" >> "$CRED_FILE"
    export WG_KEY="$k" WG_ADDR="$a" WG_RESERVED="$r"
    echo -e "${GREEN}凭证已手动录入。${PLAIN}"
}

load_credentials() {
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE"
        export WG_KEY="$WARP_PRIV_KEY" WG_ADDR="$WARP_IPV6" WG_RESERVED="$WARP_RESERVED"
        return 0
    elif [[ -n "$WARP_PRIV_KEY" ]]; then
        export WG_KEY="$WARP_PRIV_KEY" WG_ADDR="$WARP_IPV6" WG_RESERVED=$(echo "$WARP_RESERVED" | tr -d '[] ')
        return 0
    else
        return 1
    fi
}

# 核心注入函数：同时处理 Outbound 和 Routing
apply_config() {
    local mode="$1" # 1=Stream, 2=IPv4, 3=Specific, 4=Global
    
    if [[ ! -f "$CONFIG_FILE" ]]; then echo -e "${RED}错误: 找不到 config.json${PLAIN}"; return; fi
    if ! load_credentials; then echo -e "${RED}错误: 未找到凭证，请先配置账号(选项1)。${PLAIN}"; return; fi
    
    check_env
    echo -e "${YELLOW}正在应用配置 (模式: $mode)...${PLAIN}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"

    # 1. 清理旧 WARP
    jq '.outbounds |= map(select(.tag != "warp-out")) | .routing.rules |= map(select(.outboundTag != "warp-out"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 2. 注入 Outbound
    local res_json="[${WG_RESERVED}]"
    jq --arg key "$WG_KEY" --arg addr "$WG_ADDR" --argjson res "$res_json" --arg ep "$FINAL_ENDPOINT" \
       '.outbounds += [{ 
            "tag": "warp-out", 
            "protocol": "wireguard", 
            "settings": { "secretKey": $key, "address": [$addr], "peers": [{ "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": $ep, "keepAlive": 15 }], "reserved": $res, "mtu": 1280 } 
       }]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 3. 生成规则
    local anti_loop_ips="[]"
    [[ -n "$FINAL_ENDPOINT_IP" ]] && anti_loop_ips="[\"${FINAL_ENDPOINT_IP}\"]"
    local anti_loop=$(jq -n --argjson i "$anti_loop_ips" '{ "type": "field", "domain": ["engage.cloudflareclient.com", "cloudflare.com"], "ip": $i, "outboundTag": "direct" }')

    local rule=""
    case "$mode" in
        2) rule='{ "type": "field", "network": "tcp,udp", "ip": ["0.0.0.0/0"], "outboundTag": "warp-out" }' ;;
        3) 
            if [[ -z "$WARP_INBOUND_TAGS" ]]; then
                echo -e "${YELLOW}当前 Tags:${PLAIN}"; jq -r '.inbounds[].tag' "$CONFIG_FILE" | grep -v "api" | nl
                read -p "输入要接管的 Tag (逗号分隔): " WARP_INBOUND_TAGS
            fi
            local tag_json=$(echo "$WARP_INBOUND_TAGS" | jq -R 'split(",")')
            rule=$(jq -n --argjson t "$tag_json" '{ "type": "field", "inboundTag": $t, "outboundTag": "warp-out" }') ;;
        4) rule='{ "type": "field", "network": "tcp,udp", "outboundTag": "warp-out" }' ;;
        *) rule='{ "type": "field", "domain": ["geosite:netflix","geosite:disney","geosite:openai","geosite:google","geosite:youtube"], "outboundTag": "warp-out" }' ;;
    esac

    if [[ -n "$rule" ]]; then
         jq --argjson r1 "$anti_loop" --argjson r2 "$rule" '.routing.rules = [$r1, $r2] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
         jq --argjson r1 "$anti_loop" '.routing.rules = [$r1] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi

    # 重启
    if systemctl restart xray; then
        echo -e "${GREEN}设置成功！Xray 已重启。${PLAIN}"
    else
        echo -e "${RED}重启失败，还原配置...${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart xray
    fi
}

uninstall_warp() {
    echo -e "${YELLOW}正在卸载 WARP 配置...${PLAIN}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    jq '.outbounds |= map(select(.tag != "warp-out")) | .routing.rules |= map(select(.outboundTag != "warp-out"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    systemctl restart xray
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# ============================================================
# 2. 菜单界面 (复刻 Sing-box 风格)
# ============================================================

show_menu() {
    check_dependencies
    while true; do
        clear
        # 状态自检
        local st="${RED}未配置${PLAIN}"
        if [[ -f "$CONFIG_FILE" ]]; then
            if jq -e '.outbounds[]? | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
                st="${GREEN}已配置 (v3.0 Menu)${PLAIN}"
            fi
        fi

        echo -e "================ Xray Native WARP 管理面板 ================"
        echo -e " 当前状态: [$st]"
        echo -e "----------------------------------------------------"
        echo -e " 1. 配置 WARP 凭证 (自动/手动)"
        echo -e " 2. 查看当前凭证信息"
        echo -e " -----------------"
        echo -e " 3. 模式一：流媒体分流 (推荐)"
        echo -e " 4. 模式二：IPv4 流量接管"
        echo -e " 5. 模式三：指定节点接管"
        echo -e " 6. 模式四：全局双栈接管"
        echo -e " -----------------"
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
                    echo -e "PrivKey: $WG_KEY"; echo -e "IPv6: $WG_ADDR"; echo -e "Reserved: $WG_RESERVED"
                else
                    echo -e "${RED}未找到凭证。${PLAIN}"
                fi
                read -p "按回车继续..." 
                ;;
            3) apply_config 1; read -p "按回车继续..." ;;
            4) apply_config 2; read -p "按回车继续..." ;;
            5) unset WARP_INBOUND_TAGS; apply_config 3; read -p "按回车继续..." ;;
            6) apply_config 4; read -p "按回车继续..." ;;
            7) uninstall_warp; read -p "按回车继续..." ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 3. 入口逻辑
# ============================================================

auto_main() {
    echo -e "${GREEN}>>> [Auto] 正在应用 WARP 配置...${PLAIN}"
    # 自动模式下，依赖环境变量
    if [[ -z "$WARP_PRIV_KEY" ]]; then register_warp; fi
    # 映射自动模式变量到函数参数
    local m="1"
    [[ "$WARP_MODE_SELECT" == "2" ]] && m="2"
    [[ "$WARP_MODE_SELECT" == "3" ]] && m="3"
    [[ "$WARP_MODE_SELECT" == "4" ]] && m="4"
    apply_config "$m"
}

if [[ "$AUTO_SETUP" == "true" ]]; then
    check_dependencies
    auto_main
else
    show_menu
fi
