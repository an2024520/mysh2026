#!/bin/bash

# ============================================================
#  模块四：VLESS + XHTTP + Reality + ENC (抗量子加密版)
#  - 协议: VLESS + XHTTP (HTTP/3)
#  - 安全: Reality + ML-KEM-768 (Quantum-Resistant)
#  - 核心要求: Xray-core v25.x+
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"

echo -e "${GREEN}>>> [模块四] 部署抗量子节点: VLESS + XHTTP + Reality + ML-KEM ...${PLAIN}"

# 1. 环境与核心版本检查
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Xray 核心！请先运行 [模块一]。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}安装依赖 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# 检查是否支持 ML-KEM (ENC)
IS_MLKEM_SUPPORTED=false
if "$XRAY_BIN" help | grep -q "mlkem768"; then
    IS_MLKEM_SUPPORTED=true
    echo -e "${GREEN}>>> 检测到 Xray 核心支持 ML-KEM-768 抗量子加密！${PLAIN}"
else
    echo -e "${RED}警告: 当前 Xray 核心版本过低，不支持 ML-KEM 抗量子加密。${PLAIN}"
    echo -e "${YELLOW}>>> 将自动回退到标准 X25519 算法。${PLAIN}"
    echo -e "${YELLOW}>>> 请升级 Xray 核心至 v25.x+ 以启用抗量子特性。${PLAIN}"
    sleep 2
fi

# 2. 配置文件初始化
if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat <<EOF > "$CONFIG_FILE"
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      { "type": "field", "outboundTag": "blocked", "ip": ["geoip:private"] }
    ]
  }
}
EOF
fi

# 3. 用户配置 (自动/手动)
if [[ "$AUTO_SETUP" == "true" ]]; then
    # 自动模式
    echo -e "${YELLOW}>>> [自动模式] 读取参数...${PLAIN}"
    PORT="${PORT:-2088}" # 默认抗量子端口
    echo -e "    端口 (PORT): ${GREEN}${PORT}${PLAIN}"
    SNI="www.google.com" # 自动模式默认SNI (XHTTP 推荐大厂)
else
    # 手动模式
    echo -e "${YELLOW}--- 配置 XHTTP + ML-KEM 参数 ---${PLAIN}"
    while true; do
        read -p "请输入监听端口 (默认 2088): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=2088 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    echo -e "${YELLOW}请选择伪装域名 (SNI) - XHTTP 建议选择支持 HTTP/3 的大厂:${PLAIN}"
    echo -e "  1. www.google.com (Google - 极速)"
    echo -e "  2. www.cloudflare.com (CF - 稳健)"
    echo -e "  3. 手动输入"
    read -p "选择: " s
    case $s in
        2) SNI="www.cloudflare.com" ;;
        3) read -p "输入域名: " SNI; [[ -z "$SNI" ]] && SNI="www.google.com" ;;
        *) SNI="www.google.com" ;;
    esac
fi

# 4. 生成密钥 (抗量子核心逻辑)
echo -e "${YELLOW}正在生成密钥对 (ENC)...${PLAIN}"

UUID=$($XRAY_BIN uuid)
SHORT_ID=$(openssl rand -hex 4)
XHTTP_PATH="/$(openssl rand -hex 6)"

if [[ "$IS_MLKEM_SUPPORTED" == "true" ]]; then
    # 生成 ML-KEM-768 密钥
    # 格式通常为 "Private key: ... \n Public key: ..."
    RAW_KEYS=$($XRAY_BIN mlkem768)
    KEY_TYPE_LABEL="ML-KEM-768 (Anti-Quantum)"
else
    # 回退到 X25519
    RAW_KEYS=$($XRAY_BIN x25519)
    KEY_TYPE_LABEL="X25519 (Standard)"
fi

PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "Private" | awk -F ": " '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep -E "Password|Public" | awk -F ": " '{print $2}' | tr -d ' \r\n')

# 5. 注入节点配置
NODE_TAG="Xray-XHTTP-ENC-${PORT}"

# 清理旧配置 (同端口或同Tag)
tmp_clean=$(mktemp)
jq --argjson p "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.port == $p or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# 构建节点 JSON
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg path "$XHTTP_PATH" \
    --arg sni "$SNI" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    '{
      tag: $tag,
      listen: "0.0.0.0",
      port: ($port | tonumber),
      protocol: "vless",
      settings: {
        clients: [{id: $uuid, flow: ""}],
        decryption: "none"
      },
      streamSettings: {
        network: "xhttp",
        xhttpSettings: {
            path: $path,
            host: $sni
        },
        security: "reality",
        realitySettings: {
          show: false,
          dest: ($sni + ":443"),
          serverNames: [$sni],
          privateKey: $pk,
          shortIds: [$sid]
        }
      },
      sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true }
    }')

tmp_add=$(mktemp)
# [修复] 变量名统一为 new_node
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp_add" && mv "$tmp_add" "$CONFIG_FILE"

# 6. 重启与输出
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    # 链接构造
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_TAG}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [ENC] 抗量子节点部署成功！          ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "协议        : ${SKYBLUE}VLESS + XHTTP + Reality${PLAIN}"
    echo -e "加密算法    : ${RED}${KEY_TYPE_LABEL}${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "Path        : ${YELLOW}${XHTTP_PATH}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [通用分享链接] (需最新版客户端):"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # OpenClash / Meta 格式输出
    echo -e "🐱 [Mihomo / Meta YAML配置]:"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_TAG}"
  type: vless
  server: ${PUBLIC_IP}
  port: ${PORT}
  uuid: ${UUID}
  network: xhttp
  tls: true
  udp: true
  flow: ""
  servername: ${SNI}
  client-fingerprint: chrome
  xhttp-opts:
    path: ${XHTTP_PATH}
    headers:
      Host: ${SNI}
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: ${SHORT_ID}
EOF
    echo -e "${PLAIN}----------------------------------------"
    
    if [[ "$AUTO_SETUP" == "true" ]]; then
        echo "Tag: ${NODE_TAG} (ENC) | ${SHARE_LINK}" >> "/root/xray_nodes.txt"
    fi
else
    echo -e "${RED}启动失败！请检查日志 (journalctl -u xray -e) ${PLAIN}"
    echo -e "${RED}可能原因: 您的 Xray 核心版本不支持配置中的 ML-KEM 密钥格式。${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
