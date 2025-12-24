#!/bin/bash

# ============================================================
#  Xray WARP Native Route 模块 (v2.5 Ultimate-Xray)
#  - 架构: Xray WireGuard Outbound
#  - 修复: 路由插入顺序 (Prepend)、增加防环回 (Anti-Loop)
#  - 适配: 自动识别 IPv6-Only 环境并切换 Endpoint
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/usr/local/etc/xray/config.json.bak"

# 检查 Root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ============================================================
# 1. 环境自适应检测 (严格模式)
# ============================================================
check_env() {
    echo -e "${YELLOW}正在检测网络环境以适配 Endpoint...${PLAIN}"
    
    # 默认值
    IS_IPV6_ONLY=false
    # 官方通用域名 Endpoint
    FINAL_ENDPOINT="engage.cloudflareclient.com:2408" 
    # 导出纯 IP 地址供防环回使用 (如果是域名则为空或解析)
    FINAL_ENDPOINT_IP=""

    # 严格检测 IPv4
    local ipv4_check=$(curl -4 -s -m 5 http://ip.sb 2>/dev/null)
    
    if [[ "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${GREEN}>>> 检测到有效 IPv4 环境。${PLAIN}"
        echo -e "${GRAY}>>> 使用通用域名 Endpoint: $FINAL_ENDPOINT${PLAIN}"
    else
        IS_IPV6_ONLY=true
        # Cloudflare 官方 IPv6 Endpoint
        local ep_ip="2606:4700:d0::a29f:c001"
        FINAL_ENDPOINT="[${ep_ip}]:2408"
        FINAL_ENDPOINT_IP="${ep_ip}"
        echo -e "${SKYBLUE}>>> 检测到 IPv6-Only 环境。${PLAIN}"
        echo -e "${SKYBLUE}>>> 切换为 IPv6 专用 Endpoint: $FINAL_ENDPOINT${PLAIN}"
    fi
    export FINAL_ENDPOINT
    export FINAL_ENDPOINT_IP
}

# ============================================================
# 2. 获取 WARP 账号信息
# ============================================================
get_warp_account() {
    echo -e "----------------------------------------------------"
    echo -e "${SKYBLUE}配置 WARP 账号参数${PLAIN}"
    
    # 优先使用环境变量 (适配 auto_deploy.sh)
    local p_key="${WARP_PRIV_KEY}"
    local addr="${WARP_IPV6}"
    local reserved="${WARP_RESERVED}"

    if [[ -z "$p_key" ]]; then
        echo -e "${YELLOW}提示: 未检测到预设账号，建议使用 auto_deploy.sh 自动注册。${PLAIN}"
        echo -e "${YELLOW}      此处仅演示手动输入模式。${PLAIN}"
        read -p "私钥 (Private Key): " p_key
        read -p "地址 (IPv6 Address, e.g. 2606:xxxx...): " addr
        read -p "保留字段 (Reserved, e.g. 123,45,67): " reserved
    fi

    if [[ -z "$p_key" || -z "$addr" ]]; then
        echo -e "${RED}错误: WARP 账号信息缺失！${PLAIN}"
        exit 1
    fi

    # 处理 Reserved 格式: [1,2,3] -> 1,2,3
    reserved=$(echo "$reserved" | tr -d '[] ')

    # 导出给后续 jq 使用
    export WG_KEY="$p_key"
    export WG_ADDR="$addr"
    export WG_RESERVED="$reserved"
}

# ============================================================
# 3. 注入配置 (核心逻辑)
# ============================================================
inject_config() {
    echo -e "${YELLOW}正在注入 WARP 出站配置...${PLAIN}"
    
    cp "$CONFIG_FILE" "$BACKUP_FILE"

    # 1. 清理旧的 warp-out 相关配置 (Outbound & Rules)
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
    
    # 3.1 构造防环回规则 (High Priority)
    # 放行 engage 域名和 Endpoint IP 直连
    local anti_loop_domains='["engage.cloudflareclient.com", "cloudflare.com"]'
    local anti_loop_ips="[]"
    if [[ -n "$FINAL_ENDPOINT_IP" ]]; then
        anti_loop_ips="[\"${FINAL_ENDPOINT_IP}\"]"
    fi
    
    local anti_loop_rule=$(jq -n \
        --argjson d "$anti_loop_domains" \
        --argjson i "$anti_loop_ips" \
        '{ "type": "field", "domain": $d, "ip": $i, "outboundTag": "direct" }')
        # 注意: Xray 默认直连 tag 通常叫 "direct" 或 "freedom"，需确保 config.json 里有这个 tag
        # 为了保险，检查是否存在 "direct"，没有则尝试 "freedom"
    
    # 3.2 构造分流规则 (来自环境变量)
    local tags="${WARP_INBOUND_TAGS}"
    local routing_rule=""
    
    if [[ -n "$tags" ]]; then
        echo -e "${GREEN}>>> 模式: 指定节点接管 (Tags: $tags)${PLAIN}"
        local tag_json="[$(echo "$tags" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')]"
        routing_rule=$(jq -n --argjson tags "$tag_json" \
           '{ "type": "field", "inboundTag": $tags, "outboundTag": "warp-out" }')
    elif [[ "$WARP_MODE_SELECT" == "4" ]]; then
         # 全局接管 (示例)
         echo -e "${GREEN}>>> 模式: 全局接管 (Catch-All)${PLAIN}"
         routing_rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "outboundTag": "warp-out" }')
    else
         echo -e "${YELLOW}警告: 未指定接管标签，仅注入防环回规则。${PLAIN}"
    fi

    # 3.3 执行注入 (使用 Prepend 逻辑)
    # 顺序：[防环回] -> [WARP分流] -> [原有规则]
    # 这样防环回永远在最前，WARP 分流紧随其后 (优先级高于默认直连)
    
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
    # 预检查配置有效性 (Xray 自身没有 config check 命令，只能尝试重启)
    # 但我们可以检查 jq 是否生成了合法的 JSON
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

# 执行
check_env
get_warp_account
inject_config
restart_xray
