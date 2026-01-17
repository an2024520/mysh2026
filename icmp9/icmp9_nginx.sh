#!/bin/bash

# ============================================================
# ICMP9 Nginx 透明转发脚本 (轻量化重构版)
# 适用环境: Debian/Ubuntu, 128M/256M/512M VPS
# 核心功能: 
#   1. 动态拉取节点 Path/UUID
#   2. 生成 Nginx 反代配置 (WebSocket)
#   3. 输出适配 Argo 隧道的 VMess 链接
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 配置文件与路径
WORK_DIR="/etc/icmp9_relay"
CONFIG_ENV="$WORK_DIR/config.env"
NGINX_CONF="/etc/nginx/sites-available/icmp9_relay"
OUTPUT_FILE="/root/icmp9_vmess.txt"

# API 地址
API_NODES="https://api.icmp9.com/online.php"
API_CONFIG="https://api.icmp9.com/config/config.txt"
DEFAULT_UPSTREAM="tunnel-na.8443.buzz" # 保底值

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

mkdir -p "$WORK_DIR"

# ============================================================
# 1. 环境准备
# ============================================================
init_system() {
    echo -e "${GREEN}>>> [1/4] 初始化环境...${PLAIN}"
    
    # 安装必要依赖
    if ! command -v nginx &> /dev/null || ! command -v jq &> /dev/null; then
        apt-get update -y
        apt-get install -y nginx jq curl coreutils
    fi

    # 简单清理默认 Nginx 配置，防止冲突
    rm -f /etc/nginx/sites-enabled/default
}

# ============================================================
# 2. 确定上游入口域名 (Upstream Host)
# ============================================================
configure_upstream() {
    echo -e "${GREEN}>>> [2/4] 配置上游入口域名...${PLAIN}"

    # 1. 读取历史配置
    if [ -f "$CONFIG_ENV" ]; then source "$CONFIG_ENV"; fi

    # 2. 尝试从 API 获取最新入口 (作为参考)
    API_HOST=$(curl -s -m 5 "$API_CONFIG" | grep -oP '(?<=Address: ).*' | head -n 1)
    
    # 3. 确定推荐值 (历史 > API > 默认)
    RECOMMEND_HOST="${Saved_Host:-${API_HOST:-$DEFAULT_UPSTREAM}}"

    echo -e "------------------------------------------------"
    echo -e "检测到推荐的上游入口域名: ${SKYBLUE}${RECOMMEND_HOST}${PLAIN}"
    echo -e "------------------------------------------------"
    read -p "是否使用此域名？[y/n] (默认: y): " use_rec
    use_rec=${use_rec:-y}

    if [[ "$use_rec" == "y" ]]; then
        FINAL_HOST="$RECOMMEND_HOST"
    else
        read -p "请输入手动指定的入口域名 (例如 tunnel-na.8443.buzz): " user_input
        if [[ -z "$user_input" ]]; then
            echo -e "${RED}输入为空，使用默认值 $DEFAULT_UPSTREAM${PLAIN}"
            FINAL_HOST="$DEFAULT_UPSTREAM"
        else
            FINAL_HOST="$user_input"
        fi
    fi

    # 持久化保存
    echo "Saved_Host=\"$FINAL_HOST\"" > "$CONFIG_ENV"
}

# ============================================================
# 3. 配置 Nginx 反向代理
# ============================================================
setup_nginx() {
    echo -e "${GREEN}>>> [3/4] 生成 Nginx 反代配置...${PLAIN}"

    # 交互：监听端口
    read -p "请输入 Nginx 本地监听端口 (供 Argo/隧道连接) [默认 8080]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-8080}
    
    # 获取节点数据
    NODES_JSON=$(curl -s "$API_NODES")
    if [[ -z "$NODES_JSON" ]]; then
        echo -e "${RED}严重错误：无法获取节点列表！${PLAIN}"
        exit 1
    fi

    # 写入 Nginx 头部
    cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$LISTEN_PORT;
    server_name localhost;
    
    # 基础优化
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    # 默认拒绝
    location / { return 404; }
EOF

    # 循环写入 Location 规则
    # 注意：这里只负责把流量甩给 $FINAL_HOST，不关心 UUID
    for node in $(echo "$NODES_JSON" | jq -r '.[] | @base64'); do
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
        # 传递真实IP (可选)
        proxy_set_header X-Real-IP \$remote_addr;
    }
EOF
    done

    echo "}" >> "$NGINX_CONF"

    # 链接并重载
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    nginx -t > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        systemctl restart nginx
        echo -e "${GREEN}Nginx 已启动，监听端口: 127.0.0.1:$LISTEN_PORT${PLAIN}"
    else
        echo -e "${RED}Nginx 配置验证失败！${PLAIN}"
        exit 1
    fi
}

# ============================================================
# 4. 生成 VMess 分享链接 (复用原脚本逻辑)
# ============================================================
generate_links() {
    echo -e "${GREEN}>>> [4/4] 生成分享链接...${PLAIN}"
    
    # 交互：Argo 域名
    echo -e "${YELLOW}请务必输入你 Cloudflare Tunnel 绑定的公网域名${PLAIN}"
    echo -e "(格式如: my-relay.trycloudflare.com 或 relay.mydomain.com)"
    read -p "公网域名: " USER_ARGO_DOMAIN
    
    if [[ -z "$USER_ARGO_DOMAIN" ]]; then
        echo -e "${RED}未输入公网域名，无法生成有效链接！${PLAIN}"
        exit 1
    fi

    # 清空输出文件
    > "$OUTPUT_FILE"

    echo -e "\n${SKYBLUE}------ 节点列表 (V2RayN / Sing-box) ------${PLAIN}"
    
    for node in $(echo "$NODES_JSON" | jq -r '.[] | @base64'); do
        _node=$(echo "$node" | base64 -d)
        
        # 提取原始字段
        ORIGIN_NAME=$(echo "$_node" | jq -r '.name')
        # 原始脚本有emoji处理，这里简单处理一下
        NODE_ALIAS="[Argo] $ORIGIN_NAME"
        
        REAL_UUID=$(echo "$_node" | jq -r '.uuid')
        REAL_PATH=$(echo "$_node" | jq -r '.["ws-opts"].path')

        # =================================================
        # 复用原脚本的 JSON 构建逻辑 (确保格式 100% 兼容)
        # 变更点：add, host, sni 替换为 USER_ARGO_DOMAIN
        # =================================================
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

        # Base64 编码生成 vmess://
        LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
        
        # 1. 保存到文件
        echo "$LINK" >> "$OUTPUT_FILE"
        
        # 2. 屏幕打印
        echo -e "${GREEN}${NODE_ALIAS}${PLAIN}"
        echo -e "$LINK"
        echo ""
    done

    echo -e "------------------------------------------------"
    echo -e "所有链接已保存至: ${YELLOW}$OUTPUT_FILE${PLAIN}"
    echo -e "配置完成！请确保你的 Argo 隧道已指向: http://localhost:$LISTEN_PORT"
}

# 执行主流程
init_system
configure_upstream
setup_nginx
generate_links