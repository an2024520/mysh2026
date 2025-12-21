#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + WS + TLS (v1.0)
#  - 协议: VLESS + WebSocket + TLS (Self-Signed)
#  - 场景: 也就是常说的 CDN 节点 (Cloudflare/Gcore 等)
#  - 核心: Systemd 日志托管 | 端口霸占 | 自动生成证书
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/sing-box/config.json"
SB_BIN="/usr/local/bin/sing-box"
CERT_DIR="/usr/local/etc/sing-box/certs"

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + WS + TLS (CDN) ...${PLAIN}"

# 1. 环境检查
if [[ ! -f "$SB_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 核心！请先运行 [核心环境管理] 安装。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# 2. 初始化配置文件 (Systemd 日志托管模式)
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}配置文件不存在，正在初始化标准骨架...${PLAIN}"
    mkdir -p /usr/local/etc/sing-box
    cat <<EOF > $CONFIG_FILE
{
  "log": {
    "level": "info",
    "output": "",
    "timestamp": false
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": []
  }
}
EOF
    echo -e "${GREEN}标准骨架初始化完成。${PLAIN}"
fi

# 3. 用户配置参数
echo -e "${YELLOW}--- 配置 VLESS-WS-TLS (CDN) 参数 ---${PLAIN}"

# A. 端口设置 (CDN 常用端口提示)
echo -e "Cloudflare 支持端口: ${SKYBLUE}443, 2053, 2083, 2087, 2096, 8443${PLAIN}"
while true; do
    read -p "请输入监听端口 (默认 8443): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=8443 && break
    
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        if grep -q "\"listen_port\": $CUSTOM_PORT" "$CONFIG_FILE"; then
             echo -e "${YELLOW}提示: 端口 $CUSTOM_PORT 已被占用，脚本将强制覆盖该端口的旧配置。${PLAIN}"
        fi
        PORT="$CUSTOM_PORT"
        break
    else
        echo -e "${RED}无效端口。${PLAIN}"
    fi
done

# B. 域名 (SNI)
echo -e "${YELLOW}请输入你的域名 (Cloudflare 解析的域名)${PLAIN}"
read -p "域名 (例如: vps.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}错误: 必须输入域名才能使用 TLS 模式！${PLAIN}"
    exit 1
fi

# C. WS 路径
read -p "请输入 WebSocket 路径 (默认 /ws): " WS_PATH
[[ -z "$WS_PATH" ]] && WS_PATH="/ws"
# 确保路径以 / 开头
if [[ "${WS_PATH:0:1}" != "/" ]]; then
    WS_PATH="/$WS_PATH"
fi

# 4. 生成自签名证书
echo -e "${YELLOW}正在生成自签名证书 (适配 Cloudflare Full 模式)...${PLAIN}"
mkdir -p "$CERT_DIR"
CERT_FILE="${CERT_DIR}/${DOMAIN}_${PORT}.crt"
KEY_FILE="${CERT_DIR}/${DOMAIN}_${PORT}.key"

# 使用 OpenSSL 生成 10年有效期的自签名证书
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 \
    -subj "/CN=$DOMAIN" >/dev/null 2>&1

if [[ ! -f "$KEY_FILE" ]]; then
    echo -e "${RED}错误: 证书生成失败！${PLAIN}"
    exit 1
fi
echo -e "证书已保存至: $CERT_DIR"

# 5. 生成 UUID
UUID=$($SB_BIN generate uuid)

# 6. 构建与注入节点
echo -e "${YELLOW}正在更新配置文件...${PLAIN}"

NODE_TAG="vless-ws-${PORT}"

# === 步骤 1: 强制日志托管 ===
tmp_log=$(mktemp)
jq '.log.output = "" | .log.timestamp = false' "$CONFIG_FILE" > "$tmp_log" && mv "$tmp_log" "$CONFIG_FILE"

# === 步骤 2: 端口霸占清理 ===
tmp0=$(mktemp)
jq --argjson port "$PORT" 'del(.inbounds[] | select(.listen_port == $port))' "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

# === 步骤 3: 构建 Sing-box VLESS WS TLS JSON ===
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg path "$WS_PATH" \
    --arg cert "$CERT_FILE" \
    --arg key "$KEY_FILE" \
    '{
        "type": "vless",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [
            {
                "uuid": $uuid
            }
        ],
        "transport": {
            "type": "ws",
            "path": $path
        },
        "tls": {
            "enabled": true,
            "certificate_path": $cert,
            "key_path": $key
        }
    }')

# 插入新节点
tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 7. 重启与输出
echo -e "${YELLOW}正在重启服务...${PLAIN}"
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    # 获取本机IP (虽然 CDN 节点客户端填的是域名，但这里显示一下本机IP作为参考)
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    NODE_NAME="SB-WS-TLS-${PORT}"
    
    # 构造 v2rayN 链接 (标准格式)
    # 格式: vless://uuid@domain:port?type=ws&security=tls&path=/ws&sni=domain#name
    SHARE_LINK="vless://${UUID}@${DOMAIN}:${PORT}?type=ws&security=tls&path=${WS_PATH}&sni=${DOMAIN}#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [Sing-box] CDN 节点添加成功！       ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "域名 (Sni)  : ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "端口 (Port) : ${YELLOW}${PORT}${PLAIN}"
    echo -e "路径 (Path) : ${YELLOW}${WS_PATH}${PLAIN}"
    echo -e "UUID        : ${SKYBLUE}${UUID}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "⚠️ [重要提示]:"
    echo -e "1. 你的 Cloudflare SSL/TLS 设置必须为: ${RED}Full (完整)${PLAIN} 或 ${RED}Full (Strict)${PLAIN}"
    echo -e "2. 请确保域名 ${DOMAIN} 已解析到本机 IP: ${PUBLIC_IP}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # === OpenClash / Meta 配置块 ===
    echo -e "🐱 [Clash Meta / OpenClash 配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: vless
  server: ${DOMAIN}
  port: ${PORT}
  uuid: ${UUID}
  network: ws
  tls: true
  udp: true
  servername: ${DOMAIN}
  ws-opts:
    path: "${WS_PATH}"
    headers:
      Host: ${DOMAIN}
  client-fingerprint: chrome
EOF
    echo -e "${PLAIN}----------------------------------------"

    # === Sing-box 客户端配置块 ===
    echo -e "📱 [Sing-box 客户端配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
{
  "type": "vless",
  "tag": "proxy-out",
  "server": "${DOMAIN}",
  "server_port": ${PORT},
  "uuid": "${UUID}",
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN}",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    }
  },
  "transport": {
    "type": "ws",
    "path": "${WS_PATH}"
  }
}
EOF
    echo -e "${PLAIN}----------------------------------------"

else
    echo -e "${RED}启动失败！请检查日志: journalctl -u sing-box -e${PLAIN}"
fi
