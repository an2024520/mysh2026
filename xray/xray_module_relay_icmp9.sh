#!/bin/bash

# ============================================================
#  ICMP9 中转扩展模块 (PRO: Multi-User Routing)
#  - 核心修复: 解决同端口多路径监听导致的端口冲突崩溃问题
#  - 实现原理: 单端口(WS) + 多用户(UUID) -> 动态路由分流
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/usr/local/etc/xray/config.json.bak"
API_CONFIG="https://api.icmp9.com/config/config.txt"
API_NODES="https://api.icmp9.com/online.php"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ============================================================
# 1. 智能提取现有配置
# ============================================================
check_env() {
    echo -e "${YELLOW}>>> [自检] 正在扫描现有 Tunnel 节点...${PLAIN}"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 未找到 Xray 配置文件，请先部署 VLESS+WS 隧道。${PLAIN}"; exit 1
    fi

    # 提取监听 127.0.0.1 的 VLESS+WS 节点信息
    # 我们需要获取它的: 端口, 路径, 和原始配置块的索引
    TARGET_INDEX=$(jq -r '
        .inbounds | to_entries | map(select(.value.listen == "127.0.0.1" and .value.streamSettings.network == "ws")) | .[0].key
    ' "$CONFIG_FILE")

    if [[ "$TARGET_INDEX" == "null" ]]; then
        echo -e "${RED}错误: 未自动识别到本地监听的 WS 隧道节点。${PLAIN}"
        read -p "请确认是否手动继续? (y/n): " c
        [[ "$c" != "y" ]] && exit 1
        # 手动兜底逻辑暂略，建议用户先跑通隧道
        exit 1
    fi

    # 提取关键参数供后续使用
    LOCAL_PORT=$(jq -r ".inbounds[$TARGET_INDEX].port" "$CONFIG_FILE")
    # 提取现有路径 (如果为空则默认为 /)
    LOCAL_PATH=$(jq -r ".inbounds[$TARGET_INDEX].streamSettings.wsSettings.path // \"/\"" "$CONFIG_FILE")
    
    echo -e "${GREEN}>>> 锁定目标节点:${PLAIN}"
    echo -e "    索引: [${TARGET_INDEX}] | 端口: ${LOCAL_PORT} | 路径: ${LOCAL_PATH}"

    # 严格 IPv6 检测
    if ! curl -4 -s -m 5 http://ip.sb >/dev/null; then
        echo -e "${YELLOW}>>> 优化 IPv6 DNS...${PLAIN}"
        if ! grep -q "2001:4860:4860::8888" /etc/resolv.conf; then
            chattr -i /etc/resolv.conf
            echo -e "nameserver 2001:4860:4860::8888\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf
            chattr +i /etc/resolv.conf
        fi
    fi
}

get_user_input() {
    echo -e "----------------------------------------------------"
    while true; do
        read -p "请输入 ICMP9 授权 KEY (UUID): " REMOTE_UUID
        if [[ -n "$REMOTE_UUID" ]]; then break; fi
    done
    DEFAULT_DOMAIN=${ARGO_DOMAIN}
    read -p "请输入 Argo 隧道域名 (默认为 $DEFAULT_DOMAIN): " ARGO_DOMAIN
    ARGO_DOMAIN=${ARGO_DOMAIN:-$DEFAULT_DOMAIN}
    [[ -z "$ARGO_DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1
}

# ============================================================
# 2. 核心注入逻辑 (UUID 分流架构)
# ============================================================
inject_config() {
    echo -e "${YELLOW}>>> [配置] 获取节点数据与重构路由...${PLAIN}"
    
    NODES_JSON=$(curl -s "$API_NODES")
    if ! echo "$NODES_JSON" | jq -e . >/dev/null 2>&1; then
         echo -e "${RED}错误: API 请求失败。${PLAIN}"; exit 1
    fi
    
    RAW_CFG=$(curl -s "$API_CONFIG")
    R_HOST=$(echo "$RAW_CFG" | grep "^host|" | cut -d'|' -f2 | tr -d '\r\n')
    R_PORT=$(echo "$RAW_CFG" | grep "^port|" | cut -d'|' -f2 | tr -d '\r\n')
    R_WSHOST=$(echo "$RAW_CFG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
    R_TLS="none"; [[ $(echo "$RAW_CFG" | grep "^tls|" | cut -d'|' -f2) == "1" ]] && R_TLS="tls"

    cp "$CONFIG_FILE" "$BACKUP_FILE"

    # 1. 清理旧 ICMP9 出站和规则
    jq '
      .outbounds |= map(select(.tag | startswith("icmp9-") | not)) |
      .routing.rules |= map(select(.outboundTag | startswith("icmp9-") | not))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 2. 准备新的客户列表 (Clients) 和其他配置
    # 先保留原有的第一个用户 (作为默认回落或直连用户)
    EXISTING_CLIENTS=$(jq -c ".inbounds[$TARGET_INDEX].settings.clients[0:1]" "$CONFIG_FILE")
    
    echo "[]" > /tmp/new_outbounds.json
    echo "[]" > /tmp/new_rules.json
    # 初始化 clients 列表，先放入原用户
    echo "$EXISTING_CLIENTS" > /tmp/new_clients.json

    # 3. 循环生成
    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        
        # 生成专用 UUID 和 Email (作为路由标记)
        # 这里使用 xargs 去掉引号，并确保生成新 UUID
        NEW_UUID=$(/usr/local/bin/xray_core/xray uuid)
        USER_EMAIL="icmp9-${CODE}"
        TAG_OUT="icmp9-out-${CODE}"
        PATH_OUT="/${CODE}"

        # 3.1 追加用户到 Clients 列表
        # 注意：所有用户共用同一个入站端口和路径，靠 Email/UUID 区分
        jq --arg uuid "$NEW_UUID" --arg email "$USER_EMAIL" \
           '. + [{"id": $uuid, "email": $email}]' \
           /tmp/new_clients.json > /tmp/new_clients.json.tmp && mv /tmp/new_clients.json.tmp /tmp/new_clients.json

        # 3.2 生成出站 (Outbound)
        jq -n \
           --arg tag "$TAG_OUT" --arg host "$R_HOST" --arg port "$R_PORT" \
           --arg uuid "$REMOTE_UUID" --arg wshost "$R_WSHOST" --arg tls "$R_TLS" --arg path "$PATH_OUT" \
           '{
              "tag": $tag, "protocol": "vmess",
              "settings": { "vnext": [{"address": $host, "port": ($port | tonumber), "users": [{"id": $uuid}]}] },
              "streamSettings": { "network": "ws", "security": $tls, 
                "tlsSettings": (if $tls == "tls" then {"serverName": $wshost} else null end),
                "wsSettings": { "path": $path, "headers": {"Host": $wshost} } }
           }' >> /tmp/outbound_block.json

        # 3.3 生成路由规则 (基于 User Email)
        jq -n \
           --arg email "$USER_EMAIL" \
           --arg outTag "$TAG_OUT" \
           '{ "type": "field", "user": [$email], "outboundTag": $outTag }' >> /tmp/rule_block.json
           
        # 保存 UUID 映射关系供最后输出链接使用
        echo "${CODE}|${NEW_UUID}" >> /tmp/uuid_map.txt
    done

    # 4. 合并并注入
    jq -s '.' /tmp/outbound_block.json > /tmp/final_outbounds.json
    jq -s '.' /tmp/rule_block.json > /tmp/final_rules.json
    
    # 注入 Clients 到指定的 Inbound
    # 这里使用 tricky 的 jq 语法更新特定 index 的 clients
    jq --slurpfile new_clients /tmp/new_clients.json \
       --argjson idx "$TARGET_INDEX" \
       '.inbounds[$idx].settings.clients = $new_clients[0]' \
       "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 注入 Outbounds
    jq --slurpfile new_outs /tmp/final_outbounds.json '.outbounds += $new_outs[0]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    # 注入 Routing (置顶)
    jq --slurpfile new_rules /tmp/final_rules.json '.routing.rules = ($new_rules[0] + .routing.rules)' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    rm -f /tmp/new_clients.json /tmp/outbound_block.json /tmp/rule_block.json /tmp/final_*.json /tmp/new_clients.json.tmp
}

# ============================================================
# 3. 验证与输出
# ============================================================
finish_setup() {
    echo -e "${YELLOW}>>> [重启] 应用配置...${PLAIN}"
    systemctl restart xray
    sleep 2
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}失败: Xray 崩溃，正在回滚...${PLAIN}"; cp "$BACKUP_FILE" "$CONFIG_FILE"; systemctl restart xray; exit 1
    fi

    echo -e "\n${GREEN}======================================================${PLAIN}"
    echo -e "${GREEN}   ICMP9 中转部署成功 (Multi-User Mode)               ${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "核心优势: 单端口无冲突，无需修改 Cloudflare 配置"
    echo -e "WS 路径 : ${YELLOW}${LOCAL_PATH}${PLAIN} (所有节点共用)"
    echo -e "------------------------------------------------------"
    
    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        NAME=$(echo "$node" | jq -r '.name')
        EMOJI=$(echo "$node" | jq -r '.emoji')
        
        # 从映射文件取回刚才生成的专用 UUID
        UUID=$(grep "^${CODE}|" /tmp/uuid_map.txt | cut -d'|' -f2)
        NODE_ALIAS="${EMOJI} ${NAME} [中转]"
        
        # 生成链接: 使用统一的 Path，但不同的 UUID
        LINK="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${LOCAL_PATH}#${NODE_ALIAS}"
        LINK=${LINK// /%20}
        
        echo -e "${SKYBLUE}${LINK}${PLAIN}"
    done
    rm -f /tmp/uuid_map.txt
    echo -e "------------------------------------------------------"
}

check_env
get_user_input
inject_config
finish_setup
