#!/bin/bash

# ============================================================
#  模块二：VLESS + XHTTP + Reality (v1.1 Auto)
#  - 协议: XHTTP (Xray 新一代传输协议)
#  - 升级: 支持 auto_deploy.sh 自动化调用
#  - 修复: Tag + Port 双重清理
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"

echo -e "${GREEN}>>> [Xray] 智能添加节点: VLESS + Reality + XHTTP ...${PLAIN}"

# 1. 环境准备
if [[ ! -f "$XRAY_BIN" ]]; then echo -e "${RED}错误: 未找到 Xray 核心！${PLAIN}"; exit 1; fi
if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then apt update -y && apt install -y jq openssl; fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"blocked","protocol":"blackhole"}],"routing":{"rules":[]}}' > "$CONFIG_FILE"
fi

# 2. 参数获取
if [[ "$AUTO_SETUP" == "true" ]]; then
    echo -e "${GREEN}>>> [自动模式] 读取参数...${PLAIN}"
    PORT=${XRAY_XHTTP_PORT:-2053}
    SNI=${XRAY_XHTTP_SNI:-"www.sony.jp"}
else
    echo -e "${YELLOW}--- 配置 XHTTP Reality ---${PLAIN}"
    while true; do
        read -p "请输入监听端口 (默认 2053): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=2053 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else echo -e "${RED}无效端口。${PLAIN}"; fi
    done

    echo -e "${YELLOW}请选择伪装域名 (SNI):${PLAIN}"
    echo -e "  1. www.sony.jp (默认)"
    echo -e "  2. updates.cdn-apple.com"
    echo -e "  3. 手动输入"
    read -p "选择: " s
    case $s in
        2) SNI="updates.cdn-apple.com" ;;
        3) read -p "输入域名: " SNI; [[ -z "$SNI" ]] && SNI="www.sony.jp" ;;
        *) SNI="www.sony.jp" ;;
    esac
fi

# 3. 密钥生成
UUID=$($XRAY_BIN uuid)
SHORT_ID=$(openssl rand -hex 4)
XHTTP_PATH="/$(openssl rand -hex 4)"
RAW_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "Private" | awk -F ":" '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep -E "Password|Public" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# 4. 核心执行
NODE_TAG="Xray-XHTTP-${PORT}"

# [修复] Tag + Port 双重清理
tmp0=$(mktemp)
jq --argjson p "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.port == $p or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

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
        xhttpSettings: {path: $path},
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

tmp=$(mktemp)
jq --argjson new "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 5. 重启与输出
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_TAG}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [Xray] XHTTP Reality 部署成功！     ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"

    if [[ "$AUTO_SETUP" == "true" ]]; then
        LOG_FILE="/root/xray_nodes.txt"
        echo "Tag: ${NODE_TAG} | ${SHARE_LINK}" >> "$LOG_FILE"
        echo -e "${SKYBLUE}>>> [自动记录] 已追加至: ${LOG_FILE}${PLAIN}"
    fi
else
    echo -e "${RED}启动失败！journalctl -u xray -e${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
