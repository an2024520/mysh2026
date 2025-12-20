#!/bin/bash

# ==============================================================================
# Argosbx 终极净化版 v2.1 (Refactored by Gemini)
# 特性：IPv6-Only 自动优化 | WARP 智能配置 | 官方源纯净安装
# ==============================================================================

# --- 1. 全局配置 ---
export LANG=en_US.UTF-8
WORKDIR="$HOME/agsbx_clean"
BIN_DIR="$WORKDIR/bin"
CONF_DIR="$WORKDIR/conf"
SCRIPT_PATH="$WORKDIR/agsbx.sh"
BACKUP_DNS="/etc/resolv.conf.bak.agsbx" # DNS备份路径

# --- 2. 变量映射 ---
[ -z "${vlpt+x}" ] || vlp=yes
[ -z "${vmpt+x}" ] || { vmp=yes; vmag=yes; }
[ -z "${hypt+x}" ] || hyp=yes
[ -z "${tupt+x}" ] || tup=yes

export uuid=${uuid:-''}
export port_vl_re=${vlpt:-''}
export port_vm_ws=${vmpt:-''}
export port_hy2=${hypt:-''}
export port_tu=${tupt:-''}
export ym_vl_re=${reym:-''}

export WARP_MODE=${warp:-${wap:-''}}
export WP_KEY=${wpkey:-''}
export WP_IP=${wpip:-''}
export WP_RES=${wpres:-''}

# --- 3. 网络与环境检查 (核心新增) ---

check_and_fix_network() {
    # 依赖检查 (优先安装 curl 用于测试)
    if ! command -v curl >/dev/null 2>&1; then
        if [ -f /etc/debian_version ]; then
            sudo apt-get update -y && sudo apt-get install -y curl
        elif [ -f /etc/redhat-release ]; then
            sudo yum update -y && sudo yum install -y curl
        fi
    fi

    echo "🌐 正在检查网络连通性..."
    
    # 测试 IPv4 连接 (连接 Cloudflare v4)
    V4_STATUS=false
    if curl -4 -s --connect-timeout 3 https://1.1.1.1 >/dev/null; then
        V4_STATUS=true
    fi

    # 测试 IPv6 连接
    V6_STATUS=false
    if curl -6 -s --connect-timeout 3 https://2606:4700:4700::1111 >/dev/null; then
        V6_STATUS=true
    fi

    # 判定逻辑
    if [ "$V4_STATUS" = false ] && [ "$V6_STATUS" = true ]; then
        echo ""
        echo "================================================================"
        echo " ⚠️  检测到纯 IPv6 环境 (IPv6-Only)"
        echo "----------------------------------------------------------------"
        echo " 系统无法直接访问 IPv4 网络 (如 GitHub 部分资源)，可能导致安装失败。"
        echo " 建议临时添加 DNS64 (NAT64) 服务以辅助下载。"
        echo "----------------------------------------------------------------"
        read -p " 是否自动设置 DNS64 优化网络？(y/n) [默认y]: " choice
        choice=${choice:-y}

        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            echo "🔧 正在配置 DNS64..."
            # 备份
            if [ ! -f "$BACKUP_DNS" ]; then
                sudo cp /etc/resolv.conf "$BACKUP_DNS"
            fi
            # 写入 Trex DNS64
            echo -e "nameserver 2001:67c:2b0::4\nnameserver 2001:67c:2b0::6" | sudo tee /etc/resolv.conf >/dev/null
            echo "✅ 网络优化完成，可以正常下载了。"
        else
            echo "🚫 已跳过网络优化 (如下载失败请手动修复)。"
        fi
    elif [ "$V4_STATUS" = false ] && [ "$V6_STATUS" = false ]; then
        echo "❌ 警告：检测不到任何网络连接，脚本可能无法运行。"
    fi
}

check_dependencies() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_ARCH="64"; SB_ARCH="amd64"; WGCF_ARCH="amd64" ;;
        aarch64) XRAY_ARCH="arm64-v8a"; SB_ARCH="arm64"; WGCF_ARCH="arm64" ;;
        *) echo "❌ 不支持的 CPU 架构: $ARCH"; exit 1 ;;
    esac
    
    if ! command -v unzip >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        echo "📦 安装完整依赖..."
        if [ -f /etc/debian_version ]; then
            sudo apt-get update -y && sudo apt-get install -y wget tar unzip socat python3
        elif [ -f /etc/redhat-release ]; then
            sudo yum update -y && sudo yum install -y wget tar unzip socat python3
        fi
    fi
    mkdir -p "$BIN_DIR" "$CONF_DIR"
}

get_ip() {
    v4=$(curl -s4m5 https://icanhazip.com)
    v6=$(curl -s6m5 https://icanhazip.com)
    server_ip=${v4:-$v6}
    [[ "$server_ip" =~ : ]] && server_ip="[$server_ip]"
}

# --- 4. WARP 配置模块 ---

configure_warp_if_needed() {
    if [ -z "$WARP_MODE" ]; then return; fi

    echo ""
    echo "================================================================"
    echo " ☁️  检测到 WARP 参数: warp=$WARP_MODE"
    
    if [ -n "$WP_KEY" ] && [ -n "$WP_IP" ] && [ -n "$WP_RES" ]; then
        echo "✅ 使用预设 WARP 账户。"
        return
    fi

    echo " ⚠️  未检测到 WARP 账户信息。"
    echo " 1) 自动注册 (wgcf)"
    echo " 2) 手动输入"
    echo " 3) 跳过 WARP"
    read -p " 请选择 [1-3]: " choice

    case "$choice" in
        1) auto_register_warp ;;
        2) manual_input_warp ;;
        *) WARP_MODE="" ;;
    esac
}

manual_input_warp() {
    echo ""
    read -p " > PrivateKey: " WP_KEY
    read -p " > Internal IP: " WP_IP
    read -p " > Reserved [x,y,z]: " WP_RES
    if [ -z "$WP_KEY" ]; then WARP_MODE=""; fi
}

auto_register_warp() {
    echo "⬇️ 下载 wgcf..."
    wget -qO wgcf https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${WGCF_ARCH}
    chmod +x wgcf

    echo "📝 注册 WARP..."
    if ! ./wgcf register --accept-tos >/dev/null 2>&1; then
        echo "❌ 注册失败 (可能是网络限制)。"
        WARP_MODE=""
        rm -f wgcf wgcf-account.toml
        return
    fi

    ./wgcf generate >/dev/null 2>&1
    
    # 提取信息
    WP_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d ' ' -f 3)
    RAW_ADDR=$(grep 'Address' wgcf-profile.conf | cut -d '=' -f 2 | tr -d ' ')
    if [[ "$RAW_ADDR" == *","* ]]; then
        WP_IP=$(echo "$RAW_ADDR" | awk -F',' '{print $2}' | cut -d'/' -f1)
    else
        WP_IP=$(echo "$RAW_ADDR" | cut -d'/' -f1)
    fi
    
    CLIENT_ID=$(grep "client_id" wgcf-account.toml | cut -d '"' -f 2)
    if [ -n "$CLIENT_ID" ]; then
        WP_RES=$(python3 -c "import base64; d=base64.b64decode('${CLIENT_ID}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')")
    else
        WP_RES="[]"
    fi

    echo ""
    echo "################ [请保存] ################"
    echo " PrivateKey:  $WP_KEY"
    echo " Internal IP: $WP_IP"
    echo " Reserved:    $WP_RES"
    echo "##########################################"
    echo "按回车继续..."
    read
    rm -f wgcf wgcf-account.toml wgcf-profile.conf
}

# --- 5. 安装与配置 ---

download_core() {
    if [ ! -f "$BIN_DIR/xray" ]; then
        echo "⬇️ [Xray] 下载中..."
        local latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep "tag_name" | cut -d '"' -f 4)
        wget -qO "$WORKDIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${XRAY_ARCH}.zip"
        unzip -o "$WORKDIR/xray.zip" -d "$WORKDIR/temp_xray" >/dev/null
        mv "$WORKDIR/temp_xray/xray" "$BIN_DIR/xray"
        chmod +x "$BIN_DIR/xray"
        mv "$WORKDIR/temp_xray/geo"* "$BIN_DIR/" 2>/dev/null
        rm -rf "$WORKDIR/xray.zip" "$WORKDIR/temp_xray"
    fi
    if [ ! -f "$BIN_DIR/sing-box" ]; then
        echo "⬇️ [Sing-box] 下载中..."
        local latest=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f 4)
        local ver_num=${latest#v}
        wget -qO "$WORKDIR/sb.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${ver_num}-linux-${SB_ARCH}.tar.gz"
        tar -zxvf "$WORKDIR/sb.tar.gz" -C "$WORKDIR" >/dev/null
        mv "$WORKDIR"/sing-box*linux*/sing-box "$BIN_DIR/sing-box"
        chmod +x "$BIN_DIR/sing-box"
        rm -rf "$WORKDIR/sb.tar.gz" "$WORKDIR"/sing-box*linux*
    fi
}

generate_config() {
    echo "⚙️ 生成配置..."
    [ -z "$uuid" ] && { [ ! -f "$CONF_DIR/uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid) > "$CONF_DIR/uuid" || uuid=$(cat "$CONF_DIR/uuid"); }
    [ -z "$ym_vl_re" ] && ym_vl_re="apple.com"
    echo "$ym_vl_re" > "$CONF_DIR/ym_vl_re"

    [ ! -f "$CONF_DIR/cert.pem" ] && { openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/private.key"; openssl req -new -x509 -days 36500 -key "$CONF_DIR/private.key" -out "$CONF_DIR/cert.pem" -subj "/CN=www.bing.com"; }
    
    mkdir -p "$CONF_DIR/xrk"
    if [ ! -f "$CONF_DIR/xrk/private_key" ]; then
        key_pair=$("$BIN_DIR/xray" x25519)
        echo "$key_pair" | awk '/PrivateKey/{print $2}' > "$CONF_DIR/xrk/private_key"
        echo "$key_pair" | awk '/PublicKey/{print $2}' > "$CONF_DIR/xrk/public_key"
        openssl rand -hex 4 > "$CONF_DIR/xrk/short_id"
    fi

    # WARP 参数
    ENABLE_WARP=false
    if [ -n "$WARP_MODE" ] && [ -n "$WP_KEY" ]; then
        ENABLE_WARP=true
        if [[ "$WP_IP" =~ .*:.* ]]; then
             WARP_ADDR_X="\"172.16.0.2/32\", \"${WP_IP}/128\""
             WARP_ADDR_S="\"172.16.0.2/32\", \"${WP_IP}/128\""
        else
             WARP_ADDR_X="\"${WP_IP}/32\", \"2606:4700:110:8d8d:1845:c39f:2dd5:a03a/128\""
             WARP_ADDR_S="\"${WP_IP}/32\", \"2606:4700:110:8d8d:1845:c39f:2dd5:a03a/128\""
        fi
        ROUTE_V4=false; ROUTE_V6=false
        [[ "$WARP_MODE" == *"4"* ]] && ROUTE_V4=true
        [[ "$WARP_MODE" == *"6"* ]] && ROUTE_V6=true
        if [ "$ROUTE_V4" = false ] && [ "$ROUTE_V6" = false ]; then ROUTE_V4=true; fi
    fi

    # XRAY 配置
    cat > "$CONF_DIR/xr.json" <<EOF
{ "log": { "loglevel": "none" }, "inbounds": [
EOF
    if [ -n "$vlp" ] || [ -z "${vmp}${vwp}${hyp}${tup}" ]; then 
        [ -z "$port_vl_re" ] && port_vl_re=$(shuf -i 10000-65535 -n 1)
        echo "$port_vl_re" > "$CONF_DIR/port_vl_re"
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": $port_vl_re, "protocol": "vless", "settings": { "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "${ym_vl_re}:443", "serverNames": ["${ym_vl_re}"], "privateKey": "$(cat $CONF_DIR/xrk/private_key)", "shortIds": ["$(cat $CONF_DIR/xrk/short_id)"] } } },
EOF
    fi
    if [ -n "$vmp" ]; then
        [ -z "$port_vm_ws" ] && port_vm_ws=$(shuf -i 10000-65535 -n 1)
        echo "$port_vm_ws" > "$CONF_DIR/port_vm_ws"
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": ${port_vm_ws}, "protocol": "vmess", "settings": { "clients": [{ "id": "${uuid}" }] }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/${uuid}-vm" } } },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/xr.json"
    cat >> "$CONF_DIR/xr.json" <<EOF
  ], "outbounds": [ { "protocol": "freedom", "tag": "direct" }
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
    ,{ "tag": "warp-out", "protocol": "wireguard", "settings": { "secretKey": "${WP_KEY}", "address": [ ${WARP_ADDR_X} ], "peers": [{ "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": "engage.cloudflareclient.com:2408", "reserved": ${WP_RES} }] } }
EOF
    fi
    cat >> "$CONF_DIR/xr.json" <<EOF
  ], "routing": { "rules": [
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
      { "type": "field", "domain": [ "geosite:openai", "geosite:netflix", "geosite:google", "geosite:disney" ], "outboundTag": "warp-out" },
EOF
        if [ "$ROUTE_V4" = true ]; then echo '      { "type": "field", "ip": [ "0.0.0.0/0" ], "outboundTag": "warp-out" },' >> "$CONF_DIR/xr.json"; fi
        if [ "$ROUTE_V6" = true ]; then echo '      { "type": "field", "ip": [ "::/0" ], "outboundTag": "warp-out" },' >> "$CONF_DIR/xr.json"; fi
    fi
    cat >> "$CONF_DIR/xr.json" <<EOF
      { "type": "field", "outboundTag": "direct", "port": "0-65535" } ] } }
EOF

    # SING-BOX 配置
    cat > "$CONF_DIR/sb.json" <<EOF
{ "log": { "level": "info" }, "inbounds": [
EOF
    if [ -n "$hyp" ] || [ -z "${vmp}${vwp}${vlp}${tup}" ]; then 
        [ -z "$port_hy2" ] && port_hy2=$(shuf -i 10000-65535 -n 1)
        echo "$port_hy2" > "$CONF_DIR/port_hy2"
        cat >> "$CONF_DIR/sb.json" <<EOF
    { "type": "hysteria2", "listen": "::", "listen_port": ${port_hy2}, "users": [{ "password": "${uuid}" }], "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" } },
EOF
    fi
    if [ -n "$tup" ]; then
        [ -z "$port_tu" ] && port_tu=$(shuf -i 10000-65535 -n 1)
        echo "$port_tu" > "$CONF_DIR/port_tu"
        cat >> "$CONF_DIR/sb.json" <<EOF
    { "type": "tuic", "listen": "::", "listen_port": ${port_tu}, "users": [{ "uuid": "${uuid}", "password": "${uuid}" }], "congestion_control": "bbr", "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" } },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/sb.json"
    cat >> "$CONF_DIR/sb.json" <<EOF
  ], "outbounds": [ { "type": "direct", "tag": "direct" }
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/sb.json" <<EOF
    ,{ "type": "wireguard", "tag": "warp-out", "address": [ ${WARP_ADDR_S} ], "private_key": "${WP_KEY}", "peers": [{ "server": "engage.cloudflareclient.com", "server_port": 2408, "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "reserved": ${WP_RES} }] }
EOF
    fi
    cat >> "$CONF_DIR/sb.json" <<EOF
  ], "route": { "rules": [
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/sb.json" <<EOF
      { "geosite": [ "openai", "netflix", "google", "disney" ], "outbound": "warp-out" },
EOF
        if [ "$ROUTE_V4" = true ]; then echo '      { "ip_cidr": [ "0.0.0.0/0" ], "outbound": "warp-out" },' >> "$CONF_DIR/sb.json"; fi
        if [ "$ROUTE_V6" = true ]; then echo '      { "ip_cidr": [ "::/0" ], "outbound": "warp-out" },' >> "$CONF_DIR/sb.json"; fi
    fi
    cat >> "$CONF_DIR/sb.json" <<EOF
      { "port": [0, 65535], "outbound": "direct" } ] } }
EOF
}

# --- 6. 服务与指令 ---

setup_services() {
    USER_NAME=$(whoami)
    sudo tee /etc/systemd/system/xray-clean.service > /dev/null <<EOF
[Unit]
Description=Xray Clean Service
After=network.target
[Service]
User=$USER_NAME
Type=simple
ExecStart=$BIN_DIR/xray run -c $CONF_DIR/xr.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    sudo tee /etc/systemd/system/singbox-clean.service > /dev/null <<EOF
[Unit]
Description=Sing-box Clean Service
After=network.target
[Service]
User=$USER_NAME
Type=simple
ExecStart=$BIN_DIR/sing-box run -c $CONF_DIR/sb.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable xray-clean singbox-clean
    restart_services
}

restart_services() {
    systemctl is-active --quiet xray-clean && sudo systemctl restart xray-clean
    systemctl is-active --quiet singbox-clean && sudo systemctl restart singbox-clean
}

setup_shortcut() {
    cp "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
    sudo ln -sf "$SCRIPT_PATH" /usr/local/bin/agsbx
}

cmd_list() {
    [ ! -f "$CONF_DIR/uuid" ] && { echo "❌ 请先安装"; exit 1; }
    get_ip
    uuid=$(cat "$CONF_DIR/uuid")
    echo ""
    echo "================ [Argosbx 净化版 v2.1] ================"
    echo "  UUID: $uuid"
    echo "  IP:   $server_ip"
    [ -n "$WARP_MODE" ] && echo "  WARP: 开启"
    echo "------------------------------------------------------"
    [ -f "$CONF_DIR/port_vl_re" ] && echo "🔥 [Reality] vless://$uuid@$server_ip:$(cat $CONF_DIR/port_vl_re)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(cat $CONF_DIR/ym_vl_re)&fp=chrome&pbk=$(cat $CONF_DIR/xrk/public_key)&sid=$(cat $CONF_DIR/xrk/short_id)&type=tcp&headerType=none#Clean-Reality"
    [ -f "$CONF_DIR/port_hy2" ] && echo "🚀 [Hysteria2] hysteria2://$uuid@$server_ip:$(cat $CONF_DIR/port_hy2)?security=tls&alpn=h3&insecure=1&sni=www.bing.com#Clean-Hy2"
    [ -f "$CONF_DIR/port_vm_ws" ] && vm_json="{\"v\":\"2\",\"ps\":\"Clean-VMess\",\"add\":\"$server_ip\",\"port\":\"$(cat $CONF_DIR/port_vm_ws)\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"www.bing.com\",\"path\":\"/$uuid-vm\",\"tls\":\"\"}" && echo "🌀 [VMess] vmess://$(echo -n "$vm_json" | base64 -w 0)"
    echo "======================================================"
}

cmd_uninstall() {
    echo "💣 卸载中..."
    sudo systemctl stop xray-clean singbox-clean 2>/dev/null
    sudo systemctl disable xray-clean singbox-clean 2>/dev/null
    sudo rm -f /etc/systemd/system/xray-clean.service /etc/systemd/system/singbox-clean.service /usr/local/bin/agsbx
    sudo systemctl daemon-reload
    rm -rf "$WORKDIR"
    # 还原 DNS
    if [ -f "/etc/resolv.conf.bak.agsbx" ]; then
        sudo cp /etc/resolv.conf.bak.agsbx /etc/resolv.conf
        echo "✅ DNS 设置已还原"
    fi
    echo "✅ 卸载完成。"
}

# --- 7. 入口 ---
if [[ -z "$1" ]] || [[ "$1" == "rep" ]]; then
    check_and_fix_network # 优先检查网络
    check_dependencies
fi

case "$1" in
    list) cmd_list ;;
    del)  cmd_uninstall ;;
    res)  restart_services && echo "✅ 服务已重启" ;;
    upx)  check_dependencies && rm -f "$BIN_DIR/xray" && download_core && restart_services && echo "✅ Xray 升级完成" ;;
    ups)  check_dependencies && rm -f "$BIN_DIR/sing-box" && download_core && restart_services && echo "✅ Sing-box 升级完成" ;;
    rep)
        echo "♻️ 重置配置..."
        rm -rf "$CONF_DIR"/*.json "$CONF_DIR"/port*
        configure_warp_if_needed
        generate_config
        restart_services
        cmd_list
        ;;
    *)
        echo ">>> 开始安装 Argosbx 净化版 v2.1..."
        configure_warp_if_needed
        download_core
        generate_config
        setup_services
        setup_shortcut
        echo "✅ 安装完成！快捷指令: agsbx"
        cmd_list
        ;;
esac
