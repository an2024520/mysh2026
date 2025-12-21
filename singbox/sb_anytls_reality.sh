#!/bin/bash

# ============================================================
#  Sing-box 节点新增工具 (AnyTLS + Reality)
#  - 协议: AnyTLS (Sing-box 专属传输协议)
#  - 安全: Reality (无需域名 / 偷取 SNI 证书)
#  - 特性: 极度拟态，模拟任意 TLS 指纹
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONF_FILE="/usr/local/etc/sing-box/config.json"

# 1. 检查 Sing-box 是否安装
if [[ ! -f "/usr/local/bin/sing-box" ]]; then
    echo -e "${RED}错误: 未检测到 Sing-box 核心，请先安装核心环境！${PLAIN}"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    apt update -y && apt install -y jq
fi

echo -e "${GREEN}>>> 正在配置 Sing-box AnyTLS + Reality 节点...${PLAIN}"

# 2. 获取用户输入
# ------------------------------------------------
# 端口
while true; do
    read -p "请输入节点端口 (默认 8443): " PORT
    [[ -z "$PORT" ]] && PORT="8443"
    if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
        # 简单检查端口占用 (仅供参考)
        if ss -tuln | grep -q ":$PORT "; then
            echo -e "${RED}警告: 端口 $PORT 似乎已被占用，请更换。${PLAIN}"
        else
            break
        fi
    else
        echo -e "${RED}无效端口，请输入 1-65535 之间的数字。${PLAIN}"
    fi
done

# 目标网站 (Dest/SNI)
read -p "请输入 Reality 偷取的目标域名 (默认 www.apple.com): " DEST_DOMAIN
[[ -z "$DEST_DOMAIN" ]] && DEST_DOMAIN="www.apple.com"

# 密码 (AnyTLS 使用 password 而不是 UUID)
read -p "请输入连接密码 (留空随机生成): " USER_PASS
if [[ -z "$USER_PASS" ]]; then
    USER_PASS=$(openssl rand -base64 16)
fi

# 别名
read -p "请为节点起个别名 (默认 sb-anytls): " NODE_TAG
[[ -z "$NODE_TAG" ]] && NODE_TAG="sb-anytls"

# 3. 生成 Reality 密钥对
# ------------------------------------------------
echo -e "${YELLOW}正在生成 Reality 密钥...${PLAIN}"
KEY_PAIR=$(/usr/local/bin/sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "PublicKey" | awk '{print $2}')
SHORT_ID=$(/usr/local/bin/sing-box generate rand --hex 8)

if [[ -z "$PRIVATE_KEY" ]]; then
    echo -e "${RED}错误: Reality 密钥生成失败！${PLAIN}"
    exit 1
fi

echo -e "Private Key: ${SKYBLUE}$PRIVATE_KEY${PLAIN}"
echo -e "Public Key:  ${SKYBLUE}$PUBLIC_KEY${PLAIN}"
echo -e "Short ID:    ${SKYBLUE}$SHORT_ID${PLAIN}"

# 4. 写入配置文件 (JSON 操作)
# ------------------------------------------------
echo -e "${YELLOW}正在写入配置文件...${PLAIN}"

# 构造 AnyTLS 入站配置
# 注意：AnyTLS 是一个独立的 type，不是 VLESS 的 transport
NEW_INBOUND=$(jq -n \
    --arg tag "$NODE_TAG" \
    --arg port "$PORT" \
    --arg pass "$USER_PASS" \
    --arg dest "$DEST_DOMAIN" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    '{
        "type": "anytls",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [
            {
                "name": "user",
                "password": $pass
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

# 将新入站插入配置
# 如果 config.json 不存在或不合法，先创建一个空的骨架
if [[ ! -f "$CONF_FILE" ]] || [[ $(cat "$CONF_FILE") == "" ]]; then
    echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$CONF_FILE"
fi

# 使用 jq 将新 inbound 加入 inbound 列表
TEMP_JSON=$(mktemp)
jq --argjson new "$NEW_INBOUND" '.inbounds += [$new]' "$CONF_FILE" > "$TEMP_JSON" && mv "$TEMP_JSON" "$CONF_FILE"

# 5. 重启服务
# ------------------------------------------------
echo -e "${YELLOW}正在重启 Sing-box 服务...${PLAIN}"
systemctl restart sing-box

if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}节点添加成功！${PLAIN}"
    
    # 获取本机 IP
    IPV4=$(curl -s4m5 https://api.ip.sb/ip || echo "你的IP")
    
    # 6. 输出客户端配置 (AnyTLS 没有标准链接格式，推荐复制 JSON)
    echo -e "===================================================="
    echo -e "       ${SKYBLUE}Sing-box AnyTLS + Reality 节点配置${PLAIN}"
    echo -e "===================================================="
    echo -e "${YELLOW}注意：AnyTLS 是 Sing-box 专属协议，请直接复制下方 JSON 到客户端 (如 GUI 客户端或手动配置)${PLAIN}"
    echo -e ""
    echo -e "${GREEN}{"
    echo -e "  \"type\": \"anytls\","
    echo -e "  \"tag\": \"$NODE_TAG-out\","
    echo -e "  \"server\": \"$IPV4\","
    echo -e "  \"server_port\": $PORT,"
    echo -e "  \"password\": \"$USER_PASS\","
    echo -e "  \"tls\": {"
    echo -e "    \"enabled\": true,"
    echo -e "    \"server_name\": \"$DEST_DOMAIN\","
    echo -e "    \"utls\": {"
    echo -e "      \"enabled\": true,"
    echo -e "      \"fingerprint\": \"chrome\""
    echo -e "    },"
    echo -e "    \"reality\": {"
    echo -e "      \"enabled\": true,"
    echo -e "      \"public_key\": \"$PUBLIC_KEY\","
    echo -e "      \"short_id\": \"$SHORT_ID\""
    echo -e "    }"
    echo -e "  }"
    echo -e "}${PLAIN}"
    echo -e ""
    echo -e "===================================================="
    echo -e "提示: 客户端需要 Sing-box v1.12.0 或更高版本"
else
    echo -e "${RED}服务启动失败！${PLAIN}"
    echo -e "请检查日志: journalctl -u sing-box -e"
fi
