#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + Vision + Reality (v3.1 Auto)
#  - 核心: 自动识别路径 + 写入 Inbounds + 保存公钥到 .meta
#  - 特性: 自动/手动逻辑完全隔离 (双轨制)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + Vision + Reality ...${PLAIN}"

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

# 3. 初始化配置文件
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}配置文件不存在，正在初始化标准骨架...${PLAIN}"
    mkdir -p "$CONFIG_DIR"
    cat <<EOF > "$CONFIG_FILE"
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

# 4. 用户配置参数 (核心修改区域：双轨逻辑)
echo -e "${YELLOW}--- 配置 VLESS (Vision) 节点参数 ---${PLAIN}"

if [[ "$AUTO_SETUP" == "true" ]]; then
    # >>>>>>>>>> 自动模式通道 (变量优先) >>>>>>>>>>
    echo -e "${GREEN}>>> 检测到自动部署模式...${PLAIN}"
    
    # [1. 端口]
    if [[ -n "$PORT" ]]; then
        echo -e "端口: ${GREEN}[继承外部]${PLAIN} $PORT"
    else
        PORT=443
        echo -e "端口: ${GREEN}[自动默认]${PLAIN} 443"
    fi

    # [2. SNI]
    if [[ -n "$REALITY_DOMAIN" ]]; then
        SNI="$REALITY_DOMAIN"
        echo -e "SNI : ${GREEN}[继承外部]${PLAIN} $SNI"
    else
        SNI="updates.cdn-apple.com"
        echo -e "SNI : ${GREEN}[自动默认]${PLAIN} $SNI"
    fi
    
    # [3. UUID - 自动模式特有逻辑]
    if [[ -n "$UUID" ]]; then
        echo -e "UUID: ${GREEN}[继承外部]${PLAIN} $UUID"
    else
        UUID=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        echo -e "UUID: ${GREEN}[随机生成]${PLAIN} $UUID"
    fi
    
    # 自动模式跳过连通性检查交互
    if ! curl -s -I --max-time 5 "https://$SNI" >/dev/null; then
        echo -e "${YELLOW}[警告] 无法连接到 $SNI，但自动模式下强制继续。${PLAIN}"
    fi

else
    # >>>>>>>>>> 手动模式通道 (保持 100% 原有交互) >>>>>>>>>>
    
    # [A. 端口]
    while true; do
        read -p "请输入监听端口 (推荐 443, 2053, 默认 443): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=443 && break
        
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

    # [B. SNI]
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
    
    # [C. UUID - 手动模式特有逻辑]
    # 原有逻辑就是直接随机，不询问
    UUID=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)

    # [D. 连通性校验]
    echo -e "${YELLOW}正在检查连通性: $SNI ...${PLAIN}"
    if ! curl -s -I --max-time 5 "https://$SNI" >/dev/null; then
        echo -e "${RED}警告: 无法连接到 $SNI。建议更换。${PLAIN}"
        read -p "是否强制继续? (y/n): " FORCE
        [[ "$FORCE" != "y" ]] && exit 1
    fi
fi

# 5. 生成密钥
echo -e "${YELLOW}正在生成密钥...${PLAIN}"
KEY_PAIR=$($SB_BIN generate reality-keypair 2>/dev/null)

if [[ -z "$KEY_PAIR" ]]; then
    PRIVATE_KEY=$(openssl rand -base64 32 | tr -d /=+ | head -c 43)
    PUBLIC_KEY="GenerateFailed"
    echo -e "${RED}警告: 核心生成密钥失败，尝试使用 OpenSSL 回退。${PLAIN}"
else
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "PrivateKey" | awk '{print $2}' | tr -d ' "')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "PublicKey" | awk '{print $2}' | tr -d ' "')
fi
SHORT_ID=$(openssl rand -hex 8)

# 6. 构建与注入节点
echo -e "${YELLOW}正在更新配置文件...${PLAIN}"

NODE_TAG="Vision-${PORT}"

# === 步骤 1: 强制日志托管 ===
tmp_log=$(mktemp)
jq '.log.output = "" | .log.timestamp = false' "$CONFIG_FILE" > "$tmp_log" && mv "$tmp_log" "$CONFIG_FILE"

# === 步骤 2: 端口霸占清理 ===
tmp0=$(mktemp)
jq --argjson port "$PORT" 'del(.inbounds[]? | select(.listen_port == $port))' "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

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
jq --argjson new_node "$NODE_JSON" 'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# === 步骤 4: 写入伴生元数据 ===
if [[ ! -f "$META_FILE" ]]; then echo "{}" > "$META_FILE"; fi
tmp_meta=$(mktemp)
jq --arg tag "$NODE_TAG" --arg pbk "$PUBLIC_KEY" --arg sid "$SHORT_ID" --arg sni "$SNI" \
   '. + {($tag): {"pbk": $pbk, "sid": $sid, "sni": $sni}}' "$META_FILE" > "$tmp_meta" && mv "$tmp_meta" "$META_FILE"

# 7. 重启与输出
echo -e "${YELLOW}正在重启服务...${PLAIN}"
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    NODE_NAME="$NODE_TAG"
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [Sing-box] 节点已追加/更新成功！    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "SNI (伪装)  : ${YELLOW}${SNI}${PLAIN}"
    echo -e "UUID        : ${SKYBLUE}${UUID}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # 自动化模式下，将链接追加到日志文件
    if [[ "$AUTO_SETUP" == "true" ]]; then
        echo "${SHARE_LINK}" >> /root/sb_nodes.txt
    fi
    
    # 手动模式下才显示详细配置块
    if [[ "$AUTO_SETUP" != "true" ]]; then
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
    fi
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u sing-box -e${PLAIN}"
fi
