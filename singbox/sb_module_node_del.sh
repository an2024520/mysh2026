#!/bin/bash

# ============================================================
# 脚本名称：sb_module_node_del.sh
# 作用：交互式删除 Sing-box 节点 (同时清理 config.json 和 .meta)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 自动寻路
# ------------------------------------------------
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then
        CONFIG_FILE="$p"
        break
    fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 配置文件。${PLAIN}"
    exit 1
fi

META_FILE="${CONFIG_FILE}.meta"
echo -e "${GREEN}读取配置: $CONFIG_FILE${PLAIN}"

# 检查 jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: 未安装 jq${PLAIN}"
    exit 1
fi

# 2. 列出可删除节点 (排除系统保留节点)
# ------------------------------------------------
# 同时扫描 Inbounds (服务端) 和 Outbounds (客户端)
# 排除 direct, block, dns, selector, urltest
echo -e "正在扫描可删除的节点..."

LIST_IN=$(jq -r '.inbounds[]? | select(.type=="vless" or .type=="vmess" or .type=="hysteria2") | .tag + " [Server-In]"' "$CONFIG_FILE")
LIST_OUT=$(jq -r '.outbounds[]? | select(.type!="direct" and .type!="block" and .type!="dns" and .type!="selector" and .type!="urltest") | .tag + " [Client-Out]"' "$CONFIG_FILE")

IFS=$'\n' read -d '' -r -a ALL_NODES <<< "$LIST_IN"$'\n'"$LIST_OUT"

# 清理空数组元素
NODES=()
for item in "${ALL_NODES[@]}"; do
    [[ -n "$item" ]] && NODES+=("$item")
done

if [[ ${#NODES[@]} -eq 0 ]]; then
    echo -e "${YELLOW}当前没有可以删除的代理节点。${PLAIN}"
    exit 0
fi

echo -e "-------------------------------------------"
i=1
for node in "${NODES[@]}"; do
    echo -e " ${GREEN}$i.${PLAIN} $node"
    let i++
done
echo -e "-------------------------------------------"

# 3. 交互选择
# ------------------------------------------------
read -p "请输入要删除的节点序号 (回车取消): " CHOICE
if [[ -z "$CHOICE" ]]; then echo "操作取消"; exit 0; fi

INDEX=$((CHOICE-1))
RAW_SELECTION="${NODES[$INDEX]}"

if [[ -z "$RAW_SELECTION" ]]; then
    echo -e "${RED}无效的选择。${PLAIN}"
    exit 1
fi

# 提取纯 Tag
NODE_TAG=$(echo "$RAW_SELECTION" | awk '{print $1}')

echo -e "即将删除节点: ${RED}$NODE_TAG${PLAIN}"
read -p "确认删除吗? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then echo "操作取消"; exit 0; fi

# 4. 执行删除
# ------------------------------------------------
echo -e "${YELLOW}正在处理配置文件...${PLAIN}"

TMP_FILE=$(mktemp)

# A. 从 config.json 中删除 (同时尝试从 inbounds 和 outbounds 删)
jq --arg tag "$NODE_TAG" '
    del(.inbounds[]? | select(.tag == $tag)) | 
    del(.outbounds[]? | select(.tag == $tag))
' "$CONFIG_FILE" > "$TMP_FILE"

if [ $? -eq 0 ]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    echo -e "${GREEN}主配置清理完成。${PLAIN}"
else
    echo -e "${RED}主配置删除失败 (jq Error)。${PLAIN}"
    rm "$TMP_FILE"
    exit 1
fi

# B. 从 .meta 文件中删除 (如果存在)
if [[ -f "$META_FILE" ]]; then
    TMP_META=$(mktemp)
    jq --arg tag "$NODE_TAG" 'del(.[$tag])' "$META_FILE" > "$TMP_META"
    if [ $? -eq 0 ]; then
        mv "$TMP_META" "$META_FILE"
        echo -e "${GREEN}元数据清理完成。${PLAIN}"
    fi
fi

# 5. 重启服务
# ------------------------------------------------
echo -e "${YELLOW}正在重启服务...${PLAIN}"
systemctl restart sing-box

if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}删除成功，服务运行正常！${PLAIN}"
else
    echo -e "${RED}警告: 服务重启失败，请检查配置文件是否损坏。${PLAIN}"
    echo -e "日志检查: journalctl -u sing-box -e"
fi
