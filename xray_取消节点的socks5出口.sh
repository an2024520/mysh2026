#!/bin/bash

# ============================================================
#  模块七 (v3.0)：批量分流解除器 (支持 手动批量 / 一键全选)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/usr/local/etc/xray/config.json.bak"

echo -e "${GREEN}>>> [模块七] 智能分流解除器 (Reset to Direct v3.0)...${PLAIN}"

# 1. 基础检查
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 配置文件不存在。${PLAIN}"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    apt update -y && apt install -y jq
fi

# 2. 扫描并展示“被劫持”的节点
# -----------------------------------------------------------
echo -e "${YELLOW}正在扫描当前的路由规则...${PLAIN}"
echo -e "以下是目前 **正在使用代理/分流** 的节点："
echo -e "----------------------------------------------------"
printf "%-25s %-10s %-20s\n" "节点标识 (Tag)" "端口" "去向 (Outbound)"
echo -e "----------------------------------------------------"

# 定义数组存储所有可被恢复的端口
declare -a ALL_ROUTED_PORTS

# 逻辑复杂点：我们需要遍历 routing.rules，找到 inboundTag，再反查 inbounds 里的 port
# 使用 jq 提取所有包含 inboundTag 的规则，格式化为 "tag outbound"
# 使用 process substitution 避免管道子shell问题
while read -r in_tag out_tag; do
    # 根据 tag 反查端口
    PORT=$(jq -r --arg tag "$in_tag" '.inbounds[] | select(.tag == $tag) | .port' "$CONFIG_FILE")
    
    # 如果找到了对应的端口 (说明这个 tag 确实是一个有效的入站节点)
    if [[ "$PORT" =~ ^[0-9]+$ ]]; then
        printf "${SKYBLUE}%-25s${PLAIN} ${GREEN}%-10s${PLAIN} -> ${YELLOW}%-20s${PLAIN}\n" "$in_tag" "$PORT" "$out_tag"
        ALL_ROUTED_PORTS+=("$PORT")
    fi
done < <(jq -r '.routing.rules[] | select(.inboundTag != null) | "\(.inboundTag[]) \(.outboundTag)"' "$CONFIG_FILE")

echo -e "----------------------------------------------------"

ROUTED_COUNT=${#ALL_ROUTED_PORTS[@]}

if [[ "$ROUTED_COUNT" == "0" ]]; then
    echo -e "${GRAY}提示: 当前没有任何特殊的路由规则。所有节点都是直连的。${PLAIN}"
    exit 0
fi

# 3. 操作模式选择
# -----------------------------------------------------------
echo -e "${YELLOW}请选择操作模式:${PLAIN}"
echo -e "  1. ${GREEN}手动输入${PLAIN} (恢复特定端口，支持批量)"
echo -e "  2. ${RED}全部解除${PLAIN} (将列表中的 ${ROUTED_COUNT} 个节点全部恢复直连)"
read -p "请选择 [1-2]: " MODE_CHOICE

declare -a TARGET_PORTS_ARRAY

case $MODE_CHOICE in
    2)
        # === 模式 2: 全选 ===
        echo -e "${SKYBLUE}已选择全部解除。${PLAIN}"
        TARGET_PORTS_ARRAY=("${ALL_ROUTED_PORTS[@]}")
        ;;
    *)
        # === 模式 1: 手动 (默认) ===
        echo -e "${YELLOW}请输入要恢复直连的端口号 (支持批量)${PLAIN}"
        echo -e "说明: 用空格分隔多个端口，例如: ${GREEN}2053 8443${PLAIN}"
        read -p "目标端口: " INPUT_PORTS
        
        if [[ -z "$INPUT_PORTS" ]]; then
            echo -e "操作取消。"
            exit 0
        fi
        read -a TARGET_PORTS_ARRAY <<< "$INPUT_PORTS"
        ;;
esac

# 4. 批量执行解除
# -----------------------------------------------------------
echo -e "${YELLOW}正在清理路由规则...${PLAIN}"
cp "$CONFIG_FILE" "$BACKUP_FILE"
CHANGE_COUNT=0

for TARGET_PORT in "${TARGET_PORTS_ARRAY[@]}"; do
    # 验证数字
    if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}跳过: '$TARGET_PORT' 不是有效的端口号。${PLAIN}"
        continue
    fi

    # 查找 Tag
    TARGET_NODE_TAG=$(jq -r --argjson p "$TARGET_PORT" '.inbounds[] | select(.port == $p) | .tag' "$CONFIG_FILE")

    if [[ -z "$TARGET_NODE_TAG" ]] || [[ "$TARGET_NODE_TAG" == "null" ]]; then
        echo -e "${RED}跳过: 找不到端口为 $TARGET_PORT 的节点。${PLAIN}"
        continue
    fi

    # 检查是否真的在路由规则里 (防止手动输入了直连的节点)
    # 只要 routing.rules 里有这个 tag 就算
    IS_ROUTED=$(jq --arg tag "$TARGET_NODE_TAG" '.routing.rules[] | select(.inboundTag | index($tag))' "$CONFIG_FILE")
    
    if [[ -z "$IS_ROUTED" ]]; then
        echo -e "${GRAY}跳过: 节点 $TARGET_NODE_TAG 本来就是直连的。${PLAIN}"
        continue
    fi

    echo -e "  -> 恢复中: ${SKYBLUE}$TARGET_NODE_TAG${PLAIN} (${GREEN}$TARGET_PORT${PLAIN})"

    # 移除规则
    # 逻辑：删除 inboundTag 数组中包含该 tag 的所有规则
    # 注意：这会删除整条规则。由于我们在模块六是“一节点一规则”添加的，所以这样删是安全的。
    tmp=$(mktemp)
    jq --arg tag "$TARGET_NODE_TAG" '.routing.rules |= map(select(.inboundTag | index($tag) | not))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    
    ((CHANGE_COUNT++))
done

# 5. 重启与验证
# -----------------------------------------------------------
if [[ "$CHANGE_COUNT" -gt 0 ]]; then
    echo -e "----------------------------------------"
    echo -e "${YELLOW}正在重启 Xray 以应用 ${CHANGE_COUNT} 个更改...${PLAIN}"
    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}    解除成功！${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "已将 ${CHANGE_COUNT} 个节点恢复为 **直连模式**。"
        echo -e "出口 IP 已变回你的 VPS 原生 IP。"
    else
        echo -e "${RED}重启失败！正在回滚...${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart xray
    fi
else
    echo -e "${YELLOW}未做任何有效更改。${PLAIN}"
fi
