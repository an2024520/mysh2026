#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + Vision + Reality (v1.0)
#  - 协议: VLESS (Vision流控)
#  - 兼容: 支持 v2rayN / OpenClash / Clash Meta
#  - 核心: 继承 AnyTLS 脚本的 Systemd 日志托管与防冲突逻辑
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

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + Vision + Reality ...${PLAIN}"

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
echo -e "${YELLOW}--- 配置 VLESS (Vision) 节点参数 ---${PLAIN}"

# A. 端口设置
while true; do
    read -p "请输入监听端口 (推荐 443, 2053, 默认 443): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=443 && break
    
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        if grep -q "\"listen_port\": $CUSTOM_PORT" "$CONFIG_FILE"; then
             echo -e "${YELLOW}提示: 端口 $CUSTOM_PORT 已存在，脚本将自动覆盖旧配置。${PLAIN}"
        fi
        PORT="$CUSTOM_PORT"
        break
    else
        echo -e "${RED}无效端口。${PLAIN}"
    fi
done

# B. 伪装域名选择
echo -e "${YELLOW}请选择伪装域名 (SNI) - 推荐:${PLAIN}"
echo -e "  1. www.sony.jp (索尼日本)"
echo -e "  2. www.nintendo.co.jp (任天堂)"
echo -e "  3. updates.cdn-apple.com (苹果CDN)"
echo -e "  4. www.microsoft.com (微软)"
echo -e "  5. ${GREEN}手动输入${PLAIN}"
read -p "请选择 [1-5] (默认 3): " SNI_CHOICE

case $SNI_CHOICE in
    1) SNI="www.sony.jp" ;;
    2) SNI="www.nintendo.co.jp" ;;
    4) SNI="www.microsoft.com" ;;
    5) 
        read -p "请输入域名 (不带https://): " MANUAL_SNI
        [[ -z "$MANUAL_SNI" ]] && SNI="updates.cdn-apple.com" || SNI="$MANUAL_SNI"
        ;;
    *) SNI="updates.cdn-apple.com" ;;
esac

# C. 连通性校验
echo -e "${YELLOW}正在检查连通性: $SNI ...${PLAIN}"
if ! curl -s -I --max-time 5 "https://$SNI" >/dev/null; then
    echo -e "${RED}警告: 无法连接到 $SNI。建议更换。${PLAIN}"
    read -p "是否强制继续? (y/n): " FORCE
    [[ "$FORCE" != "y" ]] && exit 1
fi

# 4. 生成密钥与 UUID
echo -e "${YELLOW}正在生成密钥与 UUID...${PLAIN}"

# VLESS 使用 UUID
UUID=$($SB_BIN generate uuid)

# Reality Keypair
KEY_PAIR=$($SB_BIN generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "PublicKey" | awk '{print $2}')
SHORT_ID=$($SB_BIN generate rand --hex 8)

if [[ -z "$PRIVATE_KEY" ]]; then
    echo -e "${RED}错误: 密钥生成失败！${PLAIN}"
    exit 1
fi

# 5. 构建与注入节点
echo -e "${YELLOW}正在更新配置文件...${PLAIN}"

NODE_TAG="vless-vision-${PORT}"

# === 步骤 1: 强制日志托管 (防止 Permission Denied) ===
tmp_log=$(mktemp)
jq '.log.output = "" | .log.timestamp = false' "$CONFIG_FILE" > "$tmp_log" && mv "$tmp_log" "$CONFIG_FILE"

# === 步骤 2: 清理旧同名 Tag ===
tmp0=$(mktemp)
jq --arg tag "$NODE_TAG" 'del(.inbounds[] | select(.tag == $tag))' "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

# === 步骤 3: 构建 Sing-box 标准 VLESS Vision JSON ===
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg dest "$SNI" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    '{
        "type": "vless",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [
            {
                "uuid": $uuid,
                "flow": "xtls-rprx-vision"
            }
        ],
        "tls": {
            "enabled": true,
            "server_name": $dest,
            "reality": {
                "enabled": true,
                "handshake": {
                    "server": $dest,
                    "server_port": 443
                },
                "private_key": $pk,
                "short_id": [$sid]
            }
        }
    }')

# 插入新节点
tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 6. 重启与输出
echo -e "${YELLOW}正在重启服务...${PLAIN}"
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    NODE_NAME="SB-Vision-${PORT}"
    
    # 构造 v2rayN 链接 (标准的 VLESS Vision 格式)
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [Sing-box] 节点已追加/更新成功！    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "SNI (伪装)  : ${YELLOW}${SNI}${PLAIN}"
    echo -e "流控 (Flow) : xtls-rprx-vision"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # === 新增：OpenClash / Meta 配置块 ===
    echo -e "🐱 [Clash Meta / OpenClash 配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: vless
  server: ${PUBLIC_IP}
  port: ${PORT}
  uuid: ${UUID}
  network: tcp
  tls: true
  udp: true
  flow: xtls-rprx-vision
  servername: ${SNI}
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: ${SHORT_ID}
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
  "server": "${PUBLIC_IP}",
  "server_port": ${PORT},
  "uuid": "${UUID}",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "${PUBLIC_KEY}",
      "short_id": "${SHORT_ID}"
    }
  }
}
EOF
    echo -e "${PLAIN}----------------------------------------"

else
    echo -e "${RED}启动失败！请检查日志: journalctl -u sing-box -e${PLAIN}"
fi
