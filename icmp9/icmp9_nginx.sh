#!/bin/bash
echo "版本v3.0"
sleep 2
# ============================================================
# ICMP9 Nginx 透明转发脚本 (v3.0 智能容错版)
# 修复: 自动过滤 API 返回的状态码/布尔值 (解决 jq 报错)
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
DEFAULT_UPSTREAM="tunnel-na.8443.buzz"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1
mkdir -p "$WORK_DIR"

init_system() {
    echo -e "${GREEN}>>> [1/4] 初始化环境...${PLAIN}"
    if ! command -v nginx &> /dev/null || ! command -v jq &> /dev/null; then
        apt-get update -y && apt-get install -y nginx jq curl coreutils
    fi
    rm -f /etc/nginx/sites-enabled/default
}

configure_upstream() {
    echo -e "${GREEN}>>> [2/4] 配置上游入口域名...${PLAIN}"
    if [ -f "$CONFIG_ENV" ]; then source "$CONFIG_ENV"; fi
    API_HOST=$(curl -s -m 5 "$API_CONFIG" | grep -oP '(?<=Address: ).*' | head -n 1)
    RECOMMEND_HOST="${Saved_Host:-${API_HOST:-$DEFAULT_UPSTREAM}}"

    echo -e "------------------------------------------------"
    echo -e "推荐上游入口: ${SKYBLUE}${RECOMMEND_HOST}${PLAIN}"
    echo -e "------------------------------------------------"
    read -p "是否使用此域名？[y/n] (默认: y): " use_rec
    use_rec=${use_rec:-y}

    if [[ "$use_rec" == "y" ]]; then FINAL_HOST="$RECOMMEND_HOST"; else
        read -p "请输入入口域名: " user_input
        FINAL_HOST="${user_input:-$DEFAULT_UPSTREAM}"
    fi
    echo "Saved_Host=\"$FINAL_HOST\"" > "$CONFIG_ENV"
}

setup_nginx() {
    echo -e "${GREEN}>>> [3/4] 生成 Nginx 反代配置...${PLAIN}"
    read -p "Nginx 本地监听端口 [默认 8080]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-8080}
    
    NODES_JSON=$(curl -s "$API_NODES")
    if [[ -z "$NODES_JSON" ]]; then echo -e "${RED}API 请求失败！${PLAIN}" && exit 1; fi

    cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$LISTEN_PORT;
    server_name localhost;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    location / { return 404; }
EOF

    # === 关键修复开始 ===
    # 逻辑说明:
    # 1. (.data // .nodes // .) : 尝试从 data 或 nodes 字段读取，如果都没有就读取根对象
    # 2. if type=="array" ... : 确保传递给下游的是数组
    # 3. select(.["ws-opts"] != null) : 核心过滤，排除掉状态码、布尔值等垃圾数据
    # ====================
    for node in $(echo "$NODES_JSON" | jq -r '(.data // .nodes // .) | if type=="array" then .[] else empty end | select(.["ws-opts"] != null) | @base64'); do
        _node=$(echo "$node" | base64 -d)
        path=$(echo "$_node" | jq -r '.["ws-opts"].path')
        name=$(echo "$_node" | jq -r '.name')

        cat >> "$NGINX_CONF" <<EOF
    # $name
    location $path {
        proxy_pass https://$FINAL_HOST;
        proxy_ssl_server_name on;
        proxy_ssl_name $FINAL_HOST;
        proxy_set_header Host $FINAL_HOST;
    }
EOF
    done

    echo "}" >> "$NGINX_CONF"
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    
    nginx -t > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        systemctl restart nginx
        echo -e "${GREEN}Nginx 已启动 (Port: $LISTEN_PORT)${PLAIN}"
    else
        echo -e "${RED}Nginx 验证失败！可能是 API 数据为空。${PLAIN}"
        exit 1
    fi
}

generate_links() {
    echo -e "${GREEN}>>> [4/4] 生成分享链接...${PLAIN}"
    read -p "请输入你的公网 Argo 域名: " USER_ARGO_DOMAIN
    if [[ -z "$USER_ARGO_DOMAIN" ]]; then echo -e "${RED}域名为空，退出。${PLAIN}" && exit 1; fi

    > "$OUTPUT_FILE"
    echo -e "\n${SKYBLUE}------ 节点列表 ------${PLAIN}"
    
    # === 关键修复: 同步应用过滤逻辑 ===
    for node in $(echo "$NODES_JSON" | jq -r '(.data // .nodes // .) | if type=="array" then .[] else empty end | select(.["ws-opts"] != null) | @base64'); do
        _node=$(echo "$node" | base64 -d)
        
        ORIGIN_NAME=$(echo "$_node" | jq -r '.name')
        NODE_ALIAS="[Argo] $ORIGIN_NAME"
        REAL_UUID=$(echo "$_node" | jq -r '.uuid')
        REAL_PATH=$(echo "$_node" | jq -r '.["ws-opts"].path')

        VMESS_JSON=$(jq -n \
            --arg v "2" \
            --arg ps "$NODE_ALIAS" \
            --arg add "$USER_ARGO_DOMAIN" \
            --arg port "443" \
            --arg id "$REAL_UUID" \
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
}

init_system
configure_upstream
setup_nginx
generate_links
