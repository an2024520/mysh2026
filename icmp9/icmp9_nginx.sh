#!/bin/bash

# ============================================================
# ICMP9 Relay Manager (部署/卸载一体化脚本)
# 适用: Debian/Ubuntu (128M+ VPS)
# 功能: 
#   1. [部署] Nginx 透明转发 + 动态链接生成
#   2. [卸载] 智能清理配置，可选卸载依赖
#   3. [工具] 仅重新生成分享链接
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

# API & Fallback
API_NODES="https://api.icmp9.com/online.php"
API_CONFIG="https://api.icmp9.com/config/config.txt"
HARD_FALLBACK="tunnel-na.8443.buzz"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ============================================================
# 基础函数库
# ============================================================

init_system() {
    echo -e "${GREEN}>>> [1/5] 初始化环境...${PLAIN}"
    if ! command -v nginx &> /dev/null || ! command -v jq &> /dev/null; then
        apt-get update -y && apt-get install -y nginx jq curl coreutils
    fi
    mkdir -p "$WORK_DIR"
    rm -f /etc/nginx/sites-enabled/default
}

get_user_info() {
    echo -e "${GREEN}>>> [2/5] 配置账户信息...${PLAIN}"
    if [ -f "$CONFIG_ENV" ]; then source "$CONFIG_ENV"; fi
    
    if [[ -n "$Saved_UUID" ]]; then
        read -p "使用已保存的 UUID? [y/n] (默认: y): " use_saved
        use_saved=${use_saved:-y}
        if [[ "$use_saved" == "n" ]]; then
            read -p "请输入你的 ICMP9 Key (UUID): " USER_UUID
        else
            USER_UUID="$Saved_UUID"
        fi
    else
        read -p "请输入你的 ICMP9 Key (UUID): " USER_UUID
    fi
    
    [[ -z "$USER_UUID" ]] && echo -e "${RED}UUID 不能为空！${PLAIN}" && exit 1
    echo "Saved_UUID=\"$USER_UUID\"" > "$CONFIG_ENV"
}

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
        echo -e "${YELLOW}正在从 API 获取最新入口...${PLAIN}"
        RAW_CFG=$(curl -s -m 5 "$API_CONFIG")
        # 严格复刻原脚本解析逻辑
        API_HOST=$(echo "$RAW_CFG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
        FINAL_HOST="${API_HOST:-$HARD_FALLBACK}"
    fi

    echo -e "${GREEN}>>> 已锁定上游: $FINAL_HOST${PLAIN}"
    echo "Saved_Host=\"$FINAL_HOST\"" >> "$CONFIG_ENV"
}

setup_nginx() {
    echo -e "${GREEN}>>> [4/5] 生成 Nginx 配置...${PLAIN}"
    read -p "Nginx 本地监听端口 [默认 8080]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-8080}

    cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$LISTEN_PORT;
    server_name localhost;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    # 通配转发 (适配所有国家路径)
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
    echo -e "${GREEN}Nginx 已启动 (监听 127.0.0.1:$LISTEN_PORT)${PLAIN}"
    # 保存端口配置供生成链接时提示
    echo "Saved_Port=\"$LISTEN_PORT\"" >> "$CONFIG_ENV"
}

generate_links() {
    echo -e "${GREEN}>>> [5/5] 生成分享链接...${PLAIN}"
    
    # 尝试自动读取 UUID
    if [ -z "$USER_UUID" ] && [ -f "$CONFIG_ENV" ]; then
        source "$CONFIG_ENV"
        USER_UUID="$Saved_UUID"
    fi
    [[ -z "$USER_UUID" ]] && echo -e "${RED}错误: 无法获取 UUID，请先运行部署流程。${PLAIN}" && return

    read -p "请输入你的公网 Argo 域名 (例如 xxx.trycloudflare.com): " USER_ARGO_DOMAIN
    [[ -z "$USER_ARGO_DOMAIN" ]] && echo -e "${RED}域名为空，操作取消。${PLAIN}" && return

    NODES_JSON=$(curl -s "$API_NODES")
    [[ -z "$NODES_JSON" ]] && echo -e "${RED}API 获取失败。${PLAIN}" && return

    > "$OUTPUT_FILE"
    echo -e "\n${SKYBLUE}------ 节点列表 ------${PLAIN}"

    for node in $(echo "$NODES_JSON" | jq -r '.countries[] | @base64'); do
        _node=$(echo "$node" | base64 -d)
        
        CODE=$(echo "$_node" | jq -r '.code')
        NAME=$(echo "$_node" | jq -r '.name')
        EMOJI=$(echo "$_node" | jq -r '.emoji')
        
        # 路径逻辑: /code
        REAL_PATH="/${CODE}"
        NODE_ALIAS="[Argo] ${EMOJI} ${NAME}"

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
}

# ============================================================
# 卸载逻辑
# ============================================================
do_uninstall() {
    echo -e "${YELLOW}>>> 警告: 即将清理 ICMP9 转发配置...${PLAIN}"
    
    # 停止旧版 Xray (如果存在)
    systemctl stop xray 2>/dev/null
    
    # 清理 Nginx 配置
    if [[ -f "/etc/nginx/sites-enabled/icmp9_relay" ]]; then
        rm -f "/etc/nginx/sites-enabled/icmp9_relay"
        rm -f "/etc/nginx/sites-available/icmp9_relay"
        systemctl reload nginx
        echo -e "${GREEN}Nginx 转发配置已删除。${PLAIN}"
    else
        echo "未发现 Nginx 转发配置。"
    fi

    # 清理文件
    rm -rf "$WORK_DIR"
    rm -f "$OUTPUT_FILE"
    rm -f /root/xray_nodes2.txt
    
    echo -e "${GREEN}配置文件已清理。${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "是否卸载依赖软件? (如果这台机器只做转发，建议选 y)"
    read -p "卸载 Nginx? [y/N]: " rm_nginx
    if [[ "$rm_nginx" == "y" || "$rm_nginx" == "Y" ]]; then
        apt-get purge -y nginx nginx-common
        apt-get autoremove -y
        echo -e "${GREEN}Nginx 已卸载。${PLAIN}"
    fi
    
    echo -e "\n${GREEN}>>> 卸载完成。${PLAIN}"
}

# ============================================================
# 主菜单
# ============================================================
show_menu() {
    clear
    echo -e "============================================"
    echo -e "   ICMP9 透明转发管理脚本 (Manager v1.0)"
    echo -e "============================================"
    
    # 状态检测
    if [[ -f "$CONFIG_ENV" ]]; then
        echo -e "当前状态: ${GREEN}已配置${PLAIN}"
        source "$CONFIG_ENV"
        echo -e "入口域名: ${SKYBLUE}${Saved_Host:-未知}${PLAIN}"
        echo -e "本地UUID: ${SKYBLUE}${Saved_UUID:-未知}${PLAIN}"
    else
        echo -e "当前状态: ${YELLOW}未安装${PLAIN}"
    fi
    echo -e "============================================"
    echo -e "  1. 部署 / 更新服务 (Deploy)"
    echo -e "  2. 仅重新生成链接 (Regenerate Links)"
    echo -e "  3. 卸载 / 清理环境 (Uninstall)"
    echo -e "  0. 退出 (Exit)"
    echo -e "============================================"
    read -p "请输入选项 [0-3]: " num

    case "$num" in
        1)
            init_system
            get_user_info
            configure_upstream
            setup_nginx
            generate_links
            ;;
        2)
            if [ ! -f "$CONFIG_ENV" ]; then
                echo -e "${RED}请先执行部署！${PLAIN}"
            else
                generate_links
            fi
            ;;
        3)
            do_uninstall
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            ;;
    esac
}

show_menu