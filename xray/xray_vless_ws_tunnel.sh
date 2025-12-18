#!/bin/bash

# ============================================================
#  模块九：VLESS + WS (Tunnel 专用版 / 无需证书)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"

echo -e "${GREEN}>>> [模块九] 智能添加节点: VLESS + WebSocket (Tunnel专用)...${PLAIN}"

# 1. 环境检查
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Xray 核心！请先运行 [模块一]。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# 2. 配置文件初始化
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}配置文件不存在，正在初始化标准骨架...${PLAIN}"
    mkdir -p /usr/local/etc/xray
    cat <<EOF > $CONFIG_FILE
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": ["geoip:private"]
      }
    ]
  }
}
EOF
    echo -e "${GREEN}标准骨架初始化完成。${PLAIN}"
fi

# 3. 用户配置参数
echo -e "${YELLOW}--- 配置 Tunnel 对接节点 ---${PLAIN}"

# A. 端口设置
while true; do
    read -p "请输入 Xray 监听端口 (Tunnel 将转发到此端口, 默认 8080): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && CUSTOM_PORT=8080
    
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        if grep -q "\"port\": $CUSTOM_PORT" "$CONFIG_FILE"; then
             echo -e "${RED}警告: 端口 $CUSTOM_PORT 似乎已被占用了，请换一个！${PLAIN}"
        else
             PORT="$CUSTOM_PORT"
             break
        fi
    else
        echo -e "${RED}无效端口。${PLAIN}"
    fi
done

# B. 绑定域名 (仅用于生成分享链接)
echo -e "${YELLOW}请输入您在 Cloudflare Tunnel 绑定的公网域名:${PLAIN}"
echo -e "${YELLOW}(脚本需要它来生成客户端链接，请确保 Tunnel 已指向 http://127.0.0.1:$PORT)${PLAIN}"
read -p "域名 (例如 vless.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1

# C. WS 路径配置
DEFAULT_PATH="/$(openssl rand -hex 4)"
read -p "请输入 WebSocket 路径 (默认 ${DEFAULT_PATH}): " WS_PATH
[[ -z "$WS_PATH" ]] && WS_PATH="$DEFAULT_PATH"

# 4. 生成密钥 (UUID)
echo -e "${YELLOW}正在生成 UUID...${PLAIN}"
UUID=$($XRAY_BIN uuid)

# 5. 构建节点 JSON (No TLS, Listen Localhost)
echo -e "${YELLOW}正在注入节点配置...${PLAIN}"

NODE_TAG="vless-ws-tunnel-${PORT}"

# 关键配置：listen 127.0.0.1, security none
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg path "$WS_PATH" \
    '{
      tag: $tag,
      listen: "127.0.0.1",
      port: ($port | tonumber),
      protocol: "vless",
      settings: {
        clients: [{id: $uuid, flow: ""}],
        decryption: "none"
      },
      streamSettings: {
        network: "ws",
        security: "none",
        wsSettings: {
          path: $path
        }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic"],
        routeOnly: true
      }
    }')

tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 6. 重启与输出
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    # 链接生成逻辑：
    # 客户端连接 -> Cloudflare (TLS:443) -> Tunnel -> Xray (NoTLS:LocalPort)
    # 所以链接必须写: port=443, security=tls
    
    NODE_NAME="Xray-Tunnel-${PORT}"
    SHARE_LINK="vless://${UUID}@${DOMAIN}:443?security=tls&encryption=none&type=ws&path=${WS_PATH}&sni=${DOMAIN}&fp=chrome#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [模块九] Tunnel 节点部署成功！      ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "本地监听    : ${YELLOW}127.0.0.1:${PORT}${PLAIN}"
    echo -e "WS 路径     : ${YELLOW}${WS_PATH}${PLAIN}"
    echo -e "绑定域名    : ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "⚠️  请务必在 Cloudflare Zero Trust 后台配置："
    echo -e "   Service: ${GREEN}http://127.0.0.1:${PORT}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # === OpenClash 输出 ===
    echo -e "🐱 [OpenClash / Meta 配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: vless
  server: ${DOMAIN}
  port: 443
  uuid: ${UUID}
  network: ws
  tls: true
  udp: true
  servername: ${DOMAIN}
  client-fingerprint: chrome
  ws-opts:
    path: "${WS_PATH}"
    headers:
      Host: ${DOMAIN}
EOF
    echo -e "${PLAIN}----------------------------------------"
else
    echo -e "${RED}启动失败！${PLAIN}"
    echo -e "日志: journalctl -u xray -e"
fi
