#!/bin/bash

# ============================================================
# ICMP9 Nginx 透明转发脚本 (v6.0 最终修正版)
# 修复: 正确解析 online.php 的 countries 结构
# 修复: 手动拼接 Path (/$code) 和注入用户 UUID
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

WORK_DIR="/etc/icmp9_relay"
CONFIG_ENV="$WORK_DIR/config.env"
NGINX_CONF="/etc/nginx/sites-available/icmp9_relay"
OUTPUT_FILE="/root/icmp9_vmess.txt"

# API 地址
API_NODES="https://api.icmp9.com/online.php"
API_CONFIG="https://api.icmp9.com/config/config.txt"
HARD_FALLBACK="tunnel-na.8443.buzz"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1
mkdir -p "$WORK_DIR"

init_system() {
    echo -e "${GREEN}>>> [1/5] 初始化环境...${PLAIN}"
    if ! command -v nginx &> /dev/null || ! command -v jq &> /dev/null; then
        apt-get update -y && apt-get install -y nginx jq curl coreutils
    fi
    rm -f /etc/nginx/sites-enabled/default
}

# ============================================================
# 2. 获取 ICMP9 账户信息 (新增)
# ============================================================
get_user_info() {
    echo -e "${GREEN}>>> [2/5] 配置账户信息...${PLAIN}"
    
    # 1. 获取 UUID (Key)
    if [ -f "$CONFIG_ENV" ]; then source "$CONFIG_ENV"; fi
    
    if [[ -n "$Saved_UUID" ]]; then
        read -p "使用已保存的 UUID ($Saved_UUID)? [y/n]: " use_saved
        if [[ "$use_saved" == "n" ]]; then
            read -p "请输入你的 ICMP9 Key (UUID): " USER_UUID
        else
            USER_UUID="$Saved_UUID"
        fi
    else
        read -p "请输入你的 ICMP9 Key (UUID): " USER_UUID
    fi
    
    if [[ -z "$USER_UUID" ]]; then echo -e "${RED}UUID 不能为空！${PLAIN}" && exit 1; fi
    
    # 保存配置
    echo "Saved_UUID=\"$USER_UUID\"" > "$CONFIG_ENV"
}

# ============================================================
# 3. 配置上游入口 (逻辑保持 v5)
# ============================================================
configure_upstream() {
    echo -e "${GREEN}>>> [3/5] 配置上游入口域名...${PLAIN}"
    if [ -f "$CONFIG_ENV" ]; then source "$CONFIG_ENV"; fi
    
    HINT="[回车自动获取]"
    [[ -n "$Saved_Host" ]] && HINT="[回车复用: $Saved_Host]"

    read -p "请输入入口域名 $HINT: " USER_INPUT

    if [[ -n "$USER_INPUT" ]]; then
        FINAL_HOST="$USER_INPUT"
    elif [[ -n "$Saved_Host" ]]; then
        FINAL_HOST="$Saved_Host"
    else
        echo -e "${YELLOW}正在获取最新入口...${PLAIN}"
        RAW_CFG=$(curl -s -m 5 "$API_CONFIG")
        API_HOST=$(echo "$RAW_CFG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
        FINAL_HOST="${API_HOST:-$HARD_FALLBACK}"
    fi

    echo -e "${GREEN}>>> 已锁定上游: $FINAL_HOST${PLAIN}"
    echo "Saved_Host=\"$FINAL_HOST\"" >> "$CONFIG_ENV"
}

# ============================================================
# 4. 配置 Nginx (简化版)
# ============================================================
setup_nginx() {
    echo -e "${GREEN}>>> [4/5] 生成 Nginx 配置...${PLAIN}"
    read -p "Nginx 本地监听端口 [默认 8080]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-8080}

    # 使用通配 Location /，自动透传所有子路径 (如 /us, /jp)
    # 这样无需遍历 API 就能生成正确的 Nginx 配置
    cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$LISTEN_PORT;
    server_name localhost;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    # 通配转发: 访问 /us -> https://$FINAL_HOST/us
    location / {
        proxy_pass https://$FINAL_HOST;
        proxy_ssl_server_name on;
        proxy_ssl_name $FINAL_HOST;
        proxy_set_header Host $FINAL_HOST;
    }
}
EOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    nginx -t > /dev/null 2>&1
    systemctl restart nginx
    echo -e "${GREEN}Nginx 已启动 (Port: $LISTEN_PORT)${PLAIN}"
}

# ============================================================
# 5. 生成链接 (修正 JQ 逻辑)
# ============================================================
generate_links() {
    echo -e "${GREEN}>>> [5/5] 生成分享链接...${PLAIN}"
    read -p "请输入你的公网 Argo 域名: " USER_ARGO_DOMAIN
    if [[ -z "$USER_ARGO_DOMAIN" ]]; then echo -e "${RED}域名为空！${PLAIN}" && exit 1; fi

    NODES_JSON=$(curl -s "$API_NODES")
    if [[ -z "$NODES_JSON" ]]; then echo -e "${RED}API 获取失败，无法生成列表。${PLAIN}" && exit 1; fi

    > "$OUTPUT_FILE"
    echo -e "\n${SKYBLUE}------ 节点列表 ------${PLAIN}"

    # 修正点: 遍历 .countries[]，并手动拼接 path
    for node in $(echo "$NODES_JSON" | jq -r '.countries[] | @base64'); do
        _node=$(echo "$node" | base64 -d)
        
        CODE=$(echo "$_node" | jq -r '.code')
        NAME=$(echo "$_node" | jq -r '.name')
        EMOJI=$(echo "$_node" | jq -r '.emoji')
        
        # 核心修正: 路径 = / + code
        REAL_PATH="/${CODE}"
        NODE_ALIAS="[Argo] ${EMOJI} ${NAME}"

        # JSON 构建: 使用用户输入的 UUID (USER_UUID)
        VMESS_JSON=$(jq -n \
            --arg v "2" \
            --arg ps "$NODE_ALIAS" \
            --arg add "$USER_ARGO_DOMAIN" \
            --arg port "443" \
            --arg id "$USER_UUID" \
            --arg net "ws" \
            --arg type "none" \
            --arg host "$USER_ARGO_DOMAIN" \
            --arg path "$REAL_PATH" \
            --arg tls "tls" \
            --arg sni "$USER_ARGO_DOMAIN" \
            --arg fp "chrome" \
            '{v:$v, ps:$ps, add:$add, port:$port, id:$id, net:$net, type:$type, host:$host, path:$path, tls:$tls, sni:$sni, fp:$fp}')

        LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
        echo "$LINK" >> "$OUTPUT_FILE"
        echo -e "${GREEN}${NODE_ALIAS}${PLAIN}\n$LINK\n"
    done

    echo -e "已保存至: ${YELLOW}$OUTPUT_FILE${PLAIN}"
    echo -e "请在客户端使用该文件导入，或直接复制上方链接。"
}

init_system
get_user_info
configure_upstream
setup_nginx
generate_links
