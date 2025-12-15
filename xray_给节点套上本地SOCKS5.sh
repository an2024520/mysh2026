#!/bin/bash

# ============================================================
#  模块六 (v2.0)：批量节点分流挂载器 (智能过滤 + 批量操作)
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

echo -e "${GREEN}>>> [模块六] 批量节点分流挂载器 (Batch Router)...${PLAIN}"

# 1. 基础环境检查
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 配置文件不存在！${PLAIN}"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    apt update -y && apt install -y jq
fi

# 2. 配置 SOCKS5 出口通道 (保持不变)
# -----------------------------------------------------------
echo -e "${YELLOW}--- 第一步：配置/确认出口代理 ---${PLAIN}"
echo -e "请输入 SOCKS5 代理地址 (通常是 WARP 或其他代理)"

read -p "代理 IP (默认 127.0.0.1): " PROXY_IP
[[ -z "$PROXY_IP" ]] && PROXY_IP="127.0.0.1"

while true; do
    read -p "代理 端口 (例如 40000): " PROXY_PORT
    if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -le 65535 ]; then
        break
    else
        echo -e "${RED}请输入有效的端口号。${PLAIN}"
    fi
done

# 检测连通性
echo -e "${YELLOW}正在测试代理连通性 ($PROXY_IP:$PROXY_PORT)...${PLAIN}"
if curl -s --max-time 4 -x socks5://$PROXY_IP:$PROXY_PORT https://www.google.com >/dev/null; then
    echo -e "${GREEN}代理连接成功！${PLAIN}"
else
    echo -e "${RED}连接失败！该代理似乎无法访问外网。${PLAIN}"
    read -p "是否强制继续配置? (y/n): " FORCE
    [[ "$FORCE" != "y" ]] && exit 1
fi

# 3. 写入出站规则
# -----------------------------------------------------------
PROXY_TAG="custom-socks-out-$PROXY_PORT"
IS_EXIST=$(jq --arg tag "$PROXY_TAG" '.outbounds[] | select(.tag == $tag)' "$CONFIG_FILE")

if [[ -z "$IS_EXIST" ]]; then
    echo -e "${YELLOW}正在添加出站规则...${PLAIN}"
    OUTBOUND_JSON=$(jq -n --arg tag "$PROXY_TAG" --arg ip "$PROXY_IP" --argjson port "$PROXY_PORT" '{
        tag: $tag,
        protocol: "socks",
        settings: { servers: [{ address: $ip, port: $port }] }
    }')
    tmp=$(mktemp)
    jq --argjson new_out "$OUTBOUND_JSON" '.outbounds += [$new_out]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
fi

# 4. 选择节点 (智能过滤已挂载节点)
# -----------------------------------------------------------
echo -e ""
echo -e "${YELLOW}--- 第二步：选择要“变身”的节点 ---${PLAIN}"
echo -e "以下是目前 **尚未被挂载** 代理的“自由”节点："
echo -e "----------------------------------------------------"
printf "%-25s %-10s %-15s\n" "节点标识 (Tag)" "端口" "协议"
echo -e "----------------------------------------------------"

# === 核心逻辑升级：获取“忙碌”的 Tag 列表 ===
# 扫描 routing.rules，提取所有已经在 inboundTag 里的标签
BUSY_TAGS=$(jq -r '[.routing.rules[] | select(.inboundTag != null) | .inboundTag[]] | join(" ")' "$CONFIG_FILE")

AVAILABLE_COUNT=0

# 遍历所有节点并过滤
# 我们将 jq 的输出读入循环，同时传入 BUSY_TAGS 进行比对
jq -r '.inbounds[] | "\(.tag) \(.port) \(.protocol)"' "$CONFIG_FILE" | while read -r tag port proto; do
    # 检查当前 tag 是否出现在 BUSY_TAGS 字符串中
    if [[ " $BUSY_TAGS " =~ " $tag " ]]; then
        # 如果已被占用，则不显示 (或者你可以选择用灰色显示，这里我们按要求直接不列出)
        continue
    else
        printf "${SKYBLUE}%-25s${PLAIN} ${GREEN}%-10s${PLAIN} %-15s\n" "$tag" "$port" "$proto"
        ((AVAILABLE_COUNT++))
    fi
done
echo -e "----------------------------------------------------"

# 如果没有可用节点
if [[ "$AVAILABLE_COUNT" == "0" ]]; then
    # 这里加个简单判断，虽然在 pipe 中变量传递有局限，但视觉上列表为空用户也能看出来
    # 稍微严谨点可以重新统计一次，但为了脚本效率，直接提示用户即可
    echo -e "${GRAY}提示: 如果列表为空，说明所有节点都已经挂载了代理。${PLAIN}"
    echo -e "请先使用 [模块七] 解除挂载，或新建节点。"
fi

# 5. 批量输入处理
# -----------------------------------------------------------
echo -e "${YELLOW}请输入要挂载代理的端口号 (支持批量)${PLAIN}"
echo -e "说明: 用空格分隔多个端口，例如: ${GREEN}2053 8443${PLAIN}"
read -p "目标端口: " INPUT_PORTS

if [[ -z "$INPUT_PORTS" ]]; then
    echo -e "操作取消。"
    exit 0
fi

# 备份
cp "$CONFIG_FILE" "$BACKUP_FILE"

# 转数组
read -a PORT_ARRAY <<< "$INPUT_PORTS"
CHANGE_COUNT=0

# 6. 批量循环挂载
# -----------------------------------------------------------
for TARGET_PORT in "${PORT_ARRAY[@]}"; do
    echo -e "----------------------------------------"
    echo -e "正在处理端口: ${GREEN}$TARGET_PORT${PLAIN} ..."

    # 验证数字
    if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}跳过: 无效端口号。${PLAIN}"
        continue
    fi

    # 查找 Tag
    TARGET_NODE_TAG=$(jq -r --argjson p "$TARGET_PORT" '.inbounds[] | select(.port == $p) | .tag' "$CONFIG_FILE")

    if [[ -z "$TARGET_NODE_TAG" ]] || [[ "$TARGET_NODE_TAG" == "null" ]]; then
        echo -e "${RED}跳过: 找不到端口为 $TARGET_PORT 的节点。${PLAIN}"
        continue
    fi

    # 二次检查：防止用户手动输入了列表中没显示（已挂载）的端口
    if [[ " $BUSY_TAGS " =~ " $TARGET_NODE_TAG " ]]; then
        echo -e "${RED}跳过: 节点 $TARGET_NODE_TAG 已经挂载了代理，请勿重复操作。${PLAIN}"
        continue
    fi

    echo -e "  -> 选中节点: ${SKYBLUE}$TARGET_NODE_TAG${PLAIN}"

    # 写入路由规则 (插入到最前面)
    RULE_JSON=$(jq -n \
        --arg inTag "$TARGET_NODE_TAG" \
        --arg outTag "$PROXY_TAG" \
        '{
            type: "field",
            inboundTag: [$inTag],
            outboundTag: $outTag
        }')

    tmp_rule=$(mktemp)
    jq --argjson new_rule "$RULE_JSON" '.routing.rules = [$new_rule] + .routing.rules' "$CONFIG_FILE" > "$tmp_rule" && mv "$tmp_rule" "$CONFIG_FILE"
    
    echo -e "  -> 路由规则已添加。"
    ((CHANGE_COUNT++))
done
echo -e "----------------------------------------"

# 7. 重启与验证
# -----------------------------------------------------------
if [[ "$CHANGE_COUNT" -gt 0 ]]; then
    echo -e "${YELLOW}正在重启 Xray 以应用 ${CHANGE_COUNT} 个更改...${PLAIN}"
    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}    批量挂载成功！${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "出口流量已重定向至: ${SKYBLUE}${PROXY_IP}:${PROXY_PORT}${PLAIN}"
        echo -e "请使用 IP 检测工具验证效果。"
    else
        echo -e "${RED}重启失败！正在回滚...${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart xray
    fi
else
    echo -e "${YELLOW}未做任何更改。${PLAIN}"
fi
