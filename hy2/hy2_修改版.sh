#!/bin/bash

# ============================================================
#  Hysteria 2 全能管理脚本 (v4.0 优化版)
#  - 统一最新配置格式 (listen + acme/tls)
#  - 支持端口占用检查
#  - 端口跳跃: 自动检测 nftables / iptables
#  - 支持自定义 masquerade 网址
#  - 支持更多系统 (apt / yum / dnf)
#  - 增强服务状态检查
#  - 其他健壮性优化
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
SKYBLUE='\033[0;36m'

# 核心路径
CONFIG_FILE="/etc/hysteria/config.yaml"
HOPPING_CONF="/etc/hysteria/hopping.conf"
HY_BIN="/usr/local/bin/hysteria"
WIREPROXY_CONF="/etc/wireproxy/wireproxy.conf"
NFT_CONF="/etc/nftables/hy2_port_hopping.nft"

# --- 辅助功能：检查 Root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

# --- 辅助功能：端口占用检查 ---
check_port() {
    local port=$1
    if ss -tulnp | grep -q ":$port "; then
        echo -e "${RED}错误: 端口 $port 已被占用！${PLAIN}"
        return 1
    fi
    return 0
}

# --- 辅助功能：Web 服务管理 ---
stop_web_service() {
    WEB_SERVICE=""
    if systemctl is-active --quiet nginx; then
        WEB_SERVICE="nginx"
    elif systemctl is-active --quiet apache2; then
        WEB_SERVICE="apache2"
    elif systemctl is-active --quiet httpd; then
        WEB_SERVICE="httpd"
    fi

    if [[ -n "$WEB_SERVICE" ]]; then
        echo -e "${YELLOW}检测到 $WEB_SERVICE 占用端口，正在临时停止...${PLAIN}"
        systemctl stop "$WEB_SERVICE"
        touch /tmp/hy2_web_restore_flag
        echo "$WEB_SERVICE" > /tmp/hy2_web_service_name
    fi
}

restore_web_service() {
    if [[ -f /tmp/hy2_web_restore_flag ]]; then
        local SVC=$(cat /tmp/hy2_web_service_name)
        echo -e "${YELLOW}正在尝试恢复 Web 服务 ($SVC)...${PLAIN}"
        systemctl start "$SVC" 2>/dev/null
        if systemctl is-active --quiet "$SVC"; then
            echo -e "${GREEN}Web 服务已恢复。${PLAIN}"
        else
            echo -e "${RED}警告: Web 服务无法启动 (可能端口被 Hysteria 2 占用)。${PLAIN}"
        fi
        rm -f /tmp/hy2_web_restore_flag /tmp/hy2_web_service_name
    fi
}

# --- 辅助功能：节点信息生成 ---
print_node_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then return; fi

    echo -e "\n${YELLOW}正在读取当前配置生成分享链接...${PLAIN}"
    
    local LISTEN=$(grep "^listen:" $CONFIG_FILE | awk '{print $2}' | tr -d ':')
    if [[ -z "$LISTEN" ]]; then LISTEN=443; fi
    
    local DOMAIN_ACME=$(grep -A 2 "domains:" $CONFIG_FILE | tail -n 1 | tr -d ' -')
    local PASSWORD=$(grep "password:" $CONFIG_FILE | awk '{print $2}')
    
    local IS_SOCKS5="直连模式"
    if grep -q "# --- SOCKS5 START ---" $CONFIG_FILE; then
        IS_SOCKS5="${SKYBLUE}已挂载 Socks5 代理${PLAIN}"
    fi

    local SHOW_ADDR=""
    local SNI=""
    local INSECURE="0"

    if grep -q "acme:" $CONFIG_FILE; then
        SHOW_ADDR="$DOMAIN_ACME"
        SNI="$DOMAIN_ACME"
        INSECURE="0"
        SKIP_CERT_VAL="false"
    else
        SHOW_ADDR=$(curl -s4 ifconfig.me)
        SNI="bing.com"
        INSECURE="1"
        SKIP_CERT_VAL="true"
    fi

    local SHOW_PORT="$LISTEN"
    local OC_PORT="$LISTEN"
    local OC_COMMENT=""
    
    if [[ -f "$HOPPING_CONF" ]]; then
        source "$HOPPING_CONF"
        if [[ -n "$HOP_RANGE" ]]; then
            SHOW_PORT="$HOP_RANGE"
            local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
            OC_PORT="$START_PORT"
            OC_COMMENT="# 端口跳跃范围: ${HOP_RANGE}"
        fi
    fi

    local NODE_NAME="Hy2-${SHOW_ADDR}"
    local V2RAYN_LINK="hysteria2://${PASSWORD}@${SHOW_ADDR}:${SHOW_PORT}/?sni=${SNI}&insecure=${INSECURE}#${NODE_NAME}"

    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}      Hysteria 2 配置信息 (${IS_SOCKS5})      ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "地址: ${YELLOW}${SHOW_ADDR}${PLAIN}"
    echo -e "端口: ${YELLOW}${SHOW_PORT}${PLAIN}"
    echo -e "密码: ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "SNI : ${YELLOW}${SNI}${PLAIN}"
    echo -e "跳过证书验证: ${YELLOW}$( [[ "$INSECURE" == "1" ]] && echo "True" || echo "False" )${PLAIN}"
    
    echo -e "\n${YELLOW}➤ v2rayN / Nekoray 分享链接:${PLAIN}"
    echo -e "${V2RAYN_LINK}"
    
    echo -e "\n${YELLOW}➤ OpenClash / Clash Meta (YAML):${PLAIN}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: hysteria2
  server: "${SHOW_ADDR}"
  port: ${OC_PORT}  ${OC_COMMENT}
  password: "${PASSWORD}"
  sni: "${SNI}"
  skip-cert-verify: ${SKIP_CERT_VAL}
  alpn:
    - h3
EOF
    echo -e "----------------------------------------------"
}

# --- 系统检测与包管理 ---
detect_pkg_manager() {
    if command -v apt >/dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt update -y"
        PKG_INSTALL="apt install -y"
    elif command -v yum >/dev/null || command -v dnf >/dev/null; then
        PKG_MANAGER="yum"
        if command -v dnf >/dev/null; then
            PKG_UPDATE="dnf check-update -y || true"
            PKG_INSTALL="dnf install -y"
        else
            PKG_UPDATE="yum check-update -y || true"
            PKG_INSTALL="yum install -y"
        fi
    else
        echo -e "${RED}不支持的系统包管理器${PLAIN}"
        exit 1
    fi
}

install_base() {
    detect_pkg_manager
    echo -e "${YELLOW}正在更新系统并安装基础组件...${PLAIN}"
    $PKG_UPDATE
    $PKG_INSTALL curl wget openssl jq socat
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        $PKG_INSTALL iptables-persistent netfilter-persistent || true
    fi
}

install_core() {
    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case $ARCH in
        amd64|x86_64) HY_ARCH="amd64" ;;
        arm64|aarch64) HY_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    echo -e "${YELLOW}正在获取 Hysteria 2 最新版本...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name | sed 's/app\///')
    if [[ -z "$LATEST_VERSION" ]]; then
        echo -e "${RED}获取版本失败${PLAIN}"
        exit 1
    fi
    
    wget -O "$HY_BIN" "https://github.com/apernet/hysteria/releases/download/app%2F${LATEST_VERSION}/hysteria-linux-${HY_ARCH}"
    chmod +x "$HY_BIN"
    mkdir -p /etc/hysteria
}

# --- 端口跳跃: nftables 优先 ---
detect_firewall() {
    if command -v nft >/dev/null; then
        echo "nftables"
    elif command -v iptables >/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

setup_port_hopping() {
    local TARGET_PORT=$1
    local HOP_RANGE=$2
    if [[ -z "$HOP_RANGE" ]]; then return; fi

    local FW=$(detect_firewall)
    local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
    local END_PORT=$(echo $HOP_RANGE | cut -d '-' -f 2)

    echo -e "${YELLOW}正在配置端口跳跃: $HOP_RANGE -> $TARGET_PORT (使用 $FW)${PLAIN}"

    if [[ "$FW" == "nftables" ]]; then
        mkdir -p /etc/nftables
        cat > "$NFT_CONF" <<EOF
table inet hysteria {
    chain prerouting {
        type nat hook prerouting priority dstnat + 10; policy accept;
        udp dport $START_PORT-$END_PORT redirect to :$TARGET_PORT
    }
}
EOF
        nft flush table inet hysteria 2>/dev/null
        nft delete table inet hysteria 2>/dev/null
        nft -f "$NFT_CONF"
        systemctl enable nftables >/dev/null 2>&1
        systemctl restart nftables >/dev/null 2>&1
    elif [[ "$FW" == "iptables" ]]; then
        while iptables -t nat -D PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT" 2>/dev/null; do :; done
        iptables -t nat -A PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT"
        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save >/dev/null 2>&1
        fi
    else
        echo -e "${RED}未检测到防火墙工具，无法配置端口跳跃${PLAIN}"
        return
    fi

    echo "HOP_RANGE=$HOP_RANGE" > "$HOPPING_CONF"
}

uninstall_port_hopping() {
    if [[ -f "$HOPPING_CONF" ]]; then
        source "$HOPPING_CONF"
        if [[ -n "$HOP_RANGE" ]]; then
            local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
            local END_PORT=$(echo $HOP_RANGE | cut -d '-' -f 2)
            local FW=$(detect_firewall)

            if [[ "$FW" == "nftables" ]]; then
                nft flush table inet hysteria 2>/dev/null
                nft delete table inet hysteria 2>/dev/null
                rm -f "$NFT_CONF"
            elif [[ "$FW" == "iptables" ]]; then
                while iptables -t nat -D PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT 2>/dev/null; do :; done
                if command -v netfilter-persistent >/dev/null; then
                    netfilter-persistent save >/dev/null 2>&1
                fi
            fi
        fi
        rm -f "$HOPPING_CONF"
    fi
}

# --- 安装逻辑 ---
install_common() {
    local LISTEN_PORT=$1
    local PASSWORD=$2
    local MASQUERADE_URL=$3

    cat <<EOF > "$CONFIG_FILE"
listen: :$LISTEN_PORT
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE_URL
    rewriteHost: true
EOF
}

install_self_signed() {
    echo -e "${GREEN}>>> 安装模式: 自签名证书 (无域名)${PLAIN}"
    while true; do
        read -p "请输入监听端口 (推荐 8443): " LISTEN_PORT
        [[ -z "$LISTEN_PORT" ]] && LISTEN_PORT=8443
        if [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -le 65535 ]; then
            if check_port "$LISTEN_PORT"; then break; fi
        fi
    done
    
    read -p "端口跳跃范围 (如 20000-30000，留空跳过): " PORT_HOP
    read -p "连接密码 (留空随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 16)
    read -p "伪装网址 (默认 https://news.ycombinator.com/): " MASQUERADE_URL
    [[ -z "$MASQUERADE_URL" ]] && MASQUERADE_URL="https://news.ycombinator.com/"

    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=bing.com" >/dev/null 2>&1

    install_common "$LISTEN_PORT" "$PASSWORD" "$MASQUERADE_URL"
    cat <<EOF >> "$CONFIG_FILE"
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
EOF

    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"
    start_service
    print_node_info
}

install_acme() {
    echo -e "${GREEN}>>> 安装模式: ACME 证书 (有域名，监听 443)${PLAIN}"
    read -p "请输入域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo "域名不能为空" && exit 1
    
    read -p "请输入邮箱 (留空自动): " EMAIL
    [[ -z "$EMAIL" ]] && EMAIL="admin@$DOMAIN"
    
    read -p "端口跳跃范围 (如 20000-30000，留空跳过): " PORT_HOP
    read -p "连接密码 (留空随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 16)
    read -p "伪装网址 (默认 https://news.ycombinator.com/): " MASQUERADE_URL
    [[ -z "$MASQUERADE_URL" ]] && MASQUERADE_URL="https://news.ycombinator.com/"

    LISTEN_PORT=443
    if ! check_port "$LISTEN_PORT"; then exit 1; fi

    stop_web_service

    install_common "$LISTEN_PORT" "$PASSWORD" "$MASQUERADE_URL"
    cat <<EOF >> "$CONFIG_FILE"
acme:
  domains:
    - $DOMAIN
  email: $EMAIL
EOF

    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"
    start_service
    restore_web_service
    print_node_info
}

# --- Socks5 挂载/移除 (保持原逻辑，增强幂等) ---
attach_socks5() {
    # 同原脚本逻辑，略（为节省篇幅，此处保持不变）
    # ... (复制原 attach_socks5 函数)
    echo -e "${GREEN}>>> 正在配置 Socks5 出口分流...${PLAIN}"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 配置文件不存在。${PLAIN}"
        return
    fi
    detach_socks5 "quiet"

    DEFAULT_SOCKS="127.0.0.1:40000"
    DETECTED_INFO=""
    if [[ -f "$WIREPROXY_CONF" ]]; then
        DETECTED_INFO=$(grep "BindAddress" "$WIREPROXY_CONF" | awk -F '=' '{print $2}' | tr -d ' ')
    fi

    if [[ -n "$DETECTED_INFO" ]]; then
        echo -e "${YELLOW}检测到 WireProxy: ${GREEN}${DETECTED_INFO}${PLAIN}"
        read -p "是否使用此地址？(y/n, 默认 y): " USE_DETECTED
        [[ -z "$USE_DETECTED" ]] && USE_DETECTED="y"
        if [[ "$USE_DETECTED" == "y" ]]; then
            PROXY_ADDR="$DETECTED_INFO"
        else
            read -p "请输入 Socks5 地址: " PROXY_ADDR
        fi
    else
        read -p "请输入 Socks5 地址 (默认 $DEFAULT_SOCKS): " PROXY_ADDR
        [[ -z "$PROXY_ADDR" ]] && PROXY_ADDR="$DEFAULT_SOCKS"
    fi

    cat <<EOF >> "$CONFIG_FILE"

# --- SOCKS5 START ---
outbounds:
  - name: socks5_out
    type: socks5
    socks5:
      addr: $PROXY_ADDR

acl:
  inline:
    - socks5_out(all)
# --- SOCKS5 END ---
EOF

    systemctl restart hysteria-server
    sleep 2
    if systemctl is-active --quiet hysteria-server; then
        echo -e "${GREEN}挂载成功！${PLAIN}"
        print_node_info
    else
        echo -e "${RED}启动失败，回滚...${PLAIN}"
        detach_socks5 "quiet"
    fi
}

detach_socks5() {
    local MODE=$1
    if [[ "$MODE" != "quiet" ]]; then
        echo -e "${YELLOW}正在移除 Socks5 配置...${PLAIN}"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        sed -i '/# --- SOCKS5 START ---/,/# --- SOCKS5 END ---/d' "$CONFIG_FILE"
        sed -i '/^$/N;/^\n$/D' "$CONFIG_FILE"
    fi

    if [[ "$MODE" != "quiet" ]]; then
        systemctl restart hysteria-server
        echo -e "${GREEN}已恢复直连模式。${PLAIN}"
        print_node_info
    fi
}

# --- 服务管理 ---
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

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl restart hysteria-server

    sleep 3
    if systemctl is-active --quiet hysteria-server && ss -ulnp | grep -q "$HY_BIN"; then
        echo -e "${GREEN}Hysteria 2 服务启动成功！${PLAIN}"
    else
        echo -e "${RED}服务启动失败，请查看 journalctl -u hysteria-server${PLAIN}"
    fi
}

uninstall_hy2() {
    echo -e "${RED}警告: 即将完全卸载 Hysteria 2${PLAIN}"
    read -p "确认继续? (y/n): " CONFIRM
    [[ "$CONFIRM" != "y" ]] && return

    systemctl stop hysteria-server 2>/dev/null
    systemctl disable hysteria-server 2>/dev/null
    rm -f /etc/systemd/system/hysteria-server.service
    uninstall_port_hopping
    rm -f "$HY_BIN"
    rm -rf /etc/hysteria
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# --- 主菜单 ---
while true; do
    check_root
    clear
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    Hysteria 2 一键管理脚本 (v4.0)      ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "  1. 安装 - ${YELLOW}自签名证书${PLAIN} (无域名)"
    echo -e "  2. 安装 - ${GREEN}ACME 证书${PLAIN} (有域名)"
    echo -e "----------------------------------------"
    echo -e "  3. ${SKYBLUE}挂载 Socks5 代理出口${PLAIN} (Warp等)"
    echo -e "  4. ${YELLOW}移除 Socks5 代理出口${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "  5. 查看节点配置 / 分享链接"
    echo -e "  6. ${RED}卸载 Hysteria 2${PLAIN}"
    echo -e "  0. 退出"
    echo -e ""
    read -p "请选择操作 [0-6]: " choice

    case "$choice" in
        1) install_base; install_core; install_self_signed; read -p "按回车继续..." ;;
        2) install_base; install_core; install_acme; read -p "按回车继续..." ;;
        3) attach_socks5; read -p "按回车继续..." ;;
        4) detach_socks5; read -p "按回车继续..." ;;
        5) print_node_info; read -p "按回车继续..." ;;
        6) uninstall_hy2; read -p "按回车继续..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
    esac
done
