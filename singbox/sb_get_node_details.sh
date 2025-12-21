#!/bin/bash

# =================================================
# 脚本名称：sb_get_node_details.sh
# 作用：读取 Sing-box 的 JSON 配置文件，提取指定 Tag 的节点，并逆向生成分享链接
# 依赖：jq
# 用法：./sb_get_node_details.sh <config_path> <node_tag>
# =================================================

CONFIG_FILE="$1"
NODE_TAG="$2"

if [[ -z "$CONFIG_FILE" || -z "$NODE_TAG" ]]; then
    echo "Usage: $0 <config_path> <node_tag>"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed."
    exit 1
fi

# -------------------------------------------------
# 辅助函数：URL 编码 (填坑的关键)
# -------------------------------------------------
urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * )               printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# -------------------------------------------------
# 1. 从 JSON 中提取对应 Tag 的 Outbound 对象
# -------------------------------------------------
# 注意：Sing-box 的结构通常是 { "outbounds": [ ... ] }
NODE_JSON=$(jq -r --arg tag "$NODE_TAG" '.outbounds[] | select(.tag==$tag)' "$CONFIG_FILE")

if [[ -z "$NODE_JSON" ]]; then
    echo "Error: Node with tag '$NODE_TAG' not found."
    exit 1
fi

# 提取基础信息
TYPE=$(echo "$NODE_JSON" | jq -r '.type')
SERVER=$(echo "$NODE_JSON" | jq -r '.server // empty')
PORT=$(echo "$NODE_JSON" | jq -r '.server_port // empty')
UUID=$(echo "$NODE_JSON" | jq -r '.uuid // empty')
PASSWORD=$(echo "$NODE_JSON" | jq -r '.password // empty')

# 如果没有 server 或 port，可能不是代理节点（如 selector, urltest），直接返回 JSON
if [[ -z "$SERVER" || -z "$PORT" ]]; then
    echo "Info: Not a standard proxy node (Missing server/port). Dumping JSON:"
    echo "$NODE_JSON"
    exit 0
fi

# -------------------------------------------------
# 2. 根据协议类型拼装链接
# -------------------------------------------------

LINK=""

case "$TYPE" in
    "vless")
        # --- VLESS 拼装逻辑 ---
        # 提取传输层和安全层信息
        FLOW=$(echo "$NODE_JSON" | jq -r '.flow // empty')
        TLS_TYPE=$(echo "$NODE_JSON" | jq -r '.tls.enabled // "false"')
        TRANSPORT=$(echo "$NODE_JSON" | jq -r '.transport.type // "tcp"')
        
        # 构建参数
        PARAMS="security=none"
        if [[ "$TLS_TYPE" == "true" ]]; then
            # 判断是 TLS 还是 Reality
            REALITY=$(echo "$NODE_JSON" | jq -r '.tls.reality.enabled // "false"')
            if [[ "$REALITY" == "true" ]]; then
                PARAMS="security=reality"
                PBK=$(echo "$NODE_JSON" | jq -r '.tls.reality.public_key // empty')
                SNI=$(echo "$NODE_JSON" | jq -r '.tls.server_name // empty')
                SID=$(echo "$NODE_JSON" | jq -r '.tls.reality.short_id // empty')
                FP=$(echo "$NODE_JSON" | jq -r '.tls.utls.fingerprint // "chrome"')
                
                [[ -n "$PBK" ]] && PARAMS+="&pbk=$PBK"
                [[ -n "$SNI" ]] && PARAMS+="&sni=$SNI"
                [[ -n "$SID" ]] && PARAMS+="&sid=$SID"
                [[ -n "$FP" ]] && PARAMS+="&fp=$FP"
            else
                PARAMS="security=tls"
                SNI=$(echo "$NODE_JSON" | jq -r '.tls.server_name // empty')
                [[ -n "$SNI" ]] && PARAMS+="&sni=$SNI"
            fi
        fi

        # 拼接传输层参数 (ws, grpc 等)
        PARAMS+="&type=$TRANSPORT"
        if [[ "$TRANSPORT" == "ws" ]]; then
            WS_PATH=$(echo "$NODE_JSON" | jq -r '.transport.path // "/"')
            WS_HOST=$(echo "$NODE_JSON" | jq -r '.transport.headers.Host // empty')
            PARAMS+="&path=$(urlencode "$WS_PATH")"
            [[ -n "$WS_HOST" ]] && PARAMS+="&host=$(urlencode "$WS_HOST")"
        elif [[ "$TRANSPORT" == "grpc" ]]; then
            SERVICE_NAME=$(echo "$NODE_JSON" | jq -r '.transport.service_name // empty')
            [[ -n "$SERVICE_NAME" ]] && PARAMS+="&serviceName=$(urlencode "$SERVICE_NAME")"
        fi

        # XTLS Flow
        [[ -n "$FLOW" ]] && PARAMS+="&flow=$FLOW"

        # 最终拼接 VLESS 链接
        # 格式: vless://uuid@host:port?params#tag
        LINK="vless://${UUID}@${SERVER}:${PORT}?${PARAMS}#$(urlencode "$NODE_TAG")"
        ;;

    "vmess")
        # --- VMESS 拼装逻辑 (JSON -> Base64) ---
        # VMess 链接通常是 base64 编码的一个 JSON 对象
        # 我们需要构造这个标准 JSON 结构 (VMess Link Standard)
        
        ALTER_ID=$(echo "$NODE_JSON" | jq -r '.alter_id // 0')
        NET=$(echo "$NODE_JSON" | jq -r '.transport.type // "tcp"')
        TLS_ENABLED=$(echo "$NODE_JSON" | jq -r '.tls.enabled // "false"')
        
        # 默认为 none
        VMESS_TLS=""
        if [[ "$TLS_ENABLED" == "true" ]]; then VMESS_TLS="tls"; fi

        # 构造 VMess 标准 JSON 对象
        # 注意：这里需要根据 Transport 细化字段，这里提供最简通用模板
        VMESS_OBJ=$(jq -n \
            --arg v "2" \
            --arg ps "$NODE_TAG" \
            --arg add "$SERVER" \
            --arg port "$PORT" \
            --arg id "$UUID" \
            --arg aid "$ALTER_ID" \
            --arg net "$NET" \
            --arg type "none" \
            --arg tls "$VMESS_TLS" \
            '{v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:$aid, net:$net, type:$type, host:"", path:"", tls:$tls}')
        
        # 如果是 WS，需要补全 path 和 host
        if [[ "$NET" == "ws" ]]; then
            WS_PATH=$(echo "$NODE_JSON" | jq -r '.transport.path // "/"')
            WS_HOST=$(echo "$NODE_JSON" | jq -r '.transport.headers.Host // ""')
            VMESS_OBJ=$(echo "$VMESS_OBJ" | jq --arg path "$WS_PATH" --arg host "$WS_HOST" '.path=$path | .host=$host')
        fi

        # Base64 编码
        B64_VMESS=$(echo -n "$VMESS_OBJ" | base64 -w 0)
        LINK="vmess://${B64_VMESS}"
        ;;
    
    "hysteria2")
        # --- Hysteria2 拼装逻辑 ---
        # 格式: hysteria2://password@server:port?params#tag
        # 参数映射需要特别注意 Singbox 字段
        
        PARAMS="insecure=0"
        SNI=$(echo "$NODE_JSON" | jq -r '.tls.server_name // empty')
        INSECURE=$(echo "$NODE_JSON" | jq -r '.tls.insecure // "false"')
        OBFS_PASS=$(echo "$NODE_JSON" | jq -r '.obfs.password // empty')

        [[ -n "$SNI" ]] && PARAMS+="&sni=$SNI"
        if [[ "$INSECURE" == "true" ]]; then PARAMS+="&insecure=1"; fi
        [[ -n "$OBFS_PASS" ]] && PARAMS+="&obfs=salamander&obfs-password=$OBFS_PASS"

        LINK="hysteria2://${PASSWORD}@${SERVER}:${PORT}?${PARAMS}#$(urlencode "$NODE_TAG")"
        ;;

    *)
        echo "Warning: Protocol '$TYPE' conversion logic not fully implemented yet. Dumping JSON."
        echo "$NODE_JSON"
        exit 0
        ;;
esac

# -------------------------------------------------
# 3. 输出结果
# -------------------------------------------------
echo "$LINK"
