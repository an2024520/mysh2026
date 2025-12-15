#!/bin/bash

# ============================================================
#  模块七：节点分流解除器 (恢复直连 / 移除 WARP 挂载)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/usr/local/etc/xray/config.json.bak"

echo -e "${GREEN}>>> [模块七] 节点分流解除器 (Reset to Direct)...${PLAIN}"

# 1. 基础检查
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 配置文件不存在。${PLAIN}"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    apt update -y && apt install -y jq
fi

# 2. 列出当前被“劫持”分流的节点
# -----------------------------------------------------------
echo -e "${YELLOW}正在扫描当前的路由规则...${PLAIN}"
echo -e "----------------------------------------------------"
printf "%-25s %-20s\n" "输入节点 (Inbound)" "出口去向 (Outbound)"
echo -e "----------------------------------------------------"

# 使用 jq 扫描 routing.rules
# 逻辑：查找所有包含 inboundTag 的规则
RULE_COUNT=$(jq '.routing.rules | length' "$CONFIG_FILE")

if [[ "$RULE_COUNT" == "0" ]]; then
    echo -e "${SKYBLUE}当前没有任何特殊的路由规则。所有节点都是直连的。${PLAIN}"
    exit 0
fi

# 打印规则列表
jq -r '.routing.rules[] | select(.inboundTag != null) | "\(.inboundTag[]) \(.outboundTag)"' "$CONFIG_FILE" | while read -r in_tag out_tag; do
    printf "${SKYBLUE}%-25s${PLAIN} -> ${YELLOW}%-20s${PLAIN}\n" "$in_tag" "$out_tag"
done
echo -e "----------------------------------------------------"

# 3. 用户选择要恢复的节点
# -----------------------------------------------------------
echo -e "${YELLOW}请输入你想要恢复直连的节点的 [端口号]${PLAIN}"
echo -e "(脚本会自动查找该端口对应的 Tag 并移除相关路由规则)"

read -p "目标端口: " TARGET_PORT

if [[ -z "$TARGET_PORT" ]]; then
    echo -e "操作取消。"
    exit 0
fi

# 根据端口找 Tag
TARGET_NODE_TAG=$(jq -r --argjson p "$TARGET_PORT" '.inbounds[] | select(.port == $p) | .tag' "$CONFIG_FILE")

if [[ -z "$TARGET_NODE_TAG" ]] || [[ "$TARGET_NODE_TAG" == "null" ]]; then
    echo -e "${RED}错误: 找不到端口为 $TARGET_PORT 的节点。${PLAIN}"
    exit 1
fi

echo -e "目标节点 Tag: ${GREEN}$TARGET_NODE_TAG${PLAIN}"

# 4. 执行移除操作
# -----------------------------------------------------------
echo -e "${YELLOW}正在移除相关的路由规则...${PLAIN}"

# 备份
cp "$CONFIG_FILE" "$BACKUP_FILE"

# 核心逻辑：
# 遍历 routing.rules 数组，剔除掉那个 "inboundTag 包含 目标Tag" 的规则
# map(select(条件)) -> 只保留符合条件的
# 条件：(.inboundTag | index($tag) | not) -> 意思是：inboundTag 数组里 找不到 目标Tag
tmp=$(mktemp)
jq --arg tag "$TARGET_NODE_TAG" '.routing.rules |= map(select(.inboundTag | index($tag) | not))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 5. 重启与验证
# -----------------------------------------------------------
systemctl restart xray
sleep 1

if systemctl is-active --quiet xray; then
    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [模块七] 恢复成功！                ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "端口 ${YELLOW}${TARGET_PORT}${PLAIN} 现在已恢复为 **直连模式**。"
    echo -e "出口 IP 已变回你的 VPS 原生 IP。"
    echo -e "----------------------------------------"
else
    echo -e "${RED}重启失败！正在回滚...${PLAIN}"
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    systemctl restart xray
    echo -e "已恢复到修改前的状态。"
fi
