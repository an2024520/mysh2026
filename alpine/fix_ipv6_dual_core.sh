#!/bin/bash

# ============================================================
# 脚本名称：fix_ipv6_dual_core.sh
# 作用：修复纯 IPv6 环境下 WARP 连不通问题 (兼容 Xray & Sing-box)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 查找所有可能的配置文件 (兼容 menu.sh 体系)
find_configs() {
    PATHS=(
        "/usr/local/etc/xray/config.json" "/etc/xray/config.json" "/usr/local/etc/xray/xr.json"
        "/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "/usr/local/etc/sing-box/sb.json"
    )
    FOUND_FILES=()
    for p in "${PATHS[@]}"; do
        if [[ -f "$p" ]]; then FOUND_FILES+=("$p"); fi
    done
}

# 2. 执行修复
fix_file() {
    local file="$1"
    local tmp=$(mktemp)
    
    # 识别核心类型 (通过内容判断)
    if grep -q "outbounds" "$file" && grep -q "protocol" "$file"; then
        echo -e "${YELLOW}正在修复 Xray 配置: $file${PLAIN}"
        jq '
            (.outbounds[]? | select(.protocol == "wireguard" or .tag == "warp-out") | .settings.peers[0].endpoint) |= "[2606:4700:d0::a29f:c001]:2408" |
            .dns = { "servers": [{ "address": "2001:4860:4860::8888", "port": 53 }, "localhost"], "queryStrategy": "UseIPv6", "tag": "dns_inbound" }
        ' "$file" > "$tmp"
    elif grep -q "outbounds" "$file" && grep -q "type" "$file"; then
        echo -e "${YELLOW}正在修复 Sing-box 配置: $file${PLAIN}"
        jq '
            (.outbounds[]? | select(.type == "wireguard" or .tag == "warp-out") | .peers[0].server) |= "2606:4700:d0::a29f:c001" |
            (.outbounds[]? | select(.type == "wireguard" or .tag == "warp-out") | .peers[0].server_port) |= 2408 |
            .dns.servers |= [{ "address": "2001:4860:4860::8888", "port": 53 }] |
            .dns.strategy |= "prefer_ipv6"
        ' "$file" > "$tmp"
    fi

    if [[ -s "$tmp" ]]; then mv "$tmp" "$file" && echo -e "${GREEN}修复成功！${PLAIN}"; else rm -f "$tmp"; fi
}

# 3. 主程序
find_configs
if [[ ${#FOUND_FILES[@]} -eq 0 ]]; then echo -e "${RED}未找到配置文件${PLAIN}"; exit 1; fi

for f in "${FOUND_FILES[@]}"; do
    fix_file "$f"
done

# 重启相关服务
systemctl restart xray 2>/dev/null
systemctl restart sing-box 2>/dev/null
echo -e "${GREEN}所有相关服务已重启。${PLAIN}"
