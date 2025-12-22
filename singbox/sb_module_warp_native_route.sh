#!/bin/bash

# ============================================================
#  Sing-box Native WARP 管理模块 (SB-Commander v6.5 IPv6-Fix)
#  - 核心修复: 强制 IP 掩码 (/32 /128) 解决 Sing-box 解析崩溃
#  - 物理链路: 强制 IPv6 Endpoint 绕过 NAT64 解析故障
#  - 权限修复: 自动处理日志目录写入权
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# ==========================================
# 1. 环境初始化
# ==========================================

CONFIG_FILE=""
CRED_FILE="/etc/sing-box/warp_credentials.conf"
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未检测到 config.json 配置文件！${PLAIN}"
    exit 1
fi

mkdir -p "$(dirname "$CRED_FILE")"

check_dependencies() {
    if ! command -v jq &> /dev/null; then apt-get install -y jq || yum install -y jq; fi
    if ! command -v curl &> /dev/null; then apt-get install -y curl || yum install -y curl; fi
}

ensure_python() {
    if ! command -v python3 &> /dev/null; then
        echo -e "${YELLOW}安装 Python3 支持...${PLAIN}"
        apt-get install -y python3 || yum install -y python3
    fi
}

restart_sb() {
    # 预先修复日志权限，防止启动失败
    mkdir -p /var/log/sing-box/ && chmod 777 /var/log/sing-box/ >/dev/null 2>&1
    
    echo -e "${YELLOW}重启 Sing-box 服务...${PLAIN}"
    if command -v sing-box &> /dev/null; then
        if ! sing-box check -c "$CONFIG_FILE" > /dev/null 2>&1; then
             echo -e "${RED}配置语法校验失败！具体错误如下：${PLAIN}"
             sing-box check -c "$CONFIG_FILE"
             if [[ -f "${CONFIG_FILE}.bak" ]]; then
                 echo -e "${YELLOW}正在尝试回滚到备份配置...${PLAIN}"
                 cp "${CONFIG_FILE}.bak" "$CONFIG_FILE"
                 restart_sb
             fi
             return
        fi
    fi

    if systemctl list-unit-files | grep -q sing-box; then
        systemctl restart sing-box
    else
        pkill -xf "sing-box run -c $CONFIG_FILE"
        nohup sing-box run -c "$CONFIG_FILE" > /dev/null 2>&1 &
    fi
    sleep 2
    if systemctl is-active --quiet sing-box || pgrep -x "sing-box" >/dev/null; then
        echo -e "${GREEN}服务重启成功。${PLAIN}"
    else
        echo -e "${RED}服务重启失败！请运行 'journalctl -u sing-box' 查看原因。${PLAIN}"
    fi
}

# ==========================================
# 2. 核心：账号与配置
# ==========================================

clean_reserved() {
    local input="$1"
    local nums=$(echo "$input" | grep -oE '[0-9]+' | tr '\n' ',' | sed 's/,$//')
    [[ -n "$nums" ]] && echo "[$nums]" || echo ""
}

base64_to_reserved_shell() {
    local input="$1"
    local bytes=$(echo "$input" | base64 -d 2>/dev/null | od -An -t u1 | tr -s ' ' ',')
    bytes=$(echo "$bytes" | sed 's/^,//;s/,$//;s/ //g')
    [[ -n "$bytes" ]] && echo "[$bytes]" || echo ""
}

save_credentials() {
    cat > "$CRED_FILE" <<EOF
PRIV_KEY="$1"
PUB_KEY="$2"
V4_ADDR="$3"
V6_ADDR="$4"
RESERVED="$5"
EOF
    echo -e "${GREEN}凭证已备份至: $CRED_FILE${PLAIN}"
}

register_warp() {
    ensure_python || return 1
    echo -e "${YELLOW}正在注册免费账号...${PLAIN}"
    if ! command -v wg &> /dev/null; then apt install -y wireguard-tools || yum install -y wireguard-tools; fi
    
    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local peer_pub=$(echo "$result" | jq -r '.config.peers[0].public_key')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    
    if [[ "$v4" == "null" || -z "$v4" ]]; then echo -e "${RED}注册失败。${PLAIN}"; return 1; fi
    
    # 核心修复 1: 补全 IP 掩码，防止 Sing-box 报错
    [[ ! "$v4" =~ "/" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" ]] && v6="${v6}/128"
    
    local reserved_json=$(python3 -c "import base64, json; decoded = base64.b64decode('$client_id'); print(json.dumps([x for x in decoded[0:3]]))" 2>/dev/null)
    
    save_credentials "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

manual_warp() {
    # [手动录入逻辑同理需补全掩码...]
    # 为了简洁，主要逻辑在 write_warp_config 统一处理
    local def_priv="" def_pub="" def_v4="" def_v6="" def_res=""
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE"; def_priv="$PRIV_KEY"; def_pub="$PUB_KEY"; def_v4="$V4_ADDR"; def_v6="$V6_ADDR"; def_res="$RESERVED"
        echo -e "${SKYBLUE}检测到历史凭证，回车可直接使用默认值。${PLAIN}"
    fi
    read -p "私钥 (Private Key): " priv_key; [[ -z "$priv_key" ]] && priv_key="$def_priv"
    read -p "公钥 (Peer Public Key): " peer_pub; [[ -z "$peer_pub" ]] && peer_pub="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    read -p "本机 IPv4 [默认: 172.16.0.2/32]: " v4; [[ -z "$v4" ]] && v4="172.16.0.2/32"
    read -p "本机 IPv6 [默认: $def_v6]: " v6; [[ -z "$v6" ]] && v6="$def_v6"
    read -p "Reserved: " res_input; # [保留原逻辑获取 reserved_json...]
    
    # 手动输入补全
    [[ ! "$v4" =~ "/" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" ]] && v6="${v6}/128"
    
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

write_warp_config() {
    local priv="$1" pub="$2" v4="$3" v6="$4" res="$5"
    
    # 核心修复 2: 再次确认掩码，防止漏网之鱼
    [[ ! "$v4" =~ "/" && -n "$v4" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" && -n "$v6" ]] && v6="${v6}/128"
    
    local addr_json="[]"
    [[ -n "$v4" && "$v4" != "null" ]] && addr_json=$(echo "$addr_json" | jq --arg ip "$v4" '. + [$ip]')
    [[ -n "$v6" && "$v6" != "null" ]] && addr_json=$(echo "$addr_json" | jq --arg ip "$v6" '. + [$ip]')
    
    # 核心修复 3: 将域名 Endpoint 强制改为物理 IPv6 地址
    local warp_json=$(jq -n \
        --arg priv "$priv" --arg pub "$pub" --argjson addr "$addr_json" --argjson res "$res" \
        '{ 
            "type": "wireguard", 
            "tag": "WARP", 
            "address": $addr, 
            "private_key": $priv,
            "system": false,
            "peers": [
                { 
                    "address": "2606:4700:d0::a29f:c001", 
                    "port": 2408, 
                    "public_key": $pub, 
                    "reserved": $res,
                    "allowed_ips": ["0.0.0.0/0", "::/0"]
                }
            ] 
        }')

    # ... [后续 JSON 写入逻辑保持不变] ...
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local TMP_CONF=$(mktemp)
    jq 'if .endpoints == null then .endpoints = [] else . end | del(.endpoints[] | select(.tag == "WARP")) | .endpoints += [$new]' --argjson new "$warp_json" "$CONFIG_FILE" > "$TMP_CONF"
    
    if [[ $? -eq 0 && -s "$TMP_CONF" ]]; then
        mv "$TMP_CONF" "$CONFIG_FILE"
        echo -e "${GREEN}WARP Endpoint 配置完成并应用物理 IPv6 直连。${PLAIN}"
        restart_sb
    else
        echo -e "${RED}写入失败。${PLAIN}"; rm "$TMP_CONF" 2>/dev/null
    fi
}

# ... [路由管理逻辑保持不变] ...
show_menu() {
    check_dependencies
    # ... [菜单循环逻辑保持不变] ...
}
show_menu
