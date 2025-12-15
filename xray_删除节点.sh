#!/bin/bash

# ============================================================
#  模块四：节点查看与拆除工具 (拆迁队)
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

echo -e "${RED}>>> [模块四] 节点管理与拆除工具...${PLAIN}"

# 1. 检查配置文件是否存在
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 找不到配置文件！你还没有建立任何节点。${PLAIN}"
    exit 1
fi

# 检查 jq
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}正在安装 jq 工具...${PLAIN}"
    apt update -y && apt install -y jq
fi

# 2. 列出当前所有节点
echo -e "${YELLOW}正在读取当前运行的节点列表...${PLAIN}"
echo -e "----------------------------------------------------"
printf "%-25s %-10s %-15s\n" "节点标识 (Tag)" "端口" "协议"
echo -e "----------------------------------------------------"

# 使用 jq 解析并格式化输出
# 如果 inbounds 为空或不存在，这里不会输出内容
NODE_COUNT=$(jq '.inbounds | length' "$CONFIG_FILE")

if [[ "$NODE_COUNT" == "0" ]]; then
    echo -e "${RED}当前没有配置任何节点！${PLAIN}"
    exit 0
fi

jq -r '.inbounds[] | "\(.tag) \(.port) \(.protocol)"' "$CONFIG_FILE" | while read -r tag port proto; do
    printf "${SKYBLUE}%-25s${PLAIN} ${GREEN}%-10s${PLAIN} %-15s\n" "$tag" "$port" "$proto"
done
echo -e "----------------------------------------------------"

# 3. 用户选择要删除的节点
echo -e "${YELLOW}请输入你想要删除的节点的 [端口号] ${PLAIN}"
echo -e "(如果不想删除，请直接按回车退出)"
read -p "目标端口: " TARGET_PORT

if [[ -z "$TARGET_PORT" ]]; then
    echo -e "操作已取消。"
    exit 0
fi

# 4. 验证端口是否存在
# 使用 grep 简单查找 (jq 查找更严谨，但这里 grep 足够快)
if ! grep -q "\"port\": $TARGET_PORT" "$CONFIG_FILE"; then
    echo -e "${RED}错误: 找不到端口为 $TARGET_PORT 的节点！请检查输入。${PLAIN}"
    exit 1
fi

# 5. 执行删除
# 5.1 备份
echo -e "${YELLOW}正在备份配置文件到 $BACKUP_FILE ...${PLAIN}"
cp "$CONFIG_FILE" "$BACKUP_FILE"

# 5.2 使用 jq 剔除目标节点
# 逻辑: map(select(.port != 目标端口)) -> 重新组成数组
echo -e "${YELLOW}正在拆除端口 $TARGET_PORT ...${PLAIN}"
tmp=$(mktemp)
# 注意：这里我们要把 $TARGET_PORT 转为数字 (tonumber) 进行比较，或者确保 JSON 里是数字
jq --argjson p "$TARGET_PORT" '.inbounds |= map(select(.port != $p))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 6. 重启服务
echo -e "${YELLOW}正在重启 Xray 服务以应用更改...${PLAIN}"
systemctl restart xray
sleep 1

if systemctl is-active --quiet xray; then
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    拆除成功！节点已移除。${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "已移除端口: ${RED}$TARGET_PORT${PLAIN}"
    echo -e "当前剩余节点数: $(jq '.inbounds | length' "$CONFIG_FILE")"
else
    echo -e "${RED}警告: 重启失败！配置可能已损坏。${PLAIN}"
    echo -e "正在尝试恢复备份..."
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    systemctl restart xray
    echo -e "${YELLOW}已自动恢复到删除前的状态。请检查日志。${PLAIN}"
fi
