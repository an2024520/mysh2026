#!/bin/bash

# ============================================================
#  Xray WARP Native Route 模块 (v2.6 Ultimate-Fix)
#  - 架构: Xray WireGuard Outbound
#  - 修复: 增加独立账号注册能力，解除对 auto_deploy 的强依赖
#  - 增强: 动态搜索 config.json，防止未安装核心时脚本崩溃
#  - 适配: 自动识别 IPv6-Only 环境并切换 Endpoint
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
# 0. 环境初始化与依赖检查
# ============================================================

# 动态搜索配置文件
CONFIG_FILE=""
PATHS=("/usr/local/etc/xray/config.json" "/etc/xray/config.json" "$HOME/xray/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

BACKUP_FILE="${CONFIG_FILE}.bak"
CRED_FILE="/etc/xray/warp_credentials.conf"

check_dependencies() {
    local need_install=false
    if ! command -v jq &> /dev/null; then echo -e "${YELLOW}安装依赖: jq${PLAIN}"; need_install=true; fi
    if ! command -v curl &> /dev/null; then echo -e "${YELLOW}安装依赖: curl${PLAIN}"; need_install=true; fi
    if ! command -v python3 &> /dev/null; then echo -e "${YELLOW}安装依赖: python3${PLAIN}"; need_install=true; fi
    
    if [[ "$need_install" == "true" ]]; then
        apt-get update >/dev/null 2>&1
        apt-get install -y jq curl python3 wireguard-tools >/dev/null 2>&1 || yum install -y jq curl python3 wireguard-tools >/dev/null 2>&1
    fi
}

ensure_config_exists() {
    if [[ -z "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 未检测到 Xray 配置文件 (config.json)！${PLAIN}"
        echo -e "${GRAY}请先在菜单中安装 Xray 核心 (Install Core)。${PLAIN}"
        exit 1
    fi
    # 备份
    cp "$CONFIG_FILE" "$BACKUP_FILE"
}

# ============================================================
# 1. 环境自适应检测 (严格模式)
# ============================================================
check_env() {
    echo -e "${YELLOW}正在检测网络环境以适配 Endpoint...${PLAIN}"
    
    IS_IPV6_ONLY=false
    FINAL_ENDPOINT="engage.cloudflareclient.com:2408" 
    FINAL_ENDPOINT_IP=""

    local ipv4_check=$(curl -4 -s -m 5 http://ip.sb 2>/dev/null)
    
    if [[ "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${GREEN}>>> 检测到有效 IPv4 环境。${PLAIN}"
    else
        IS_IPV6_ONLY=true
        local ep_ip="2606:4700:d0::a29f:c001"
        FINAL_ENDPOINT="[${ep_ip}]:2408"
        FINAL_ENDPOINT_IP="${ep_ip}"
        echo -e "${SKYBLUE}>>> 检测到 IPv6-Only 环境，切换专用 Endpoint。${PLAIN}"
    fi
    export FINAL_ENDPOINT
    export FINAL_ENDPOINT_IP
}

# ============================================================
# 2. 账号注册与获取 (核心修复点)
# ============================================================

save_credentials() {
    mkdir -p "$(dirname "$CRED_FILE")"
    cat > "$CRED_FILE" <<EOF
WARP_PRIV_KEY="$1"
WARP_IPV6="$2"
WARP_RESERVED="$3"
EOF
}

register_warp() {
    echo -e "${YELLOW}正在连接 Cloudflare API 注册新账号...${PLAIN}"
    
    # 生成密钥对
    if ! command -v wg &> /dev/null; then apt-get install -y wireguard-tools || yum install -y wireguard-tools; fi
    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    
    # 注册请求
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    
    if [[ "$v6" == "null" || -z "$v6" ]]; then 
        echo -e "${RED}注册失败，无法获取 IPv6 地址，请重试。${PLAIN}"
        exit 1
    fi
    
    # 转换 Reserved
    local res_json=$(python3 -c "import base64, json; d=base64.b64decode('$client_id'); print(json.dumps([x for x in d[0:3]]))" 2>/dev/null)
    # Xray 需要逗号分隔的字符串，例如 123,45,67
    local res_str=$(echo "$res_json" | tr -d '[] ')

    echo -e "${GREEN}注册成功！${PLAIN}"
    export WG_KEY="$priv_key"
    export WG_ADDR="$v6/128"
    export WG_RESERVED="$res_str"
    
    save_credentials "$priv_key" "$v6/128" "$res_str"
}

get_warp_account() {
    echo -e "----------------------------------------------------"
    echo -e "${SKYBLUE}配置 WARP 账号参数${PLAIN}"
    
    # 1. 尝试从环境变量获取 (Auto Mode)
    if [[ -n "$WARP_PRIV_KEY" ]]; then
        export WG_KEY="$WARP_PRIV_KEY"
        export WG_ADDR="$WARP_IPV6"
        export WG_RESERVED=$(echo "$WARP_RESERVED" | tr -d '[] ')
        return
    fi

    # 2. 尝试从本地凭证获取
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE"
        echo -e "${GREEN}检测到本地已保存的凭证。${PLAIN}"
        export WG_KEY="$WARP_PRIV_KEY"
        export WG_ADDR="$WARP_IPV6"
        export WG_RESERVED="$WARP_RESERVED"
        return
    fi

    # 3. 手动模式交互
    echo -e " 1. 自动注册免费账号 (推荐)"
    echo -e " 2. 手动输入账号信息"
    read -p "请选择 [1/2]: " choice

    if [[ "$choice" == "2" ]]; then
        read -p "私钥 (Private Key): " p_key
        read -p "地址 (IPv6 Address, e.g. 2606:xxxx...): " addr
        read -p "保留字段 (Reserved, e.g. 123,45,67): " reserved
        export WG_KEY="$p_key"
        export WG_ADDR="$addr"
        export WG_RESERVED=$(echo "$reserved" | tr -d '[] ')
    else
        register_warp
    fi

    if [[ -z "$WG_KEY" || -z "$WG_ADDR" ]]; then
        echo -e "${RED}错误: WARP 账号信息缺失！${PLAIN}"
        exit 1
    fi
}

# ============================================================
# 3. 注入配置 (核心逻辑)
# ============================================================
inject_config() {
    ensure_config_exists
    echo -e "${YELLOW}正在注入 WARP 出站配置...${PLAIN}"
    
    # 1. 清理旧配置
    jq '
      .outbounds |= map(select(.tag != "warp-out")) |
      .routing.rules |= map(select(.outboundTag != "warp-out"))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 2. 注入 Outbound
    local res_json="[$(echo $WG_RESERVED | sed 's/,/,/g')]"
    
    jq --arg key "$WG_KEY" \
       --arg addr "$WG_ADDR" \
       --argjson res "$res_json" \
       --arg endpoint "$FINAL_ENDPOINT" \
       '.outbounds += [{
            "tag": "warp-out",
            "protocol": "wireguard",
            "settings": {
                "secretKey": $key,
                "address": [$addr],
                "peers": [{
                    "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                    "endpoint": $endpoint,
                    "keepAlive": 15
                }],
                "reserved": $res,
                "mtu": 1280
            }
       }]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 3. 注入路由规则
    echo -e "${YELLOW}正在配置路由规则 (Anti-Loop & Routing)...${PLAIN}"
    
    # 3.1 构造防环回规则
    local anti_loop_domains='["engage.cloudflareclient.com", "cloudflare.com"]'
    local anti_loop_ips="[]"
    if [[ -n "$FINAL_ENDPOINT_IP" ]]; then
        anti_loop_ips="[\"${FINAL_ENDPOINT_IP}\"]"
    fi
    
    local anti_loop_rule=$(jq -n \
        --argjson d "$anti_loop_domains" \
        --argjson i "$anti_loop_ips" \
        '{ "type": "field", "domain": $d, "ip": $i, "outboundTag": "direct" }')
    
    # 3.2 构造分流规则
    local tags="${WARP_INBOUND_TAGS}"
    local routing_rule=""
    
    if [[ -n "$tags" ]]; then
        echo -e "${GREEN}>>> 模式: 指定节点接管 (Tags: $tags)${PLAIN}"
        local tag_json="[$(echo "$tags" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')]"
        routing_rule=$(jq -n --argjson tags "$tag_json" \
           '{ "type": "field", "inboundTag": $tags, "outboundTag": "warp-out" }')
    elif [[ "$WARP_MODE_SELECT" == "4" ]]; then
         echo -e "${GREEN}>>> 模式: 全局接管 (Catch-All)${PLAIN}"
         routing_rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "outboundTag": "warp-out" }')
    else
         echo -e "${YELLOW}警告: 未指定接管标签，仅注入防环回规则。${PLAIN}"
    fi

    # 3.3 执行注入 (Prepend)
    if [[ -n "$routing_rule" ]]; then
        jq --argjson r1 "$anti_loop_rule" \
           --argjson r2 "$routing_rule" \
           '.routing.rules = [$r1, $r2] + .routing.rules' \
           "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
        jq --argjson r1 "$anti_loop_rule" \
           '.routing.rules = [$r1] + .routing.rules' \
           "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi
}

# ============================================================
# 4. 重启验证
# ============================================================
restart_xray() {
    if ! jq . "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}JSON 语法错误，还原备份...${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        exit 1
    fi

    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}WARP 模块加载成功！Endpoint: $FINAL_ENDPOINT${PLAIN}"
        echo -e "${GRAY}防环回规则已置顶。${PLAIN}"
    else
        echo -e "${RED}Xray 重启失败，正在还原配置...${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart xray
        exit 1
    fi
}

# 执行流程
check_dependencies
check_env
get_warp_account
inject_config
restart_xray
