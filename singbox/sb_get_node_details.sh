#!/bin/bash

# =================================================
# 脚本名称：sb_get_node_details.sh (v3.1 Final)
# 作用：全能节点信息提取 (支持 AnyTLS / Hysteria2 / 元数据读取)
# =================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="$1"
NODE_TAG="$2"

# 1. 自动寻路
# ------------------------------------------------
if [[ -z "$CONFIG_FILE" ]]; then
    PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
    for p in "${PATHS[@]}"; do
        if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
    done
    if [[ -z "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 未找到 Sing-box 配置文件。${PLAIN}"; exit 1
    fi
    echo -e "${GREEN}读取配置: $CONFIG_FILE${PLAIN}"
fi
META_FILE="${CONFIG_FILE}.meta"

if ! command -v jq &> /dev/null; then echo -e "${RED}错误: 需要安装 jq${PLAIN}"; exit 1; fi

# 2. 交互式选择 (Inbounds + Outbounds)
# ------------------------------------------------
if [[ -z "$NODE_TAG" ]]; then
    # 扫描 Inbounds (排除空) - 增加 anytls/hysteria2 支持
    LIST_IN=$(jq -r '.inbounds[]? | select(.type=="vless" or .type=="vmess" or .type=="hysteria2" or .type=="anytls") | .tag + " [Server-In]"' "$CONFIG_FILE")
    # 扫描 Outbounds (排除 Direct/Block 等)
    LIST_OUT=$(jq -r '.outbounds[]? | select(.type!="direct" and .type!="block" and .type!="dns" and .type!="selector" and .type!="urltest") | .tag + " [Client-Out]"' "$CONFIG_FILE")
    
    # 合并列表
    IFS=$'\n' read -d '' -r -a ALL_NODES <<< "$LIST_IN"$'\n'"$LIST_OUT"

    # 清理空行
    CLEAN_NODES=()
    for item in "${ALL_NODES[@]}"; do
        [[ -n "$item" ]] && CLEAN_NODES+=("$item")
    done

    if [[ ${#CLEAN_NODES[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未发现任何有效节点。请先添加节点。${PLAIN}"
        exit 0
    fi

    echo -e "-------------------------------------------"
    echo -e "发现以下节点:"
    i=1
    for item in "${CLEAN_NODES[@]}"; do
        echo -e " ${GREEN}$i.${PLAIN} $item"
        let i++
    done
    echo -e "-------------------------------------------"
    
    read -p "请选择序号 (回车退出): " CHOICE
    if [[ -z "$CHOICE" ]]; then exit 0; fi
    INDEX=$((CHOICE-1))
    
    RAW_SELECTION="${CLEAN_NODES[$INDEX]}"
    if [[ -z "$RAW_SELECTION" ]]; then echo "无效选择"; exit 1; fi
    
    # 提取纯 Tag (去掉后面的 [Server-In] 等)
    NODE_TAG=$(echo "$RAW_SELECTION" | awk '{print $1}')
fi

echo -e "正在解析: ${SKYBLUE}$NODE_TAG${PLAIN} ..."

# 3. 数据提取
# ------------------------------------------------
# 尝试在 Inbounds (服务端) 查找
NODE_JSON=$(jq -r --arg tag "$NODE_TAG" '.inbounds[]? | select(.tag==$tag)' "$CONFIG_FILE")
IS_SERVER="false"

if [[ -n "$NODE_JSON" ]]; then
    IS_SERVER="true"
else
    # 尝试在 Outbounds (客户端) 查找
    NODE_JSON=$(jq -r --arg tag "$NODE_TAG" '.outbounds[]? | select(.tag==$tag)' "$CONFIG_FILE")
fi

if [[ -z "$NODE_JSON" ]]; then echo "错误: JSON 中找不到 Tag 为 '$NODE_TAG' 的配置。"; exit 1; fi

# 提取通用字段
TYPE=$(echo "$NODE_JSON" | jq -r '.type')
SKIP_CERT_VERIFY="false" # 默认验证证书

if [[ "$IS_SERVER" == "true" ]]; then
    # === 服务端模式 (Inbound) ===
    SERVER_ADDR=$(curl -s4m5 https://api.ip.sb/ip || curl -s4m5 ifconfig.me)
    PORT=$(echo "$NODE_JSON" | jq -r '.listen_port')
    
    # 区分协议提取凭证
    if [[ "$TYPE" == "anytls" || "$TYPE" == "hysteria2" ]]; then
        PASSWORD=$(echo "$NODE_JSON" | jq -r '.users[0].password // empty')
    else
        UUID=$(echo "$NODE_JSON" | jq -r '.users[0].uuid // empty')
    fi
    
    # 提取 Hy2 混淆
    if [[ "$TYPE" == "hysteria2" ]]; then
        OBFS_TYPE="salamander"
        OBFS_PASS=$(echo "$NODE_JSON" | jq -r '.obfs.password // empty')
    fi

    # 尝试从伴生文件读取元数据
    if [[ -f "$META_FILE" ]]; then
        # VLESS / AnyTLS
        PBK=$(jq -r --arg tag "$NODE_TAG" '.[$tag].pbk // empty' "$META_FILE")
        SID=$(jq -r --arg tag "$NODE_TAG" '.[$tag].sid // empty' "$META_FILE")
        
        # 通用 / Hy2
        META_SNI=$(jq -r --arg tag "$NODE_TAG" '.[$tag].sni // .[$tag].domain // empty' "$META_FILE")
        if [[ -n "$META_SNI" ]]; then SNI="$META_SNI"; fi
        
        # Hy2 证书模式判断
        META_TYPE=$(jq -r --arg tag "$NODE_TAG" '.[$tag].type // empty' "$META_FILE")
        if [[ "$META_TYPE" == "hy2-self" ]]; then
            SKIP_CERT_VERIFY="true"
        fi
    fi
    
    # 如果伴生文件里没有 SNI，尝试从配置读取
    if [[ -z "$SNI" ]]; then SNI=$(echo "$NODE_JSON" | jq -r '.tls.server_name // empty'); fi
    # 如果 Hy2 自签且无 SNI，默认 bing.com
    if [[ "$TYPE" == "hysteria2" && "$SKIP_CERT_VERIFY" == "true" && -z "$SNI" ]]; then SNI="bing.com"; fi

else
    # === 客户端模式 (Outbound) ===
    SERVER_ADDR=$(echo "$NODE_JSON" | jq -r '.server')
    PORT=$(echo "$NODE_JSON" | jq -r '.server_port')
    
    if [[ "$TYPE" == "anytls" || "$TYPE" == "hysteria2" ]]; then
        PASSWORD=$(echo "$NODE_JSON" | jq -r '.password // empty')
    else
        UUID=$(echo "$NODE_JSON" | jq -r '.uuid // empty')
    fi
    
    if [[ "$TYPE" == "hysteria2" ]]; then
        OBFS_PASS=$(echo "$NODE_JSON" | jq -r '.obfs.password // empty')
        INSECURE=$(echo "$NODE_JSON" | jq -r '.tls.insecure // "false"')
        [[ "$INSECURE" == "true" ]] && SKIP_CERT_VERIFY="true"
    fi
    
    SNI=$(echo "$NODE_JSON" | jq -r '.tls.server_name // empty')
    PBK=$(echo "$NODE_JSON" | jq -r '.tls.reality.public_key // empty')
    SID=$(echo "$NODE_JSON" | jq -r '.tls.reality.short_id // empty')
fi

urlencode() {
    local string="${1}"; local strlen=${#string}; local encoded=""; local pos c o
    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}; case "$c" in [-_.~a-zA-Z0-9] ) o="${c}" ;; * ) printf -v o '%%%02x' "'$c" ;; esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# 4. 生成链接与配置
# ------------------------------------------------
LINK=""

case "$TYPE" in
    "vless")
        FLOW=""
        if [[ "$IS_SERVER" == "true" ]]; then
            FLOW=$(echo "$NODE_JSON" | jq -r '.users[0].flow // empty')
            TLS_ENABLED=$(echo "$NODE_JSON" | jq -r '.tls.enabled // "false"')
            REALITY=$(echo "$NODE_JSON" | jq -r '.tls.reality.enabled // "false"')
            TRANSPORT=$(echo "$NODE_JSON" | jq -r '.transport.type // "tcp"')
            WS_PATH=$(echo "$NODE_JSON" | jq -r '.transport.path // "/"')
            GRPC_SERVICE=$(echo "$NODE_JSON" | jq -r '.transport.service_name // empty')
        else
            FLOW=$(echo "$NODE_JSON" | jq -r '.flow // empty')
            TLS_ENABLED=$(echo "$NODE_JSON" | jq -r '.tls.enabled // "false"')
            REALITY=$(echo "$NODE_JSON" | jq -r '.tls.reality.enabled // "false"')
            TRANSPORT=$(echo "$NODE_JSON" | jq -r '.transport.type // "tcp"')
            WS_PATH=$(echo "$NODE_JSON" | jq -r '.transport.path // "/"')
            GRPC_SERVICE=$(echo "$NODE_JSON" | jq -r '.transport.service_name // empty')
        fi

        PARAMS="security=none"
        if [[ "$TLS_ENABLED" == "true" ]]; then
            if [[ "$REALITY" == "true" ]]; then
                PARAMS="security=reality&sni=$SNI&fp=chrome&pbk=$PBK"
                [[ -n "$SID" ]] && PARAMS+="&sid=$SID"
            else
                PARAMS="security=tls&sni=$SNI"
            fi
        fi
        PARAMS+="&type=$TRANSPORT"
        [[ "$TRANSPORT" == "ws" ]] && PARAMS+="&path=$(urlencode "$WS_PATH")"
        [[ "$TRANSPORT" == "grpc" ]] && PARAMS+="&serviceName=$(urlencode "$GRPC_SERVICE")"
        [[ -n "$FLOW" ]] && PARAMS+="&flow=$FLOW"
        
        LINK="vless://${UUID}@${SERVER_ADDR}:${PORT}?${PARAMS}#$(urlencode "$NODE_TAG")"
        ;;

    "anytls")
        LINK="anytls://${PASSWORD}@${SERVER_ADDR}:${PORT}?security=reality&sni=${SNI}&fp=chrome&pbk=${PBK}&sid=${SID}&type=tcp&headerType=none#$(urlencode "$NODE_TAG")"
        ;;

    "hysteria2")
        # 构造 Hy2 链接
        # hysteria2://password@ip:port?insecure=1&obfs=salamander&obfs-password=xxx&sni=bing.com#tag
        INSECURE_VAL="0"
        [[ "$SKIP_CERT_VERIFY" == "true" ]] && INSECURE_VAL="1"
        
        LINK="hysteria2://${PASSWORD}@${SERVER_ADDR}:${PORT}?insecure=${INSECURE_VAL}&sni=${SNI}"
        if [[ -n "$OBFS_PASS" ]]; then
            LINK+="&obfs=salamander&obfs-password=${OBFS_PASS}"
        fi
        LINK+="#$(urlencode "$NODE_TAG")"
        ;;

    *)
        echo "暂不支持自动生成该协议链接: $TYPE"
        exit 0
        ;;
esac

# 5. 最终输出
# ------------------------------------------------
echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}       节点详情: ${NODE_TAG}       ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "协议        : ${YELLOW}${TYPE}${PLAIN}"
echo -e "地址        : ${YELLOW}${SERVER_ADDR}:${PORT}${PLAIN}"

if [[ "$TYPE" == "anytls" || "$TYPE" == "hysteria2" ]]; then
    echo -e "Password    : ${SKYBLUE}${PASSWORD}${PLAIN}"
else
    echo -e "UUID        : ${SKYBLUE}${UUID}${PLAIN}"
fi

echo -e "SNI         : ${YELLOW}${SNI}${PLAIN}"

if [[ "$TYPE" == "vless" && -n "$PBK" ]]; then
    echo -e "Reality PBK : ${SKYBLUE}${PBK}${PLAIN}"
elif [[ "$TYPE" == "anytls" && -n "$PBK" ]]; then
    echo -e "Reality PBK : ${SKYBLUE}${PBK}${PLAIN}"
elif [[ "$TYPE" == "hysteria2" ]]; then
    echo -e "Obfs Pass   : ${SKYBLUE}${OBFS_PASS}${PLAIN}"
    echo -e "Skip Cert   : $( [[ "$SKIP_CERT_VERIFY" == "true" ]] && echo "${RED}True (不安全)${PLAIN}" || echo "${GREEN}False (安全)${PLAIN}" )"
fi

echo -e "----------------------------------------"
echo -e "🚀 [分享链接] (v2rayN / Nekobox):"
echo -e "${YELLOW}${LINK}${PLAIN}"
echo -e "----------------------------------------"

# --- Sing-box 客户端配置 ---
echo -e "📱 [Sing-box 客户端配置块]:"
echo -e "${YELLOW}"

if [[ "$TYPE" == "anytls" ]]; then
cat <<EOF
{
  "type": "anytls",
  "tag": "proxy-out",
  "server": "${SERVER_ADDR}",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "padding_scheme": [],
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": { "enabled": true, "public_key": "${PBK}", "short_id": "${SID}" }
  }
}
EOF
elif [[ "$TYPE" == "vless" ]]; then
cat <<EOF
{
  "type": "vless",
  "tag": "proxy-out",
  "server": "${SERVER_ADDR}",
  "server_port": ${PORT},
  "uuid": "${UUID}",
  "flow": "${FLOW}",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": { "enabled": true, "public_key": "${PBK}", "short_id": "${SID}" }
  },
  "transport": { "type": "${TRANSPORT}", "path": "${WS_PATH}" }
}
EOF
elif [[ "$TYPE" == "hysteria2" ]]; then
INSECURE_BOOL="false"
[[ "$SKIP_CERT_VERIFY" == "true" ]] && INSECURE_BOOL="true"
cat <<EOF
{
  "type": "hysteria2",
  "tag": "proxy-out",
  "server": "${SERVER_ADDR}",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "insecure": ${INSECURE_BOOL}
  },
  "obfs": {
    "type": "salamander",
    "password": "${OBFS_PASS}"
  }
}
EOF
fi
echo -e "${PLAIN}----------------------------------------"

# --- OpenClash 配置 (分流处理) ---
if [[ "$TYPE" == "vless" ]]; then
    # VLESS 的 OpenClash 配置
    OC_TLS="true"
    OC_FLOW="$FLOW"
    OC_NET="$TRANSPORT"
    OC_OPTS=""
    if [[ "$REALITY" == "true" ]]; then
        OC_OPTS="  reality-opts:
    public-key: $PBK
    short-id: $SID"
    fi
    if [[ "$TRANSPORT" == "ws" ]]; then
         OC_OPTS="$OC_OPTS
  ws-opts:
    path: \"$WS_PATH\"
    headers:
      Host: $SNI"
    fi
    
    echo -e "🐱 [Clash Meta / OpenClash 配置块]:"
    echo -e "${YELLOW}"
cat <<EOF
- name: "${NODE_TAG}"
  type: vless
  server: ${SERVER_ADDR}
  port: ${PORT}
  uuid: ${UUID}
  network: ${OC_NET}
  tls: ${OC_TLS}
  udp: true
  flow: ${OC_FLOW}
  servername: ${SNI}
  client-fingerprint: chrome
${OC_OPTS}
EOF
    echo -e "${PLAIN}----------------------------------------"

elif [[ "$TYPE" == "hysteria2" ]]; then
    # Hysteria2 的 OpenClash 配置
    echo -e "🐱 [Clash Meta / OpenClash 配置块]:"
    echo -e "${YELLOW}"
cat <<EOF
- name: "${NODE_TAG}"
  type: hysteria2
  server: ${SERVER_ADDR}
  port: ${PORT}
  password: "${PASSWORD}"
  sni: "${SNI}"
  skip-cert-verify: ${SKIP_CERT_VERIFY}
  obfs: salamander
  obfs-password: "${OBFS_PASS}"
EOF
    echo -e "${PLAIN}----------------------------------------"

elif [[ "$TYPE" == "anytls" ]]; then
    # AnyTLS 不支持 Clash
    echo -e "${YELLOW}⚠️  OpenClash / Clash Meta 不支持 AnyTLS 协议，跳过生成配置。${PLAIN}"
    echo -e "----------------------------------------"
fi

# 警告信息
if [[ "$IS_SERVER" == "true" && -n "$REALITY" && -z "$PBK" && "$TYPE" == "vless" ]]; then
    echo -e "${RED}严重警告: 未找到 Reality Public Key。${PLAIN}"
    echo -e "原因: 这是一个旧版脚本创建的节点，没有保存公钥元数据。"
    echo -e "建议: 删除此节点并重新添加。"
fi
echo ""
