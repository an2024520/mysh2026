#!/bin/bash

# ==============================================================================
# Argosbx 终极净化版 v2.0 (Refactored by Gemini)
# 核心逻辑：参数驱动 -> 按需触发WARP配置 -> 官方源安装 -> 纯净运行
# ==============================================================================

# --- 1. 全局配置 ---
export LANG=en_US.UTF-8
WORKDIR="$HOME/agsbx_clean"
BIN_DIR="$WORKDIR/bin"
CONF_DIR="$WORKDIR/conf"
SCRIPT_PATH="$WORKDIR/agsbx.sh"

# --- 2. 变量映射 (兼容 WebUI 参数) ---
# 协议开关
[ -z "${vlpt+x}" ] || vlp=yes
[ -z "${vmpt+x}" ] || { vmp=yes; vmag=yes; }
[ -z "${hypt+x}" ] || hyp=yes
[ -z "${tupt+x}" ] || tup=yes

# 核心变量
export uuid=${uuid:-''}
export port_vl_re=${vlpt:-''}
export port_vm_ws=${vmpt:-''}
export port_hy2=${hypt:-''}
export port_tu=${tupt:-''}
export ym_vl_re=${reym:-''}

# WARP 开关 (WebUI 传入 warp=s4, warp=x6, warp=yes 等)
# 兼容 wap 变量名
export WARP_MODE=${warp:-${wap:-''}}

# WARP 账户信息 (可手动传入，也可脚本生成)
export WP_KEY=${wpkey:-''}
export WP_IP=${wpip:-''}
export WP_RES=${wpres:-''}

# --- 3. 基础检查 ---

check_env() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_ARCH="64"; SB_ARCH="amd64"; WGCF_ARCH="amd64" ;;
        aarch64) XRAY_ARCH="arm64-v8a"; SB_ARCH="arm64"; WGCF_ARCH="arm64" ;;
        *) echo "❌ 不支持的 CPU 架构: $ARCH"; exit 1 ;;
    esac
    
    # 基础依赖
    if ! command -v unzip >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        echo "📦 安装必要依赖 (curl, wget, unzip, tar, python3)..."
        if [ -f /etc/debian_version ]; then
            sudo apt-get update -y && sudo apt-get install -y curl wget tar unzip socat python3
        elif [ -f /etc/redhat-release ]; then
            sudo yum update -y && sudo yum install -y curl wget tar unzip socat python3
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

# --- 4. WARP 逻辑 (核心修改点) ---

configure_warp_if_needed() {
    # 1. 检查是否需要开启 WARP
    if [ -z "$WARP_MODE" ]; then
        return # 参数中没有 warp=...，直接返回，不打扰用户
    fi

    echo ""
    echo "================================================================"
    echo " ☁️  检测到 WARP 启用参数: warp=$WARP_MODE"
    echo "----------------------------------------------------------------"

    # 2. 检查是否已经有账户信息 (通过环境变量传入)
    if [ -n "$WP_KEY" ] && [ -n "$WP_IP" ] && [ -n "$WP_RES" ]; then
        echo "✅ 检测到完整的 WARP 账户变量，直接使用。"
        return
    fi

    # 3. 交互菜单
    echo " ⚠️  未检测到 WARP 账户信息 (PrivateKey/IP/Reserved)。"
    echo " 请选择获取方式："
    echo " 1) 自动生成新账户 (使用官方 wgcf 工具，用完即焚)"
    echo " 2) 手动输入现有信息 (PrivateKey, Internal IP, Reserved)"
    echo " 3) 放弃 WARP (仅安装普通节点)"
    echo "----------------------------------------------------------------"
    read -p " 请输入数字 [1-3]: " choice

    case "$choice" in
        1)
            auto_register_warp
            ;;
        2)
            manual_input_warp
            ;;
        *)
            echo "🚫 已取消 WARP 配置。"
            WARP_MODE="" # 清空模式，后续不生成配置
            ;;
    esac
}

manual_input_warp() {
    echo ""
    echo "📝 请输入 WARP 信息："
    read -p " > PrivateKey (私钥): " WP_KEY
    read -p " > Internal IP (例如 172.16.0.2 或 2606:...): " WP_IP
    read -p " > Reserved (格式如 [1,2,3]): " WP_RES
    
    # 简单校验
    if [ -z "$WP_KEY" ] || [ -z "$WP_IP" ] || [ -z "$WP_RES" ]; then
        echo "❌ 信息不完整，跳过 WARP 配置。"
        WARP_MODE=""
    fi
}

auto_register_warp() {
    echo "⬇️ 正在下载 wgcf 注册工具..."
    wget -qO wgcf https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${WGCF_ARCH}
    chmod +x wgcf

    echo "📝 正在注册 WARP 账号..."
    if ! ./wgcf register --accept-tos >/dev/null 2>&1; then
        echo "❌ WARP 注册失败 (可能是 CF 接口限制)。"
        rm -f wgcf wgcf-account.toml
        WARP_MODE=""
        return
    fi

    ./wgcf generate >/dev/null 2>&1

    echo "🔍 正在提取参数..."
    WP_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d ' ' -f 3)
    
    # 提取 IP (优先取 IPv6, 没有则 IPv4)
    RAW_ADDR=$(grep 'Address' wgcf-profile.conf | cut -d '=' -f 2 | tr -d ' ')
    if [[ "$RAW_ADDR" == *","* ]]; then
        WP_IP=$(echo "$RAW_ADDR" | awk -F',' '{print $2}' | cut -d'/' -f1)
    else
        WP_IP=$(echo "$RAW_ADDR" | cut -d'/' -f1)
    fi
    
    # 计算 Reserved
    CLIENT_ID=$(grep "client_id" wgcf-account.toml | cut -d '"' -f 2)
    if [ -n "$CLIENT_ID" ]; then
        WP_RES=$(python3 -c "import base64; d=base64.b64decode('${CLIENT_ID}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')")
    else
        WP_RES="[]"
    fi

    echo ""
    echo "################ [请务必保存以下信息] ################"
    echo " PrivateKey: $WP_KEY"
    echo " Internal IP: $WP_IP"
    echo " Reserved:   $WP_RES"
    echo "######################################################"
    echo "按回车键继续..."
    read

    # 清理残留
    rm -f wgcf wgcf-account.toml wgcf-profile.conf
}

# --- 5. 核心安装与配置 ---

download_core() {
    # Xray
    if [ ! -f "$BIN_DIR/xray" ]; then
        echo "⬇️ [Xray] 下载中 (官方源)..."
        local latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep "tag_name" | cut -d '"' -f 4)
        wget -qO "$WORKDIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${XRAY_ARCH}.zip"
        unzip -o "$WORKDIR/xray.zip" -d "$WORKDIR/temp_xray" >/dev/null
        mv "$WORKDIR/temp_xray/xray" "$BIN_DIR/xray"
        chmod +x "$BIN_DIR/xray"
        # 确保 geo 文件存在
        mv "$WORKDIR/temp_xray/geoip.dat" "$BIN_DIR/" 2>/dev/null
        mv "$WORKDIR/temp_xray/geosite.dat" "$BIN_DIR/" 2>/dev/null
        rm -rf "$WORKDIR/xray.zip" "$WORKDIR/temp_xray"
    fi
    # Sing-box
    if [ ! -f "$BIN_DIR/sing-box" ]; then
        echo "⬇️ [Sing-box] 下载中 (官方源)..."
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
    echo "⚙️ 生成配置文件..."
    # 基础信息
    [ -z "$uuid" ] && { [ ! -f "$CONF_DIR/uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid) > "$CONF_DIR/uuid" || uuid=$(cat "$CONF_DIR/uuid"); }
    [ -z "$ym_vl_re" ] && ym_vl_re="apple.com"
    echo "$ym_vl_re" > "$CONF_DIR/ym_vl_re"

    # 证书
    [ ! -f "$CONF_DIR/cert.pem" ] && { openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/private.key"; openssl req -new -x509 -days 36500 -key "$CONF_DIR/private.key" -out "$CONF_DIR/cert.pem" -subj "/CN=www.bing.com"; }
    
    mkdir -p "$CONF_DIR/xrk"
    if [ ! -f "$CONF_DIR/xrk/private_key" ]; then
        key_pair=$("$BIN_DIR/xray" x25519)
        echo "$key_pair" | awk '/PrivateKey/{print $2}' > "$CONF_DIR/xrk/private_key"
        echo "$key_pair" | awk '/PublicKey/{print $2}' > "$CONF_DIR/xrk/public_key"
        openssl rand -hex 4 > "$CONF_DIR/xrk/short_id"
    fi

    # --- WARP 参数处理 ---
    ENABLE_WARP=false
    if [ -n "$WARP_MODE" ] && [ -n "$WP_KEY" ]; then
        ENABLE_WARP=true
        # 地址格式化
        if [[ "$WP_IP" =~ .*:.* ]]; then
             # IPv6
             WARP_ADDR_X="\"172.16.0.2/32\", \"${WP_IP}/128\""
             WARP_ADDR_S="\"172.16.0.2/32\", \"${WP_IP}/128\""
        else
             # IPv4
             WARP_ADDR_X="\"${WP_IP}/32\", \"2606:4700:110:8d8d:1845:c39f:2dd5:a03a/128\""
             WARP_ADDR_S="\"${WP_IP}/32\", \"2606:4700:110:8d8d:1845:c39f:2dd5:a03a/128\""
        fi

        # 路由策略判定
        ROUTE_V4=false; ROUTE_V6=false
        [[ "$WARP_MODE" == *"4"* ]] && ROUTE_V4=true
        [[ "$WARP_MODE" == *"6"* ]] && ROUTE_V6=true
        # 默认兜底：接管 IPv4
        if [ "$ROUTE_V4" = false ] && [ "$ROUTE_V6" = false ]; then ROUTE_V4=true; fi
    fi

    # ================= XRAY JSON =================
    cat > "$CONF_DIR/xr.json" <<EOF
{ "log": { "loglevel": "none" }, "inbounds": [
EOF
    # Reality
    if [ -n "$vlp" ] || [ -z "${vmp}${vwp}${hyp}${tup}" ]; then 
        [ -z "$port_vl_re" ] && port_vl_re=$(shuf -i 10000-65535 -n 1)
        echo "$port_vl_re" > "$CONF_DIR/port_vl_re"
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": $port_vl_re, "protocol": "vless", "settings": { "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "${ym_vl_re}:443", "serverNames": ["${ym_vl_re}"], "privateKey": "$(cat $CONF_DIR/xrk/private_key)", "shortIds": ["$(cat $CONF_DIR/xrk/short_id)"] } } },
EOF
    fi
    # VMess
    if [ -n "$vmp" ]; then
        [ -z "$port_vm_ws" ] && port_vm_ws=$(shuf -i 10000-65535 -n 1)
        echo "$port_vm_ws" > "$CONF_DIR/port_vm_ws"
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": ${port_vm_ws}, "protocol": "vmess", "settings": { "clients": [{ "id": "${uuid}" }] }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/${uuid}-vm" } } },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/xr.json"
    
    # Xray Outbounds
    cat >> "$CONF_DIR/xr.json" <<EOF
  ], "outbounds": [ { "protocol": "freedom", "tag": "direct" }
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
    ,{ "tag": "warp-out", "protocol": "wireguard", "settings": { "secretKey": "${WP_KEY}", "address": [ ${WARP_ADDR_X} ], "peers": [{ "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": "engage.cloudflareclient.com:2408", "reserved": ${WP_RES} }] } }
EOF
    fi
    # Xray Routing
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

    # ================= SING-BOX JSON =================
    cat > "$CONF_DIR/sb.json" <<EOF
{ "log": { "level": "info" }, "inbounds": [
EOF
    # Hysteria2
    if [ -n "$hyp" ] || [ -z "${vmp}${vwp}${vlp}${tup}" ]; then 
        [ -z "$port_hy2" ] && port_hy2=$(shuf -i 10000-65535 -n 1)
        echo "$port_hy2" > "$CONF_DIR/port_hy2"
        cat >> "$CONF_DIR/sb.json" <<EOF
    { "type": "hysteria2", "listen": "::", "listen_port": ${port_hy2}, "users": [{ "password": "${uuid}" }], "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" } },
EOF
    fi
    # Tuic
    if [ -n "$tup" ]; then
        [ -z "$port_tu" ] && port_tu=$(shuf -i 10000-65535 -n 1)
        echo "$port_tu" > "$CONF_DIR/port_tu"
        cat >> "$CONF_DIR/sb.json" <<EOF
    { "type": "tuic", "listen": "::", "listen_port": ${port_tu}, "users": [{ "uuid": "${uuid}", "password": "${uuid}" }], "congestion_control": "bbr", "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" } },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/sb.json"

    # Sing-box Outbounds
    cat >> "$CONF_DIR/sb.json" <<EOF
  ], "outbounds": [ { "type": "direct", "tag": "direct" }
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/sb.json" <<EOF
    ,{ "type": "wireguard", "tag": "warp-out", "address": [ ${WARP_ADDR_S} ], "private_key": "${WP_KEY}", "peers": [{ "server": "engage.cloudflareclient.com", "server_port": 2408, "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "reserved": ${WP_RES} }] }
EOF
    fi
    # Sing-box Routing
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

# --- 6. 系统服务 ---

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

# --- 7. 命令管理 ---

cmd_list() {
    [ ! -f "$CONF_DIR/uuid" ] && { echo "❌ 请先安装"; exit 1; }
    get_ip
    uuid=$(cat "$CONF_DIR/uuid")
    echo ""
    echo "================ [Argosbx 净化版 v2.0] ================"
    echo "  UUID: $uuid"
    echo "  IP:   $server_ip"
    [ -n "$WARP_MODE" ] && echo "  WARP: 开启 (模式: ${WARP_MODE:-默认})"
    echo "------------------------------------------------------"
    [ -f "$CONF_DIR/port_vl_re" ] && echo "🔥 [Reality] vless://$uuid@$server_ip:$(cat $CONF_DIR/port_vl_re)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(cat $CONF_DIR/ym_vl_re)&fp=chrome&pbk=$(cat $CONF_DIR/xrk/public_key)&sid=$(cat $CONF_DIR/xrk/short_id)&type=tcp&headerType=none#Clean-Reality"
    [ -f "$CONF_DIR/port_hy2" ] && echo "🚀 [Hysteria2] hysteria2://$uuid@$server_ip:$(cat $CONF_DIR/port_hy2)?security=tls&alpn=h3&insecure=1&sni=www.bing.com#Clean-Hy2"
    [ -f "$CONF_DIR/port_vm_ws" ] && vm_json="{\"v\":\"2\",\"ps\":\"Clean-VMess\",\"add\":\"$server_ip\",\"port\":\"$(cat $CONF_DIR/port_vm_ws)\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"www.bing.com\",\"path\":\"/$uuid-vm\",\"tls\":\"\"}" && echo "🌀 [VMess] vmess://$(echo -n "$vm_json" | base64 -w 0)"
    echo "======================================================"
}

# --- 8. 入口逻辑 ---

if [[ -z "$1" ]] || [[ "$1" == "rep" ]]; then
    check_env
fi

case "$1" in
    list) cmd_list ;;
    del)  
        echo "💣 卸载中..."
        sudo systemctl stop xray-clean singbox-clean 2>/dev/null
        sudo systemctl disable xray-clean singbox-clean 2>/dev/null
        sudo rm -f /etc/systemd/system/xray-clean.service /etc/systemd/system/singbox-clean.service /usr/local/bin/agsbx
        sudo systemctl daemon-reload
        rm -rf "$WORKDIR"
        echo "✅ 完成。"
        ;;
    res)  restart_services && echo "✅ 服务已重启" ;;
    upx)  check_env && rm -f "$BIN_DIR/xray" && download_core && restart_services && echo "✅ Xray 升级完成" ;;
    ups)  check_env && rm -f "$BIN_DIR/sing-box" && download_core && restart_services && echo "✅ Sing-box 升级完成" ;;
    rep)
        echo "♻️ 重置配置..."
        rm -rf "$CONF_DIR"/*.json "$CONF_DIR"/port*
        configure_warp_if_needed # 重新检测 WARP 需求
        generate_config
        restart_services
        cmd_list
        ;;
    *)
        echo ">>> 开始安装 Argosbx 净化版 v2.0..."
        configure_warp_if_needed # 核心：按需触发 WARP 配置
        download_core
        generate_config
        setup_services
        setup_shortcut
        echo "✅ 安装完成！快捷指令: agsbx"
        cmd_list
        ;;
esac
