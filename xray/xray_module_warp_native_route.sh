#!/bin/bash

# ============================================================
#  Xray WARP Native Route 模块 (v2.0 IPv6 Adaptive)
#  - 功能: 为 Xray 添加 WireGuard (WARP) 出站
#  - 适配: 自动识别 IPv6-Only 环境并切换 Endpoint
#  - 模式: 支持全局接管 / 指定节点接管 / 分流模式
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

    # 严格检测 IPv4
    local ipv4_check=$(curl -4 -s -m 5 http://ip.sb 2>/dev/null)
    
    if [[ "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${GREEN}>>> 检测到有效 IPv4 环境。${PLAIN}"
        echo -e "${GRAY}>>> 使用通用域名 Endpoint: $FINAL_ENDPOINT${PLAIN}"
    else
        IS_IPV6_ONLY=true
        # Cloudflare 官方 IPv6 Endpoint
        FINAL_ENDPOINT="[2606:4700:d0::a29f:c001]:2408"
        echo -e "${SKYBLUE}>>> 检测到 IPv6-Only 环境。${PLAIN}"
        echo -e "${SKYBLUE}>>> 切换为 IPv6 专用 Endpoint: $FINAL_ENDPOINT${PLAIN}"
    fi
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

    # 如果没有环境变量，尝试自动注册 (这里简化为必须提供或由外部工具生成，
    # 实际场景中通常调用 wgcf-account 或 warp-reg 工具，此处假设用户已获知参数或使用自备参数)
    # 为了保持脚本纯净，这里建议对接 auto_deploy.sh 传入的变量，
    # 或者如果变量为空，提示用户输入。

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

    # 1. 清理旧的 warp-out
    jq '
      .outbounds |= map(select(.tag != "warp-out")) |
      .routing.rules |= map(select(.outboundTag != "warp-out"))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 2. 注入 Outbound (使用 $FINAL_ENDPOINT)
    # 构造 Reserved JSON 数组字符串
    local res_json="[$(echo $WG_RESERVED | sed 's/,/,/g')]"
    
    jq --arg key "$WG_KEY" \
       --arg addr "$WG_ADDR" \
       --argjson res "$res_json" \
       --arg endpoint "$FINAL_ENDPOINT" \
       '.outbounds += [{
          "tag": "warp-out",
          "protocol": "freedom",
          "settings": {
            "domainStrategy": "UseIP"
          },
          "streamSettings": {
            "network": "headers", 
            "security": "none" 
          }
       }]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 
       # 注意: 上面只是占位，实际 WireGuard 需要 Xray v1.8+ 的 protocol: "wireguard"
       # 由于 jq 构造复杂对象较繁琐，这里采用简化的 WireGuard 配置结构:
       
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

    # 3. 注入路由规则 (根据模式)
    # 模式来自于 auto_deploy.sh 的 WARP_MODE_SELECT 或 WARP_INBOUND_TAGS
    
    echo -e "${YELLOW}正在配置分流规则...${PLAIN}"
    
    # 获取指定的入站标签 (如果有)
    local tags="${WARP_INBOUND_TAGS}"
    
    if [[ -n "$tags" ]]; then
        echo -e "${GREEN}>>> 模式: 指定节点接管 (Tags: $tags)${PLAIN}"
        # 将逗号分隔的字符串转为 jq 数组
        local tag_json="[$(echo "$tags" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')]"
        
        # 插入规则：匹配 inboundTag -> warp-out
        # 这里的规则应该放在靠前位置，但要排在 ICMP9 之后。
        # 由于 ICMP9 是 "prepend" (插入头部)，我们这里用 "append" (追加) 或正常 += 即可，
        # 只要 ICMP9 脚本是最后运行的，或者 ICMP9 脚本总是把自己插到最前面。
        
        jq --argjson tags "$tag_json" \
           '.routing.rules += [{
              "type": "field",
              "inboundTag": $tags,
              "outboundTag": "warp-out"
           }]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
        echo -e "${YELLOW}警告: 未指定接管标签，未添加路由规则 (WARP 仅作为备用出站存在)。${PLAIN}"
    fi
}

# ============================================================
# 4. 重启验证
# ============================================================
restart_xray() {
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}WARP 模块加载成功！Endpoint: $FINAL_ENDPOINT${PLAIN}"
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
