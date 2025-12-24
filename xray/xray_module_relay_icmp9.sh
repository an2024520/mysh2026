#!/bin/bash

# ============================================================
#  ICMP9 中转扩展模块 (Xray Relay Extension)
#  功能: 将 VPS 变为 ICMP9 的多路中转服务器 (Single Port Multi-Path)
#  依赖: 必须先运行 xray_core.sh 安装好核心环境
#  原理: 入站(VMess+WS) -> 路由(根据Path) -> 出站(ICMP9节点)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 配置文件路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/usr/local/etc/xray/config.json.bak"

# ICMP9 API 地址
API_CONFIG="https://api.icmp9.com/config/config.txt"
API_NODES="https://api.icmp9.com/online.php"

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

# 检查依赖
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}正在安装 jq...${PLAIN}"
    apt-get update && apt-get install -y jq
fi

echo -e "${GREEN}>>> [ICMP9 中转模块] 初始化...${PLAIN}"

# ============================================================
# 1. 获取并解析 ICMP9 配置
# ============================================================
echo -e "${YELLOW}正在获取 ICMP9 远端配置...${PLAIN}"

RAW_CONFIG=$(curl -s --connect-timeout 10 "$API_CONFIG")
if [[ -z "$RAW_CONFIG" ]]; then
    echo -e "${RED}错误: 无法连接 API 获取配置，请检查网络。${PLAIN}"
    exit 1
fi

# 提取关键信息 (参考原 icmp9.sh 逻辑)
REMOTE_HOST=$(echo "$RAW_CONFIG" | grep "^host|" | cut -d'|' -f2 | tr -d '\r\n')
REMOTE_PORT=$(echo "$RAW_CONFIG" | grep "^port|" | cut -d'|' -f2 | tr -d '\r\n')
REMOTE_WSHOST=$(echo "$RAW_CONFIG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
# 如果 API 返回的 tls 为 1，则开启 TLS
REMOTE_TLS_FLAG=$(echo "$RAW_CONFIG" | grep "^tls|" | cut -d'|' -f2 | tr -d '\r\n')
REMOTE_SECURITY="none"
[[ "$REMOTE_TLS_FLAG" == "1" ]] && REMOTE_SECURITY="tls"

if [[ -z "$REMOTE_HOST" || -z "$REMOTE_PORT" ]]; then
    echo -e "${RED}错误: 配置解析失败。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}远端服务器获取成功: ${REMOTE_WSHOST}:${REMOTE_PORT} (${REMOTE_SECURITY})${PLAIN}"

# ============================================================
# 2. 用户交互配置
# ============================================================
echo -e "----------------------------------------------------"
echo -e "${SKYBLUE}请配置中转参数:${PLAIN}"

# 2.1 获取 ICMP9 授权 Key
read -p "请输入您的 ICMP9 授权 KEY (UUID): " REMOTE_UUID
if [[ -z "$REMOTE_UUID" ]]; then
    echo -e "${RED}错误: KEY 不能为空！${PLAIN}"
    exit 1
fi

# 2.2 配置本地中转端口
read -p "请输入 VPS 本地监听端口 (默认 10086): " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-10086}

# 2.3 配置本地地址 (用于生成链接)
# 自动获取公网 IP
PUBLIC_IP=$(curl -s4 http://ip.sb)
echo -e "检测到公网 IP: ${GREEN}$PUBLIC_IP${PLAIN}"
read -p "请输入用于连接的地址/域名 (如果使用了 CF Tunnel，请填 Tunnel 域名，否则直接回车使用 IP): " USER_DOMAIN
USER_DOMAIN=${USER_DOMAIN:-$PUBLIC_IP}

# 2.4 生成本地鉴权 UUID
LOCAL_UUID=$(/usr/local/bin/xray_core/xray uuid)
echo -e "为您生成的本地中转 UUID: ${GREEN}$LOCAL_UUID${PLAIN}"

# ============================================================
# 3. 构建配置 JSON (核心逻辑)
# ============================================================
echo -e "${YELLOW}正在获取节点列表并生成路由规则...${PLAIN}"

# 获取节点列表 JSON
NODES_JSON=$(curl -s "$API_NODES")
# 提取所有国家代码 (如 hk, us, sg)
COUNTRY_CODES=$(echo "$NODES_JSON" | jq -r '.countries[]? | .code')

if [[ -z "$COUNTRY_CODES" ]]; then
    echo -e "${RED}错误: 无法获取节点列表。${PLAIN}"
    exit 1
fi

# 备份配置
cp "$CONFIG_FILE" "$BACKUP_FILE"

# --- 3.1 清理旧配置 ---
# 删除所有 tag 以 "icmp9-" 开头的 inbound, outbound 和 routing rules
echo -e "${YELLOW}清理旧的 ICMP9 配置...${PLAIN}"
jq '
  .inbounds |= map(select(.tag | startswith("icmp9-") | not)) |
  .outbounds |= map(select(.tag | startswith("icmp9-") | not)) |
  .routing.rules |= map(select(.outboundTag | startswith("icmp9-") | not))
' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"


# --- 3.2 构造新的 Inbound (入站) ---
# 监听本地端口，路径设为 / (接受所有路径，后续由路由分发)
jq --arg port "$LOCAL_PORT" --arg uuid "$LOCAL_UUID" '.inbounds += [{
  "tag": "icmp9-relay-in",
  "port": ($port | tonumber),
  "protocol": "vmess",
  "settings": {
    "clients": [{"id": $uuid}]
  },
  "streamSettings": {
    "network": "ws",
    "wsSettings": { "path": "/" }
  }
}]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"


# --- 3.3 循环构造 Outbounds 和 Rules ---
# 这一步通过 bash 循环，构建临时的 json 片段，最后一次性合并，避免频繁 IO
TEMP_OUTBOUNDS_FILE="/tmp/icmp9_outbounds.json"
TEMP_RULES_FILE="/tmp/icmp9_rules.json"
echo "[]" > "$TEMP_OUTBOUNDS_FILE"
echo "[]" > "$TEMP_RULES_FILE"

for code in $COUNTRY_CODES; do
    # 构造 Outbound: 对应每一个国家节点
    # 注意: sni 必须设为 ICMP9 的 wshost
    jq --arg code "$code" \
       --arg host "$REMOTE_HOST" \
       --arg port "$REMOTE_PORT" \
       --arg uuid "$REMOTE_UUID" \
       --arg wshost "$REMOTE_WSHOST" \
       --arg security "$REMOTE_SECURITY" \
       '. + [{
          "tag": ("icmp9-out-" + $code),
          "protocol": "vmess",
          "settings": {
            "vnext": [{
              "address": $host,
              "port": ($port | tonumber),
              "users": [{"id": $uuid, "security": "auto"}]
            }]
          },
          "streamSettings": {
            "network": "ws",
            "security": $security,
            "tlsSettings": (if $security == "tls" then {"serverName": $wshost} else null end),
            "wsSettings": {
              "path": ("/" + $code),
              "headers": {"Host": $wshost}
            }
          }
       }]' "$TEMP_OUTBOUNDS_FILE" > "${TEMP_OUTBOUNDS_FILE}.tmp" && mv "${TEMP_OUTBOUNDS_FILE}.tmp" "$TEMP_OUTBOUNDS_FILE"

    # 构造 Routing Rule: 路径匹配
    # 如果入站是 icmp9-relay-in 且路径包含 /relay/hk，则路由到 icmp9-out-hk
    jq --arg code "$code" \
       '. + [{
          "type": "field",
          "inboundTag": ["icmp9-relay-in"],
          "outboundTag": ("icmp9-out-" + $code),
          "path": [("/relay/" + $code)]
       }]' "$TEMP_RULES_FILE" > "${TEMP_RULES_FILE}.tmp" && mv "${TEMP_RULES_FILE}.tmp" "$TEMP_RULES_FILE"
done

# --- 3.4 将生成的片段合并回主配置 ---
# 注入 Outbounds
jq --slurpfile new_outs "$TEMP_OUTBOUNDS_FILE" '.outbounds += $new_outs[0]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

# 注入 Rules (注意：路由规则最好插在最前面，但 jq 追加到最后也行，只要不与 block 规则冲突)
# 这里我们选择追加到 rules 数组的前部 (如果用 += 则是追加到尾部)
# 为了简单稳妥，我们追加到数组里。Xray 是按顺序匹配的，只要前面没有 "block all"，通常没问题。
jq --slurpfile new_rules "$TEMP_RULES_FILE" '.routing.rules = ($new_rules[0] + .routing.rules)' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

# 清理临时文件
rm -f "$TEMP_OUTBOUNDS_FILE" "$TEMP_RULES_FILE" "${CONFIG_FILE}.tmp"

# ============================================================
# 4. 重启服务与链接生成
# ============================================================
echo -e "${YELLOW}正在重启 Xray 服务...${PLAIN}"
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    echo -e "${GREEN}>>> ICMP9 中转模块部署成功！${PLAIN}"
    echo -e ""
    echo -e "中转入口信息:"
    echo -e "地址 (Address): ${SKYBLUE}${USER_DOMAIN}${PLAIN}"
    echo -e "端口 (Port)   : ${SKYBLUE}${LOCAL_PORT}${PLAIN}"
    echo -e "用户 ID (UUID): ${SKYBLUE}${LOCAL_UUID}${PLAIN}"
    echo -e "传输协议      : VMess + WS"
    echo -e "----------------------------------------------------"
    echo -e "${YELLOW}以下是为您生成的 V2RayN 格式链接 (已包含路径分流):${PLAIN}"
    echo -e ""

    # 循环生成链接
    # 从 NODES_JSON 里重新读取 name, emoji 和 code
    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r item; do
        CODE=$(echo "$item" | jq -r '.code')
        NAME=$(echo "$item" | jq -r '.name')
        EMOJI=$(echo "$item" | jq -r '.emoji')
        
        # 构造 VMess JSON
        # 注意: path 设置为 /relay/<code>，这就是我们在 Routing Rule 里匹配的路径
        VMESS_JSON=$(jq -n \
            --arg v "2" \
            --arg ps "${EMOJI} 中转->${NAME}" \
            --arg add "$USER_DOMAIN" \
            --arg port "$LOCAL_PORT" \
            --arg id "$LOCAL_UUID" \
            --arg path "/relay/${CODE}" \
            --arg host "$USER_DOMAIN" \
            --arg sni "$USER_DOMAIN" \
            '{
                v: $v,
                ps: $ps,
                add: $add,
                port: $port,
                id: $id,
                aid: "0",
                scy: "auto",
                net: "ws",
                type: "none",
                host: $host,
                path: $path,
                tls: "none",
                sni: "",
                alpn: ""
            }')
        
        # 简单的 Base64 编码 (vmess://)
        LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
        echo -e "${GREEN}${LINK}${PLAIN}"
    done
    
    echo -e ""
    echo -e "${SKYBLUE}提示: 如果您使用了 Cloudflare Tunnel，请手动确保 V2RayN 中开启 TLS 并将 SNI 填为您的域名。${PLAIN}"
    echo -e "${SKYBLUE}生成的链接默认 TLS 为 none (因无法判断您是否有证书)。如果使用 Tunnel，请手动改为 TLS。${PLAIN}"
else
    echo -e "${RED}错误: Xray 服务重启失败！${PLAIN}"
    echo -e "请检查配置文件: $CONFIG_FILE"
    echo -e "正在尝试还原备份..."
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    systemctl restart xray
fi
