#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + Vision + Reality (v2.2 Debug)
#  - 修复: 增加详细的调试日志，定位 .meta 文件写入失败原因
#  - 优化: 强化密钥生成的容错检查
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + Vision + Reality (Debug Mode)...${PLAIN}"

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
    echo -e "${RED}错误: 未找到 Sing-box 配置文件！${PLAIN}"
    exit 1
fi

CONFIG_DIR=$(dirname "$CONFIG_FILE")
META_FILE="${CONFIG_FILE}.meta" 
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"
echo -e "${YELLOW}>>> [Debug] 伴生文件路径应为: ${META_FILE}${PLAIN}"

# 2. 依赖检查
if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}安装必要工具 (jq, openssl)...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y jq openssl
    elif [ -f /etc/redhat-release ]; then
        yum install -y jq openssl
    fi
fi

# 3. 参数配置
# ------------------------------------------------
# A. 端口
while true; do
    read -p "请输入监听端口 (默认 443): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=443 && break
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        PORT="$CUSTOM_PORT"
        break
    else
        echo -e "${RED}无效端口。${PLAIN}"
    fi
done

# B. 伪装域名
echo -e "${YELLOW}请选择伪装域名 (SNI):${PLAIN}"
echo -e "  1. www.microsoft.com (默认)"
echo -e "  2. www.apple.com"
echo -e "  3. 手动输入"
read -p "选择 [1-3]: " SNI_CHOICE
case $SNI_CHOICE in
    2) SNI="www.apple.com" ;;
    3) read -p "输入域名: " SNI ;;
    *) SNI="www.microsoft.com" ;;
esac

# 4. 生成密钥 (带 Debug)
# ------------------------------------------------
echo -e "${YELLOW}正在生成密钥与 UUID...${PLAIN}"
UUID=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
KEY_PAIR=$($SB_BIN generate reality-keypair 2>/dev/null)

if [[ -z "$KEY_PAIR" ]]; then
    echo -e "${RED}>>> [Debug] Sing-box 核心无法生成密钥，尝试 fallback...${PLAIN}"
    PRIVATE_KEY=$(openssl rand -base64 32 | tr -d /=+ | head -c 43)
    # 如果无法生成 Reality 密钥对，查看脚本将无法工作，必须报错
    echo -e "${RED}严重错误: 无法调用 sing-box 生成 Reality 密钥对！${PLAIN}"
    echo -e "检测到的 sing-box 路径: $SB_BIN"
    exit 1
else
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "PrivateKey" | awk '{print $2}' | tr -d ' "')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "PublicKey" | awk '{print $2}' | tr -d ' "')
    echo -e "${GREEN}>>> [Debug] 密钥生成成功。${PLAIN}"
    echo -e "${GREEN}>>> [Debug] Public Key: ${PUBLIC_KEY}${PLAIN}"
fi
SHORT_ID=$(openssl rand -hex 8)

# 5. 写入配置
# ------------------------------------------------
NODE_TAG="Vision-${PORT}"

echo -e "${YELLOW}正在写入配置...${PLAIN}"

# A. 清理冲突端口
tmp_clean=$(mktemp)
jq --argjson port "$PORT" 'del(.inbounds[]? | select(.listen_port == $port))' "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# B. 构造 Inbound JSON
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
        "users": [{ "uuid": $uuid, "flow": "xtls-rprx-vision" }],
        "tls": {
            "enabled": true,
            "server_name": $dest,
            "reality": {
                "enabled": true,
                "handshake": { "server": $dest, "server_port": 443 },
                "private_key": $pk,
                "short_id": [$sid]
            }
        }
    }')

# C. 写入 config.json
tmp_add=$(mktemp)
jq --argjson new "$NODE_JSON" 'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new]' "$CONFIG_FILE" > "$tmp_add" 

if [ $? -eq 0 ]; then
    mv "$tmp_add" "$CONFIG_FILE"
    echo -e "${GREEN}>>> [Debug] config.json 写入成功。${PLAIN}"
else
    echo -e "${RED}>>> [Debug] config.json 写入失败 (jq 错误)。${PLAIN}"
    exit 1
fi

# D. 写入伴生元数据 (强制 Debug)
# ------------------------------------------------
echo -e "${YELLOW}正在写入伴生文件: ${META_FILE} ...${PLAIN}"

# 1. 确保文件存在
if [[ ! -f "$META_FILE" ]]; then 
    echo "{}" > "$META_FILE"
    if [ $? -ne 0 ]; then
        echo -e "${RED}>>> [Debug] 创建 meta 文件失败！检查权限？${PLAIN}"
        ls -ld "$CONFIG_DIR"
    else
        echo -e "${GREEN}>>> [Debug] meta 文件初始化完成。${PLAIN}"
    fi
fi

# 2. 执行 jq 写入
tmp_meta=$(mktemp)
jq --arg tag "$NODE_TAG" --arg pbk "$PUBLIC_KEY" --arg sid "$SHORT_ID" --arg sni "$SNI" \
   '. + {($tag): {"pbk": $pbk, "sid": $sid, "sni": $sni}}' "$META_FILE" > "$tmp_meta"

if [ $? -eq 0 ]; then
    mv "$tmp_meta" "$META_FILE"
    echo -e "${GREEN}>>> [Debug] 元数据写入成功！${PLAIN}"
    echo -e "${GREEN}>>> [Debug] 当前 meta 文件内容:${PLAIN}"
    cat "$META_FILE"
else
    echo -e "${RED}>>> [Debug] 元数据写入失败！(jq 报错)${PLAIN}"
    echo -e "尝试写入的内容: Tag=$NODE_TAG, PBK=$PUBLIC_KEY"
fi

# 6. 重启服务
# ------------------------------------------------
systemctl restart sing-box
sleep 1

if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}配置写入并重启成功！${PLAIN}"
    echo -e "节点 Tag: ${SKYBLUE}$NODE_TAG${PLAIN} (已存入 Inbounds)"
else
    echo -e "${RED}服务启动失败，请检查日志。${PLAIN}"
fi
