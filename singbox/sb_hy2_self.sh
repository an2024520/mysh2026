#!/bin/bash

# ============================================================
#  Sing-box 节点新增: Hysteria 2 + Self-Signed (自签证书)
#  - 核心: 自动生成 SSL 证书 + 写入 Inbounds + 写入 .meta
#  - 协议: Hysteria 2 (UDP 暴力协议)
#  - 特性: 支持 Obfs 混淆 / 自动生成自签证书 / 端口清理
#  - 更新: 新增 OpenClash 格式输出
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: Hysteria 2 (自签证书版) ...${PLAIN}"

# 1. 智能路径查找
# ------------------------------------------------
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then
        CONFIG_FILE="$p"
        break
    fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="/usr/local/etc/sing-box/config.json"
fi

CONFIG_DIR=$(dirname "$CONFIG_FILE")
META_FILE="${CONFIG_FILE}.meta"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")
CERT_DIR="${CONFIG_DIR}/cert" # 证书存放目录

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"

# 2. 环境检查
if [[ ! -f "$SB_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 核心！请先运行 [核心环境管理] 安装。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 (jq, openssl)...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y jq openssl
    elif [ -f /etc/redhat-release ]; then
        yum install -y jq openssl
    fi
fi

# 3. 初始化配置与目录
if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$CONFIG_DIR"
    cat <<EOF > "$CONFIG_FILE"
{
  "log": { "level": "info", "output": "", "timestamp": false },
  "inbounds": [],
  "outbounds": [ { "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" } ],
  "route": { "rules": [] }
}
EOF
fi
mkdir -p "$CERT_DIR"

# 4. 用户配置参数
echo -e "${YELLOW}--- 配置 Hysteria 2 (Self-Signed) 参数 ---${PLAIN}"

# A. 端口设置
while true; do
    read -p "请输入 UDP 监听端口 (推荐 8443, 443, 默认 10086): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=10086 && break
    
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        if grep -q "\"listen_port\": $CUSTOM_PORT" "$CONFIG_FILE"; then
             echo -e "${YELLOW}提示: 端口 $CUSTOM_PORT 已被占用，脚本将强制覆盖。${PLAIN}"
        fi
        PORT="$CUSTOM_PORT"
        break
    else
        echo -e "${RED}无效端口。${PLAIN}"
    fi
done

# B. 密码与混淆
PASSWORD=$(openssl rand -base64 16)
OBFS_PASS=$(openssl rand -hex 8)

echo -e "${YELLOW}已自动生成高强度密码与混淆密钥。${PLAIN}"

# 5. 生成自签证书
echo -e "${YELLOW}正在生成自签证书...${PLAIN}"
# 生成 100 年有效期的自签证书
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$CERT_DIR/self_${PORT}.key" -out "$CERT_DIR/self_${PORT}.crt" -days 36500 -subj "/CN=bing.com" 2>/dev/null

if [[ ! -f "$CERT_DIR/self_${PORT}.crt" ]]; then
    echo -e "${RED}错误: 证书生成失败！${PLAIN}"
    exit 1
fi
CERT_PATH="$CERT_DIR/self_${PORT}.crt"
KEY_PATH="$CERT_DIR/self_${PORT}.key"

# 6. 构建与注入节点
echo -e "${YELLOW}正在更新配置文件...${PLAIN}"

NODE_TAG="Hy2-Self-${PORT}"

# === 步骤 1: 强制日志托管 ===
tmp_log=$(mktemp)
jq '.log.output = "" | .log.timestamp = false' "$CONFIG_FILE" > "$tmp_log" && mv "$tmp_log" "$CONFIG_FILE"

# === 步骤 2: 端口霸占清理 ===
tmp0=$(mktemp)
jq --argjson port "$PORT" 'del(.inbounds[]? | select(.listen_port == $port))' "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

# === 步骤 3: 构建 Hysteria 2 JSON ===
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg pass "$PASSWORD" \
    --arg obfs "$OBFS_PASS" \
    --arg cert "$CERT_PATH" \
    --arg key "$KEY_PATH" \
    '{
        "type": "hysteria2",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [
            {
                "password": $pass
            }
        ],
        "obfs": {
            "type": "salamander",
            "password": $obfs
        },
        "tls": {
            "enabled": true,
            "certificate_path": $cert,
            "key_path": $key
        }
    }')

# 插入新节点
tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" 'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# === 步骤 4: 写入 Meta ===
if [[ ! -f "$META_FILE" ]]; then echo "{}" > "$META_FILE"; fi
tmp_meta=$(mktemp)
jq --arg tag "$NODE_TAG" --arg pass "$PASSWORD" --arg obfs "$OBFS_PASS" \
   '. + {($tag): {"type": "hy2-self", "pass": $pass, "obfs": $obfs}}' "$META_FILE" > "$tmp_meta" && mv "$tmp_meta" "$META_FILE"

# 7. 重启与输出
echo -e "${YELLOW}正在重启服务...${PLAIN}"
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    NODE_NAME="$NODE_TAG"
    
    # 构造 v2rayN 链接 (hy2://password@ip:port?insecure=1&obfs=salamander&obfs-password=xxx&sni=bing.com#tag)
    SHARE_LINK="hysteria2://${PASSWORD}@${PUBLIC_IP}:${PORT}?insecure=1&obfs=salamander&obfs-password=${OBFS_PASS}&sni=bing.com#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}   [Sing-box] Hy2 (自签) 节点添加成功   ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "认证密码    : ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "混淆密码    : ${YELLOW}${OBFS_PASS}${PLAIN}"
    echo -e "跳过验证    : ${RED}是 (Allow Insecure)${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🐱 [OpenClash / Clash Meta 配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: hysteria2
  server: "${PUBLIC_IP}"
  port: ${PORT}
  password: "${PASSWORD}"
  sni: "bing.com"
  skip-cert-verify: true
  obfs: salamander
  obfs-password: "${OBFS_PASS}"
EOF
    echo -e "${PLAIN}----------------------------------------"
    echo -e "📱 [Sing-box 客户端配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
{
  "type": "hysteria2",
  "tag": "proxy-out",
  "server": "${PUBLIC_IP}",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "bing.com",
    "insecure": true
  },
  "obfs": {
    "type": "salamander",
    "password": "${OBFS_PASS}"
  }
}
EOF
    echo -e "${PLAIN}----------------------------------------"
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u sing-box -e${PLAIN}"
fi

}
