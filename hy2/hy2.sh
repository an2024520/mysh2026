#!/bin/bash

# ============================================================
#  Hysteria 2 一键管理脚本 (v2.0 增强版)
#  - 支持自签/ACME
#  - 支持端口跳跃 (iptables)
#  - 自动生成 v2rayN / OpenClash 配置
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/hysteria/config.yaml"
HOPPING_CONF="/etc/hysteria/hopping.conf"
HY_BIN="/usr/local/bin/hysteria"

# --- 辅助函数：生成并打印节点信息 ---
print_node_info() {
    local IP_OR_DOMAIN=$1
    local PORT=$2
    local PASSWORD=$3
    local SNI=$4
    local INSECURE=$5
    local HOP_RANGE=$6
    
    # 确定显示给客户端的端口（如果是跳跃，则显示范围）
    local CLIENT_PORT="$PORT"
    if [[ -n "$HOP_RANGE" ]]; then
        CLIENT_PORT="$HOP_RANGE"
    fi

    # 1. 生成 v2rayN 分享链接 (hysteria2://)
    # 格式: hysteria2://密码@地址:端口/?sni=SNI&insecure=1#名称
    local V2RAYN_LINK="hysteria2://${PASSWORD}@${IP_OR_DOMAIN}:${CLIENT_PORT}/?sni=${SNI}&insecure=${INSECURE}&name=Hy2-${IP_OR_DOMAIN}"

    # 2. 生成 OpenClash (Meta核心) 配置块
    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}      Hysteria 2 节点配置生成成功！          ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    
    echo -e "${YELLOW}➤ v2rayN / Nekoray 分享链接:${PLAIN}"
    echo -e "${V2RAYN_LINK}"
    
    echo -e "\n${YELLOW}➤ OpenClash / Clash Meta 配置 (YAML):${PLAIN}"
    echo -e "----------------------------------------------"
    cat <<EOF
- name: "Hy2-${IP_OR_DOMAIN}"
  type: hysteria2
  server: "${IP_OR_DOMAIN}"
  port: ${CLIENT_PORT}  # 如果是端口跳跃，这里会显示范围
  password: "${PASSWORD}"
  sni: "${SNI}"
  skip-cert-verify: $( [[ "$INSECURE" == "1" ]] && echo "true" || echo "false" )
  alpn:
    - h3
EOF
    echo -e "----------------------------------------------"
    echo -e "${YELLOW}提示：如果启用了端口跳跃，请务必在 VPS 安全组放行 UDP 端口范围: ${HOP_RANGE}${PLAIN}"
}

# 1. 基础检查与依赖安装
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

install_base() {
    echo -e "${YELLOW}正在更新系统并安装必要组件...${PLAIN}"
    apt update -y
    # 核心：安装 iptables 和 持久化插件
    apt install -y curl wget openssl jq iptables iptables-persistent netfilter-persistent
    
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p
    fi
}

setup_port_hopping() {
    local TARGET_PORT=$1
    local HOP_RANGE=$2

    if [[ -z "$HOP_RANGE" ]]; then return; fi

    echo -e "${YELLOW}正在配置 iptables 端口跳跃: $HOP_RANGE -> $TARGET_PORT${PLAIN}"
    local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
    local END_PORT=$(echo $HOP_RANGE | cut -d '-' -f 2)

    # 清理旧规则并添加新规则
    iptables -t nat -F PREROUTING 2>/dev/null
    # 注意：这里省略了 -i eth0，使其对所有接口生效，防止网卡名不对导致规则无效
    iptables -t nat -A PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT"
    
    netfilter-persistent save
    echo "HOP_RANGE=$HOP_RANGE" > "$HOPPING_CONF"
}

install_core() {
    ARCH=$(dpkg --print-architecture)
    case $ARCH in
        amd64) HY_ARCH="amd64" ;;
        arm64) HY_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    wget -O "$HY_BIN" "https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${HY_ARCH}"
    chmod +x "$HY_BIN"
    mkdir -p /etc/hysteria
}

install_self_signed() {
    echo -e "${GREEN}>>> 模式: 自签名证书${PLAIN}"
    while true; do
        read -p "监听端口 (目标端口，如 8443): " LISTEN_PORT
        if [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -le 65535 ]; then break; fi
    done
    read -p "端口跳跃范围 (如 20000-30000，留空跳过): " PORT_HOP
    read -p "连接密码 (留空随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 8)

    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=bing.com" >/dev/null 2>&1

    cat <<EOF > "$CONFIG_FILE"
listen: :$LISTEN_PORT
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF
    
    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"
    start_service
    
    # 打印节点信息 (insecure=1, sni=bing.com)
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    print_node_info "$PUBLIC_IP" "$LISTEN_PORT" "$PASSWORD" "bing.com" "1" "$PORT_HOP"
}

install_acme() {
    echo -e "${GREEN}>>> 模式: ACME 证书 (强制443)${PLAIN}"
    read -p "域名: " DOMAIN
    read -p "邮箱: " EMAIL
    [[ -z "$EMAIL" ]] && EMAIL="admin@$DOMAIN"
    LISTEN_PORT=443
    read -p "端口跳跃范围 (如 20000-30000，留空跳过): " PORT_HOP
    read -p "连接密码 (留空随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 8)

    systemctl stop nginx 2>/dev/null
    
    cat <<EOF > "$CONFIG_FILE"
server:
  listen: :$LISTEN_PORT
acme:
  domains:
    - $DOMAIN
  email: $EMAIL
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF

    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"
    start_service
    
    # 打印节点信息 (insecure=0, sni=域名)
    print_node_info "$DOMAIN" "$LISTEN_PORT" "$PASSWORD" "$DOMAIN" "0" "$PORT_HOP"
}

start_service() {
    cat <<EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStart=$HY_BIN server -c $CONFIG_FILE
Restart=always
RestartSec=5
Environment=HYSTERIA_ACME_DIR=/etc/hysteria/acme

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl restart hysteria-server
}

uninstall_hy2() {
    echo -e "${RED}正在卸载...${PLAIN}"
    systemctl stop hysteria-server
    systemctl disable hysteria-server
    rm -f /etc/systemd/system/hysteria-server.service
    iptables -t nat -F PREROUTING 2>/dev/null
    netfilter-persistent save
    rm -f "$HY_BIN"
    rm -rf /etc/hysteria
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# --- 主菜单 ---
check_root
echo -e "1. 安装 - 自签名证书 (无域名)"
echo -e "2. 安装 - ACME 证书 (有域名)"
echo -e "3. 卸载"
read -p "选择: " CHOICE
case "$CHOICE" in
    1) install_base; install_core; install_self_signed ;;
    2) install_base; install_core; install_acme ;;
    3) uninstall_hy2 ;;
    *) echo "无效" ;;
esac
