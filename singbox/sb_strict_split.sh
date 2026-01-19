#!/bin/bash
# ============================================================
#  Sing-box 节点级硬分流工具 (Strict Protocol Splitter)
#  - 核心功能: 将指定入站节点强制绑定到纯 IPv4 或纯 IPv6 出口
#  - 适用场景: 双栈 VPS 实现“一机两用” / 解决特定应用 IP 限制
#  - 兼容性: Sing-box v1.12+ (使用 Route + Outbound 策略)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 配置文件定位
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 配置文件。${PLAIN}"
    exit 1
fi

# 2. 依赖检查
if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: 缺少 jq 组件。请运行: apt-get install jq -y${PLAIN}"
    exit 1
fi

# ------------------------------------------------------------
# 核心逻辑区
# ------------------------------------------------------------

# 备份函数
backup_config() {
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
    echo -e "${GREEN}已备份配置文件至: ${CONFIG_FILE}.bak.$(date +%s)${PLAIN}"
}

# 恢复函数
restore_config() {
    local latest_bak=$(ls -t "${CONFIG_FILE}.bak."* 2>/dev/null | head -n1)
    if [[ -n "$latest_bak" ]]; then
        cp "$latest_bak" "$CONFIG_FILE"
        echo -e "${YELLOW}配置校验失败，已自动回滚至: $latest_bak${PLAIN}"
    else
        echo -e "${RED}严重错误: 无法回滚，请手动检查配置文件。${PLAIN}"
    fi
}

# 获取入站列表
get_inbound_tags() {
    # 排除 tun 接口和本地回环，只显示代理节点
    jq -r '.inbounds[] | select(.type != "tun" and .type != "direct") | .tag' "$CONFIG_FILE"
}

# 注入配置的主函数
inject_strict_rules() {
    local v4_tags_json="$1"
    local v6_tags_json="$2"
    local tmp_file=$(mktemp)

    # 1. 注入 Outbounds (如果不存在)
    # EXIT-HARD-V4: 强制 IPv4
    # EXIT-HARD-V6: 强制 IPv6
    jq '
    def ensure_outbound($tag; $strategy):
        if (.outbounds | map(select(.tag == $tag)) | length) == 0 then
            .outbounds += [{
                "type": "direct",
                "tag": $tag,
                "domain_strategy": $strategy
            }]
        else
            .
        end;
    
    ensure_outbound("EXIT-HARD-V4"; "ipv4_only") |
    ensure_outbound("EXIT-HARD-V6"; "ipv6_only")
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"

    # 2. 注入路由规则 (Route Rules)
    # 先清理旧的同名规则，再在头部插入新规则
    jq --argjson v4t "$v4_tags_json" --argjson v6t "$v6_tags_json" '
    .route.rules |= map(select(.outbound != "EXIT-HARD-V4" and .outbound != "EXIT-HARD-V6")) |
    
    (if ($v4t | length) > 0 then [{
        "inbound": $v4t,
        "action": "route",
        "outbound": "EXIT-HARD-V4"
    }] else [] end) + 
    
    (if ($v6t | length) > 0 then [{
        "inbound": $v6t,
        "action": "route",
        "outbound": "EXIT-HARD-V6"
    }] else [] end) + 
    .
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
}

# ------------------------------------------------------------
# 交互界面
# ------------------------------------------------------------

clear
echo -e "============================================"
echo -e " Sing-box 节点级硬分流工具 (Strict Split)"
echo -e "--------------------------------------------"
echo -e " 检测到的配置文件: ${SKYBLUE}$CONFIG_FILE${PLAIN}"
echo -e " 现有入站节点 (Inbounds):"
echo -e "--------------------------------------------"

# 读取现有 Tag
mapfile -t TAGS < <(get_inbound_tags)

if [[ ${#TAGS[@]} -eq 0 ]]; then
    echo -e "${RED}未检测到有效的代理入站节点 (VLESS/VMess/Trojan等)。${PLAIN}"
    exit 1
fi

# 显示列表
i=1
for tag in "${TAGS[@]}"; do
    echo -e " [$i] ${GREEN}$tag${PLAIN}"
    let i++
done
echo -e "--------------------------------------------"

# 交互选择 IPv4 组
echo -e "${YELLOW}请选择要【强制走 IPv4】的节点序号 (用空格分隔，回车跳过):${PLAIN}"
read -p "> " v4_input
V4_SELECTED=()
if [[ -n "$v4_input" ]]; then
    for num in $v4_input; do
        idx=$((num-1))
        if [[ -n "${TAGS[$idx]}" ]]; then
            V4_SELECTED+=("${TAGS[$idx]}")
        fi
    done
fi

# 交互选择 IPv6 组 (自动排除已选 V4 的)
echo -e "${YELLOW}请选择要【强制走 IPv6】的节点序号 (用空格分隔，回车跳过):${PLAIN}"
read -p "> " v6_input
V6_SELECTED=()
if [[ -n "$v6_input" ]]; then
    for num in $v6_input; do
        idx=$((num-1))
        tag="${TAGS[$idx]}"
        if [[ -n "$tag" ]]; then
            # 简单查重：如果已经在 V4 组里，则跳过
            if [[ " ${V4_SELECTED[*]} " =~ " ${tag} " ]]; then
                echo -e "${RED}跳过 $tag: 已分配给 IPv4 组${PLAIN}"
            else
                V6_SELECTED+=("$tag")
            fi
        fi
    done
fi

# 确认信息
echo -e "--------------------------------------------"
echo -e "即将执行修改:"
if [[ ${#V4_SELECTED[@]} -gt 0 ]]; then
    echo -e " ${GREEN}强制 IPv4 节点:${PLAIN} ${V4_SELECTED[*]}"
else
    echo -e " 强制 IPv4 节点: (无)"
fi

if [[ ${#V6_SELECTED[@]} -gt 0 ]]; then
    echo -e " ${GREEN}强制 IPv6 节点:${PLAIN} ${V6_SELECTED[*]}"
else
    echo -e " 强制 IPv6 节点: (无)"
fi
echo -e "--------------------------------------------"
read -p "确认写入配置? (y/n): " confirm
[[ "$confirm" != "y" ]] && exit 0

# 执行
backup_config

# 转换数组为 JSON 格式字符串供 jq 使用
V4_JSON=$(printf '%s\n' "${V4_SELECTED[@]}" | jq -R . | jq -s . -c)
V6_JSON=$(printf '%s\n' "${V6_SELECTED[@]}" | jq -R . | jq -s . -c)

# 注入
echo -e "正在注入规则..."
inject_strict_rules "$V4_JSON" "$V6_JSON"

# 验证
echo -e "正在验证配置完整性..."
if sing-box check -c "$CONFIG_FILE"; then
    echo -e "${GREEN}验证通过! 重启服务生效...${PLAIN}"
    systemctl restart sing-box
    systemctl status sing-box --no-pager | head -n 10
else
    echo -e "${RED}验证失败!${PLAIN}"
    restore_config
    exit 1
fi