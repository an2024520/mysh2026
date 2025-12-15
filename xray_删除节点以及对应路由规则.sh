#!/bin/bash

# ============================================================
#  模块四 (v2.0)：智能级联拆除工具 (清理节点 + 清理关联路由)
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

echo -e "${RED}>>> [模块四] 智能节点拆除工具 (级联清理版)...${PLAIN}"

# 1. 检查配置文件
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 找不到配置文件！${PLAIN}"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    apt update -y && apt install -y jq
fi

# 2. 列出当前节点
echo -e "${YELLOW}正在读取当前运行的节点列表...${PLAIN}"
echo -e "----------------------------------------------------"
printf "%-25s %-10s %-15s\n" "节点标识 (Tag)" "端口" "协议"
echo -e "----------------------------------------------------"

NODE_COUNT=$(jq '.inbounds | length' "$CONFIG_FILE")
if [[ "$NODE_COUNT" == "0" ]]; then
    echo -e "${RED}当前没有配置任何节点！${PLAIN}"
    exit 0
fi

jq -r '.inbounds[] | "\(.tag) \(.port) \(.protocol)"' "$CONFIG_FILE" | while read -r tag port proto; do
    printf "${SKYBLUE}%-25s${PLAIN} ${GREEN}%-10s${PLAIN} %-15s\n" "$tag" "$port" "$proto"
done
echo -e "----------------------------------------------------"

# 3. 用户选择
echo -e "${YELLOW}请输入你想要删除的节点的 [端口号] ${PLAIN}"
read -p "目标端口: " TARGET_PORT

if [[ -z "$TARGET_PORT" ]]; then
    echo -e "操作已取消。"
    exit 0
fi

# 4. 关键步骤：先获取 Tag (为了后续清理路由)
# -----------------------------------------------------------
# 我们必须在删除节点之前，先查出它的 Tag 名字
TARGET_TAG=$(jq -r --argjson p "$TARGET_PORT" '.inbounds[] | select(.port == $p) | .tag' "$CONFIG_FILE")

if [[ -z "$TARGET_TAG" ]] || [[ "$TARGET_TAG" == "null" ]]; then
    echo -e "${RED}错误: 找不到端口为 $TARGET_PORT 的节点！${PLAIN}"
    exit 1
fi

echo -e "检测到目标节点 Tag: ${SKYBLUE}$TARGET_TAG${PLAIN}"

# 5. 执行级联删除
# -----------------------------------------------------------
echo -e "${YELLOW}正在备份配置...${PLAIN}"
cp "$CONFIG_FILE" "$BACKUP_FILE"

# 5.1 删除 inbound 节点
echo -e "${YELLOW}Step 1: 正在移除监听端口 $TARGET_PORT ...${PLAIN}"
tmp1=$(mktemp)
jq --argjson p "$TARGET_PORT" '.inbounds |= map(select(.port != $p))' "$CONFIG_FILE" > "$tmp1" && mv "$tmp1" "$CONFIG_FILE"

# 5.2 删除相关的 routing 规则 (清理幽灵规则)
# 逻辑：在 routing.rules 里，如果某个规则的 inboundTag 列表里包含了我们要删的 Tag，就把这条规则删掉
echo -e "${YELLOW}Step 2: 正在清理关联路由规则 (清理幽灵配置) ...${PLAIN}"
tmp2=$(mktemp)
jq --arg tag "$TARGET_TAG" '.routing.rules |= map(select(.inboundTag | index($tag) | not))' "$CONFIG_FILE" > "$tmp2" && mv "$tmp2" "$CONFIG_FILE"

# 6. 重启服务
echo -e "${YELLOW}正在重启 Xray 服务...${PLAIN}"
systemctl restart xray
sleep 1

if systemctl is-active --quiet xray; then
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    级联拆除成功！${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "1. 节点 [${TARGET_TAG}] 已被移除。"
    echo -e "2. 所有指向该节点的 WARP/分流规则 已被清理。"
    echo -e "----------------------------------------"
    echo -e "当前剩余节点数: $(jq '.inbounds | length' "$CONFIG_FILE")"
else
    echo -e "${RED}重启失败！正在回滚...${PLAIN}"
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    systemctl restart xray
    echo -e "已恢复备份。"
fi
