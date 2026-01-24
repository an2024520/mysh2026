#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + WS + TLS (CDN)
#  版本: v1.4 (修复端口自定义问题)
#  - 模式: 交互式导入证书
#  - 修复: 增加端口交互输入，支持 Cloudflare Origin Rules 指定端口
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

echo "安装依赖JQ"
if [[ -n $(command -v apt-get) ]]; then
    apt-get update && apt-get install -y jq
elif [[ -n $(command -v yum) ]]; then
    yum install -y jq
fi

echo -e "${GREEN}>>> [Sing-box] 新增节点: VLESS + WS + TLS (CDN) ...${PLAIN}"

# --- 1. 环境准备 ---
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done
[[ -z "$CONFIG_FILE" ]] && CONFIG_FILE="/usr/local/etc/sing-box/config.json"

if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: 未安装 jq，请先安装 (apt install jq / yum install jq)${PLAIN}"
    exit 1
fi

# --- 2. 证书路径获取 (交互/自动) ---
input_cert_paths() {
    local info_file="/etc/acme_info"
    local def_cert=""
    local def_key=""
    local def_domain=""

    if [[ -f "$info_file" ]]; then
        source "$info_file"
        def_cert="$CERT_PATH"
        def_key="$KEY_PATH"
        def_domain="$DOMAIN"
    fi

    echo -e "\n${YELLOW}--- 证书配置 ---${PLAIN}"
    
    # 域名输入
    if [[ -n "$def_domain" ]]; then
        read -p "请输入节点域名 [默认: $def_domain]: " input_domain
        DOMAIN="${input_domain:-$def_domain}"
    else
        read -p "请输入节点域名: " DOMAIN
    fi
    [[ -z "$DOMAIN" ]] && echo -e "${RED}域名不能为空!${PLAIN}" && exit 1

    # 证书公钥路径
    if [[ -n "$def_cert" ]]; then
        echo -e "检测到默认证书: ${SKYBLUE}$def_cert${PLAIN}"
        read -p "使用该路径? [y/n/自定义路径]: " cert_choice
        if [[ "$cert_choice" == "y" || "$cert_choice" == "Y" || -z "$cert_choice" ]]; then
            CERT_PATH="$def_cert"
        else
            CERT_PATH="$cert_choice"
        fi
    else
        read -p "请输入证书文件(.crt/.cer) 绝对路径: " CERT_PATH
    fi

    # 证书私钥路径
    if [[ -n "$def_key" ]]; then
        echo -e "检测到默认私钥: ${SKYBLUE}$def_key${PLAIN}"
        read -p "使用该路径? [y/n/自定义路径]: " key_choice
        if [[ "$key_choice" == "y" || "$key_choice" == "Y" || -z "$key_choice" ]]; then
            KEY_PATH="$def_key"
        else
            KEY_PATH="$key_choice"
        fi
    else
        read -p "请输入私钥文件(.key) 绝对路径: " KEY_PATH
    fi

    if [[ ! -f "$CERT_PATH" ]]; then
        echo -e "${RED}错误: 找不到证书文件: $CERT_PATH${PLAIN}"
        exit 1
    fi
    if [[ ! -f "$KEY_PATH" ]]; then
        echo -e "${RED}错误: 找不到私钥文件: $KEY_PATH${PLAIN}"
        exit 1
    fi
}

# --- 3. 配置参数生成 ---
input_cert_paths

UUID=$(cat /proc/sys/kernel/random/uuid)

# [修复] 端口交互逻辑
echo -e "\n${YELLOW}--- 端口配置 ---${PLAIN}"
read -p "请输入节点监听端口 (留空则随机 10000-60000): " input_port

if [[ -n "$input_port" ]]; then
    # 用户指定端口
    PORT="$input_port"
    # 简单检查占用 (非强制)
    if netstat -tuln | grep -q ":$PORT "; then
        echo -e "${RED}警告: 端口 $PORT 似乎已被占用!${PLAIN}"
        read -p "是否强制使用? [y/N]: " force_opt
        if [[ "$force_opt" != "y" && "$force_opt" != "Y" ]]; then
            echo "操作取消。" && exit 1
        fi
    fi
else
    # 随机端口 (保留原逻辑)
    PORT=$(shuf -i 10000-60000 -n 1)
    while netstat -tuln | grep -q ":$PORT "; do
        PORT=$(shuf -i 10000-60000 -n 1)
    done
fi

WS_PATH="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)"
NODE_TAG="TLS-WS-${PORT}"

# --- 4. 注入配置文件 ---
echo -e "${GREEN}>>> 正在写入配置文件...${PLAIN}"

# 构造 Inbound JSON
NODE_JSON=$(jq -n \
    --arg tag "$NODE_TAG" \
    --arg port "$PORT" \
    --arg uuid "$UUID" \
    --arg path "$WS_PATH" \
    --arg host "$DOMAIN" \
    --arg cert "$CERT_PATH" \
    --arg key "$KEY_PATH" \
    '{
        "type": "vless",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [
            {
                "uuid": $uuid,
                "flow": ""
            }
        ],
        "transport": {
            "type": "ws",
            "path": $path,
            "headers": {
                "Host": $host
            }
        },
        "tls": {
            "enabled": true,
            "server_name": $host,
            "certificate_path": $cert,
            "key_path": $key
        }
    }')

tmp=$(mktemp)
# 核心修复: 将 $new_node 改为 $new
jq --argjson new "$NODE_JSON" '.inbounds = (.inbounds // []) + [$new]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# --- 5. 重启与输出 ---
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    # 获取公网IP (IPv4 优先，失败降级到 IPv6)
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s6m5 https://api.ip.sb/ip)
    
    # 链接中 security=tls
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=tls&encryption=none&type=ws&path=${WS_PATH}&sni=${DOMAIN}&fp=chrome#${NODE_TAG}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}  [Sing-box] WS+TLS (CDN) 部署成功！    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "绑定域名    : ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "证书路径    : ${CERT_PATH}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "注意: 若使用了 Cloudflare Origin Rules，请确保端口与规则一致。"
else
    echo -e "${RED}部署失败: Sing-box 服务未启动，请检查日志 (journalctl -u sing-box -e)${PLAIN}"
fi