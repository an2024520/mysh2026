#!/bin/bash
echo "v1.2"
sleep 2
# ============================================================
#  Sing-box 节点级硬分流工具 (Strict Protocol Splitter) v1.2
#  - 修复: 修正 jq 语法导致路由规则无法注入或被清空的问题
#  - 核心: 自动将指定入站绑定到 IPv4/IPv6 专用硬出口
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
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

backup_config() {
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
    echo -e "${GREEN}已备份配置至: ${CONFIG_FILE}.bak.$(date +%s)${PLAIN}"
}

restore_config() {
    local latest_bak=$(ls -t "${CONFIG_FILE}.bak."* 2>/dev/null | head -n1)
    if [[ -n "$latest_bak" ]]; then
        cp "$latest_bak" "$CONFIG_FILE"
        echo -e "${YELLOW}配置校验失败，已回滚至: $latest_bak${PLAIN}"
    else
        echo -e "${RED}严重错误: 无法回滚，请手动检查配置文件。${PLAIN}"
    fi
}

get_inbound_tags() {
    jq -r '.inbounds[] | select(.type != "tun" and .type != "direct") | .tag' "$CONFIG_FILE"
}

inject_strict_rules() {
    local v4_tags_json="$1"
    local v6_tags_json="$2"
    local tmp_file=$(mktemp)

    # 第一步: 注入 Outbounds (如果不存在)
    # 这一步通常是成功的
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

    # 第二步: 注入路由规则 (修复版逻辑)
    # 使用变量捕获新规则，然后精准合并到 .route.rules 数组中
    jq --argjson v4t "$v4_tags_json" --argjson v6t "$v6_tags_json" '
    
    # 1. 构造 IPv4 新规则对象
    ($v4t | if length > 0 then [{
        "inbound": .,
        "action": "route",
        "outbound": "EXIT-HARD-V4"
    }] else [] end) as $new_v4 |

    # 2. 构造 IPv6 新规则对象
    ($v6t | if length > 0 then [{
        "inbound": .,
        "action": "route",
        "outbound": "EXIT-HARD-V6"
    }] else [] end) as $new_v6 |

    # 3. 更新 route.rules
    # 逻辑: (新V4规则 + 新V6规则) + (旧规则 - 旧的硬分流规则)
    .route.rules |= (
        $new_v4 + $new_v6 + 
        (map(select(.outbound != "EXIT-HARD-V4" and .outbound != "EXIT-HARD-V6")))
    )
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
}

# ------------------------------------------------------------
# 交互界面
# ------------------------------------------------------------

clear
echo -e "============================================"
echo -e " Sing-box 节点级硬分流工具 (Strict Split) v1.2"
echo -e "--------------------------------------------"
echo -e " 目标配置文件: ${SKYBLUE}$CONFIG_FILE${PLAIN}"
echo -e " 现有入站节点 (Inbounds):"
echo -e "--------------------------------------------"

mapfile -t TAGS < <(get_inbound_tags)

if [[ ${#TAGS[@]} -eq 0 ]]; then
    echo -e "${RED}未检测到有效的代理入站节点。${PLAIN}"
    exit 1
fi

i=1
for tag in "${TAGS[@]}"; do
    echo -e " [$i] ${GREEN}$tag${PLAIN}"
    let i++
done
echo -e "--------------------------------------------"

# 选择 IPv4 组
echo -e "${YELLOW}请选择要【强制走 IPv4】的节点序号 (空格分隔，回车跳过):${PLAIN}"
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

# 选择 IPv6 组
echo -e "${YELLOW}请选择要【强制走 IPv6】的节点序号 (空格分隔，回车跳过):${PLAIN}"
read -p "> " v6_input
V6_SELECTED=()
if [[ -n "$v6_input" ]]; then
    for num in $v6_input; do
        idx=$((num-1))
        tag="${TAGS[$idx]}"
        if [[ -n "$tag" ]]; then
            if [[ " ${V4_SELECTED[*]} " =~ " ${tag} " ]]; then
                echo -e "${RED}跳过 $tag: 已分配给 IPv4 组${PLAIN}"
            else
                V6_SELECTED+=("$tag")
            fi
        fi
    done
fi

# 确认执行
echo -e "--------------------------------------------"
if [[ ${#V4_SELECTED[@]} -gt 0 ]]; then
    echo -e " 强制 IPv4: ${GREEN}${V4_SELECTED[*]}${PLAIN}"
else
    echo -e " 强制 IPv4: (无)"
fi
if [[ ${#V6_SELECTED[@]} -gt 0 ]]; then
    echo -e " 强制 IPv6: ${GREEN}${V6_SELECTED[*]}${PLAIN}"
else
    echo -e " 强制 IPv6: (无)"
fi
echo -e "--------------------------------------------"
read -p "确认写入配置? (y/n): " confirm
[[ "$confirm" != "y" ]] && exit 0

backup_config

# 转换数组为 JSON
V4_JSON=$(printf '%s\n' "${V4_SELECTED[@]}" | jq -R . | jq -s . -c)
V6_JSON=$(printf '%s\n' "${V6_SELECTED[@]}" | jq -R . | jq -s . -c)

echo -e "正在注入规则..."
inject_strict_rules "$V4_JSON" "$V6_JSON"

echo -e "正在验证配置..."
# 双重验证：检查语法 + 检查规则是否真的写进去了
if sing-box check -c "$CONFIG_FILE"; then
    # 检查规则第一条是否是我们刚才写的
    FIRST_RULE_OUT=$(jq -r '.route.rules[0].outbound' "$CONFIG_FILE")
    if [[ "$FIRST_RULE_OUT" == "EXIT-HARD-V4" || "$FIRST_RULE_OUT" == "EXIT-HARD-V6" ]]; then
        echo -e "${GREEN}验证成功! 规则已置顶。${PLAIN}"
        systemctl restart sing-box
        
        # 显示前几行状态
        echo -e "--------------------------------------------"
        echo -e "当前路由表首部规则 (Top Rules):"
        jq '.route.rules[0:2]' "$CONFIG_FILE"
        echo -e "--------------------------------------------"
    else
        echo -e "${RED}警告: 语法正确但规则未置顶，脚本逻辑可能仍有误。${PLAIN}"
        # 不回滚，但也提示警告
    fi
else
    echo -e "${RED}Sing-box 语法校验失败!${PLAIN}"
    restore_config
    exit 1
fi