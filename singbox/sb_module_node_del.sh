#!/bin/bash

# ============================================================
# 脚本名称：sb_module_node_del.sh (v3.5 ListFix)
# 作用：深度清理 Sing-box 节点
# 修复：
# 1. 找回消失的 Inbound 节点列表 (解决只能看到 WARP 的 bug)
# 2. 保留 v3.4 的智能路由规则清洗逻辑
# 3. 适配 Sing-box 1.12+ Endpoints
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# ==========================================
# 1. 环境与配置检测
# ==========================================

CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 配置文件 config.json。${PLAIN}"
    exit 1
fi

META_FILE="${CONFIG_FILE}.meta"
BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%H%M%S)"

if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: 系统未安装 jq。${PLAIN}"
    exit 1
fi

# ==========================================
# 2. 交互式选择节点 (核心修复区域)
# ==========================================

echo -e "${GREEN}正在读取当前节点列表...${PLAIN}"

# --- 修复开始 ---
# 1. 读取 Inbounds (服务端节点 - VLESS/Hy2/AnyTLS 等)
# v3.4 漏掉了这一行，导致无法显示你添加的入站节点，这里补上并加上标识
NODES_IN=$(jq -r '.inbounds[]? | .tag + " [Server-In]"' "$CONFIG_FILE")

# 2. 读取 Outbounds (客户端/系统节点)
# 沿用 v3.2 的严格过滤，排除 direct/block/dns 等系统保留标签
NODES_OUT=$(jq -r '.outbounds[]? | select(.type!="direct" and .type!="block" and .type!="dns" and .type!="selector" and .type!="urltest" and .type!="loopback") | .tag + " [Client-Out]"' "$CONFIG_FILE")

# 3. 读取 Endpoints (WARP 等新版节点)
NODES_EP=$(jq -r '.endpoints[]? | .tag + " [Endpoint]"' "$CONFIG_FILE")
# --- 修复结束 ---

# 合并列表
ALL_NODES=$(echo -e "$NODES_IN\n$NODES_OUT\n$NODES_EP" | sed '/^$/d')

if [[ -z "$ALL_NODES" ]]; then
    echo -e "${YELLOW}未检测到可删除的自定义节点。${PLAIN}"
    exit 0
fi

declare -a NODE_ARRAY
i=1
echo -e "------------------------------------------------"
echo -e " 序号 | 节点标签 (Tag)"
echo -e "------------------------------------------------"

while IFS= read -r line; do
    # 提取纯 Tag 用于后续删除逻辑 (去掉 [Server-In] 等后缀)
    raw_tag=$(echo "$line" | awk '{print $1}')
    NODE_ARRAY[$i]="$raw_tag"
    echo -e "  $i   | ${SKYBLUE}$line${PLAIN}"
    ((i++))
done <<< "$ALL_NODES"

echo -e "------------------------------------------------"
echo -e "${YELLOW}请输入要删除的节点序号 (空格分隔)${PLAIN}"
echo -e "${RED}注意：将自动清理关联的路由规则，确保 Sing-box 正常重启。${PLAIN}"
read -p "请选择: " selection

if [[ -z "$selection" ]]; then echo -e "${YELLOW}取消操作。${PLAIN}"; exit 0; fi

# ==========================================
# 3. 执行删除 (高级 JQ 逻辑 - v3.4版)
# ==========================================

declare -a DELETE_TAGS
for num in $selection; do
    if [[ -n "${NODE_ARRAY[$num]}" ]]; then
        tag="${NODE_ARRAY[$num]}"
        DELETE_TAGS+=("$tag")
        echo -e "准备删除: ${RED}$tag${PLAIN}"
    fi
done

[[ ${#DELETE_TAGS[@]} -eq 0 ]] && exit 1

echo -e "${YELLOW}正在备份配置文件...${PLAIN}"
cp "$CONFIG_FILE" "$BACKUP_FILE"

JSON_TAGS=$(printf '%s\n' "${DELETE_TAGS[@]}" | jq -R . | jq -s .)
TMP_FILE=$(mktemp)

echo -e "${YELLOW}正在智能清洗 Config & Routes...${PLAIN}"

# v3.4 核心逻辑保持不变 (智能清洗路由)
jq --argjson tags "$JSON_TAGS" '
    # 1. 删除节点定义
    del(.inbounds[]? | select(.tag as $t | $tags | index($t))) | 
    del(.outbounds[]? | select(.tag as $t | $tags | index($t))) |
    del(.endpoints[]? | select(.tag as $t | $tags | index($t))) |
    
    # 2. 删除以被删节点为目标的规则 (outbound == tag)
    del(.route.rules[]? | select(.outbound as $o | $tags | index($o))) |

    # 3. 清洗引用了被删节点的规则 (inbound 包含 tag)
    .route.rules |= map(
        if .inbound then
            # 将 inbound 转为数组，然后减去我们要删除的 tags
            (.inbound | if type=="array" then . else [.] end) - $tags |
            # 如果减完后为空，则丢弃该规则
            if length == 0 then empty 
            # 否则更新规则
            else . as $new_ib | ($$ | .inbound = $new_ib) end
        else
            .
        end
    )
' "$CONFIG_FILE" > "$TMP_FILE"

if [[ $? -eq 0 && -s "$TMP_FILE" ]]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    echo -e "${GREEN}配置清理完成。${PLAIN}"
else
    echo -e "${RED}错误: JSON 处理失败，已恢复备份。${PLAIN}"
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    rm "$TMP_FILE"
    exit 1
fi

# 处理 Meta 文件
if [[ -f "$META_FILE" ]]; then
    TMP_META=$(mktemp)
    jq --argjson tags "$JSON_TAGS" 'del(.[$tags[]])' "$META_FILE" > "$TMP_META" && mv "$TMP_META" "$META_FILE"
fi

# ==========================================
# 5. 重启服务
# ==========================================
echo -e "${YELLOW}正在重启 Sing-box 服务...${PLAIN}"
if systemctl list-unit-files | grep -q sing-box; then
    systemctl restart sing-box
else
    pkill -xf "sing-box run -c $CONFIG_FILE"
    nohup sing-box run -c "$CONFIG_FILE" > /dev/null 2>&1 &
fi

sleep 2
if systemctl is-active --quiet sing-box || pgrep -x "sing-box" >/dev/null; then
    echo -e "${GREEN}操作成功！${PLAIN}"
    # 清理证书
    for tag in "${DELETE_TAGS[@]}"; do
        rm -f "/usr/local/etc/sing-box/cert/${tag}.crt" 2>/dev/null
        rm -f "/usr/local/etc/sing-box/cert/${tag}.key" 2>/dev/null
    done
else
    echo -e "${RED}重启失败！可能因残留配置导致，已回滚。${PLAIN}"
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    systemctl restart sing-box
fi
