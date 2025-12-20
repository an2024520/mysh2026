#!/bin/bash

# ==============================================================================
# Argosbx 终极净化全功能版 (Refactored by Gemini)
# 包含功能：install | list | del | upx | ups | res | rep
# 特性：官方源、安全路径、自动配置快捷命令 agsbx
# ==============================================================================

# --- 1. 全局配置与路径 ---
export LANG=en_US.UTF-8

# 核心工作目录
WORKDIR="$HOME/agsbx_clean"
BIN_DIR="$WORKDIR/bin"
CONF_DIR="$WORKDIR/conf"
SCRIPT_PATH="$WORKDIR/agsbx.sh" # 脚本自身的永久存储路径

# --- 2. 变量映射 (WebUI 兼容层) ---
[ -z "${vlpt+x}" ] || vlp=yes
[ -z "${vmpt+x}" ] || { vmp=yes; vmag=yes; }
[ -z "${vwpt+x}" ] || { vwp=yes; vmag=yes; }
[ -z "${hypt+x}" ] || hyp=yes
[ -z "${tupt+x}" ] || tup=yes
[ -z "${xhpt+x}" ] || xhp=yes
[ -z "${vxpt+x}" ] || vxp=yes
[ -z "${anpt+x}" ] || anp=yes
[ -z "${sspt+x}" ] || ssp=yes
[ -z "${arpt+x}" ] || arp=yes
[ -z "${sopt+x}" ] || sop=yes
[ -z "${warp+x}" ] || wap=yes

export uuid=${uuid:-''}
export port_vl_re=${vlpt:-''}
export port_vm_ws=${vmpt:-''}
export port_hy2=${hypt:-''}
export port_tu=${tupt:-''}
export ym_vl_re=${reym:-''}
export argo=${argo:-''}

# --- 3. 辅助功能函数 ---

check_env() {
    # 架构判断
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_ARCH="64"; SB_ARCH="amd64"; CF_ARCH="amd64" ;;
        aarch64) XRAY_ARCH="arm64-v8a"; SB_ARCH="arm64"; CF_ARCH="arm64" ;;
        *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    # 依赖检查
    if ! command -v unzip >/dev/null 2>&1; then
        echo "📦 安装必要依赖 (curl, wget, unzip, tar)..."
        if [ -f /etc/debian_version ]; then
            sudo apt-get update -y && sudo apt-get install -y curl wget tar unzip socat
        elif [ -f /etc/redhat-release ]; then
            sudo yum update -y && sudo yum install -y curl wget tar unzip socat
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

# --- 4. 核心下载/更新函数 (官方源) ---

download_xray() {
    echo "⬇️ [Xray] 正在检查最新版本 (XTLS官方)..."
    local latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    if [ -z "$latest" ]; then echo "❌ 获取 Xray 版本失败，请检查网络"; return 1; fi
    echo "   版本: $latest"
    
    local url="https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${XRAY_ARCH}.zip"
    wget -qO "$WORKDIR/xray.zip" "$url"
    unzip -o "$WORKDIR/xray.zip" -d "$WORKDIR/temp_xray"
    mv "$WORKDIR/temp_xray/xray" "$BIN_DIR/xray"
    chmod +x "$BIN_DIR/xray"
    rm -rf "$WORKDIR/xray.zip" "$WORKDIR/temp_xray"
    echo "✅ Xray 更新/安装完毕"
}

download_singbox() {
    echo "⬇️ [Sing-box] 正在检查最新版本 (SagerNet官方)..."
    local latest=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    if [ -z "$latest" ]; then echo "❌ 获取 Sing-box 版本失败"; return 1; fi
    echo "   版本: $latest"
    
    local ver_num=${latest#v}
    local url="https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${ver_num}-linux-${SB_ARCH}.tar.gz"
    wget -qO "$WORKDIR/sb.tar.gz" "$url"
    tar -zxvf "$WORKDIR/sb.tar.gz" -C "$WORKDIR"
    mv "$WORKDIR"/sing-box*linux*/sing-box "$BIN_DIR/sing-box"
    chmod +x "$BIN_DIR/sing-box"
    rm -rf "$WORKDIR/sb.tar.gz" "$WORKDIR"/sing-box*linux*
    echo "✅ Sing-box 更新/安装完毕"
}

# --- 5. 配置文件生成 ---

generate_config() {
    echo "⚙️ 生成配置文件..."
    # 生成 UUID
    if [ -z "$uuid" ]; then
        if [ ! -f "$CONF_DIR/uuid" ]; then
            uuid=$(cat /proc/sys/kernel/random/uuid)
            echo "$uuid" > "$CONF_DIR/uuid"
        else
            uuid=$(cat "$CONF_DIR/uuid")
        fi
    fi
    [ -z "$ym_vl_re" ] && ym_vl_re="apple.com"
    echo "$ym_vl_re" > "$CONF_DIR/ym_vl_re"

    # 生成证书 (Singbox用)
    if [ ! -f "$CONF_DIR/cert.pem" ]; then
        openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/private.key"
        openssl req -new -x509 -days 36500 -key "$CONF_DIR/private.key" -out "$CONF_DIR/cert.pem" -subj "/CN=www.bing.com"
    fi
    
    # 生成 Xray Keys
    mkdir -p "$CONF_DIR/xrk"
    if [ ! -f "$CONF_DIR/xrk/private_key" ]; then
        if [ -f "$BIN_DIR/xray" ]; then
            key_pair=$("$BIN_DIR/xray" x25519)
            echo "$key_pair" | awk '/PrivateKey/{print $2}' > "$CONF_DIR/xrk/private_key"
            echo "$key_pair" | awk '/PublicKey/{print $2}' > "$CONF_DIR/xrk/public_key"
            openssl rand -hex 4 > "$CONF_DIR/xrk/short_id"
        fi
    fi

    # 写入 xr.json (Xray)
    cat > "$CONF_DIR/xr.json" <<EOF
{ "log": { "loglevel": "none" }, "inbounds": [
EOF
    # Reality
    if [ -n "$vlp" ] || [ -z "${vmp}${vwp}${hyp}${tup}" ]; then 
        [ -z "$port_vl_re" ] && port_vl_re=$(shuf -i 10000-65535 -n 1)
        echo "$port_vl_re" > "$CONF_DIR/port_vl_re"
        cat >> "$CONF_DIR/xr.json" <<EOF
    {
      "listen": "::", "port": $port_vl_re, "protocol": "vless",
      "settings": { "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "${ym_vl_re}:443", "serverNames": ["${ym_vl_re}"], "privateKey": "$(cat $CONF_DIR/xrk/private_key)", "shortIds": ["$(cat $CONF_DIR/xrk/short_id)"] } }
    },
EOF
    fi
    # Vmess
    if [ -n "$vmp" ]; then
        [ -z "$port_vm_ws" ] && port_vm_ws=$(shuf -i 10000-65535 -n 1)
        echo "$port_vm_ws" > "$CONF_DIR/port_vm_ws"
        cat >> "$CONF_DIR/xr.json" <<EOF
    {
      "listen": "::", "port": ${port_vm_ws}, "protocol": "vmess",
      "settings": { "clients": [{ "id": "${uuid}" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/${uuid}-vm" } }
    },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/xr.json"
    echo '], "outbounds": [{ "protocol": "freedom", "tag": "direct" }] }' >> "$CONF_DIR/xr.json"

    # 写入 sb.json (Singbox)
    cat > "$CONF_DIR/sb.json" <<EOF
{ "log": { "level": "info" }, "inbounds": [
EOF
    # Hysteria2
    if [ -n "$hyp" ] || [ -z "${vmp}${vwp}${vlp}${tup}" ]; then 
        [ -z "$port_hy2" ] && port_hy2=$(shuf -i 10000-65535 -n 1)
        echo "$port_hy2" > "$CONF_DIR/port_hy2"
        cat >> "$CONF_DIR/sb.json" <<EOF
    {
      "type": "hysteria2", "listen": "::", "listen_port": ${port_hy2},
      "users": [{ "password": "${uuid}" }],
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" }
    },
EOF
    fi
    # Tuic
    if [ -n "$tup" ]; then
        [ -z "$port_tu" ] && port_tu=$(shuf -i 10000-65535 -n 1)
        echo "$port_tu" > "$CONF_DIR/port_tu"
        cat >> "$CONF_DIR/sb.json" <<EOF
    {
      "type": "tuic", "listen": "::", "listen_port": ${port_tu},
      "users": [{ "uuid": "${uuid}", "password": "${uuid}" }],
      "congestion_control": "bbr",
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" }
    },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/sb.json"
    echo '], "outbounds": [{ "type": "direct", "tag": "direct" }] }' >> "$CONF_DIR/sb.json"
}

# --- 6. 服务管理 ---

setup_services() {
    USER_NAME=$(whoami)
    # 注册 Xray 服务
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
    # 注册 Singbox 服务
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
    echo "🔄 重启服务中..."
    systemctl is-active --quiet xray-clean && sudo systemctl restart xray-clean
    systemctl is-active --quiet singbox-clean && sudo systemctl restart singbox-clean
    sleep 2
    echo "✅ 服务已重启"
}

# --- 7. 快捷命令注册 (agsbx) ---

setup_shortcut() {
    # 1. 复制当前脚本到永久目录
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    
    # 2. 创建软链接到 /usr/local/bin (这样所有用户可用，且立即生效)
    if [ ! -f /usr/local/bin/agsbx ]; then
        echo "🔗 创建快捷命令 'agsbx'..."
        sudo ln -sf "$SCRIPT_PATH" /usr/local/bin/agsbx
    else
        # 确保链接指向正确
        sudo ln -sf "$SCRIPT_PATH" /usr/local/bin/agsbx
    fi
}

# --- 8. 功能指令 (List, Del, Up, etc) ---

cmd_list() {
    if [ ! -f "$CONF_DIR/uuid" ]; then echo "❌ 未找到配置，请先安装"; exit 1; fi
    get_ip
    uuid=$(cat "$CONF_DIR/uuid")
    ym_vl_re=$(cat "$CONF_DIR/ym_vl_re" 2>/dev/null)
    
    echo ""
    echo "================ [Argosbx 净化版状态] ================"
    echo "  UUID: $uuid"
    echo "  IP:   $server_ip"
    echo "------------------------------------------------------"
    
    [ -f "$CONF_DIR/port_vl_re" ] && echo "🔥 [Reality] vless://$uuid@$server_ip:$(cat $CONF_DIR/port_vl_re)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$ym_vl_re&fp=chrome&pbk=$(cat $CONF_DIR/xrk/public_key)&sid=$(cat $CONF_DIR/xrk/short_id)&type=tcp&headerType=none#Clean-Reality" && echo ""
    [ -f "$CONF_DIR/port_hy2" ] && echo "🚀 [Hysteria2] hysteria2://$uuid@$server_ip:$(cat $CONF_DIR/port_hy2)?security=tls&alpn=h3&insecure=1&sni=www.bing.com#Clean-Hy2" && echo ""
    [ -f "$CONF_DIR/port_vm_ws" ] && vm_json="{\"v\":\"2\",\"ps\":\"Clean-VMess\",\"add\":\"$server_ip\",\"port\":\"$(cat $CONF_DIR/port_vm_ws)\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"www.bing.com\",\"path\":\"/$uuid-vm\",\"tls\":\"\"}" && echo "🌀 [VMess] vmess://$(echo -n "$vm_json" | base64 -w 0)" && echo ""
    [ -f "$CONF_DIR/port_tu" ] && echo "🛸 [Tuic] tuic://$uuid:$uuid@$server_ip:$(cat $CONF_DIR/port_tu)?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.bing.com&allow_insecure=1#Clean-Tuic" && echo ""
    
    echo "======================================================"
}

cmd_uninstall() {
    echo "💣 正在卸载..."
    sudo systemctl stop xray-clean singbox-clean 2>/dev/null
    sudo systemctl disable xray-clean singbox-clean 2>/dev/null
    sudo rm -f /etc/systemd/system/xray-clean.service /etc/systemd/system/singbox-clean.service
    sudo systemctl daemon-reload
    sudo rm -f /usr/local/bin/agsbx
    rm -rf "$WORKDIR"
    echo "✅ 卸载完成，感谢使用。"
}

# --- 9. 主逻辑入口 ---

# 如果是 install 或 rep，需要先检查环境
if [[ -z "$1" ]] || [[ "$1" == "rep" ]]; then
    check_env
fi

case "$1" in
    list) cmd_list ;;
    del)  cmd_uninstall ;;
    res)  restart_services ;;
    upx)  
        echo "🆙 升级 Xray..."
        check_env
        download_xray && restart_services 
        ;;
    ups)  
        echo "🆙 升级 Sing-box..."
        check_env
        download_singbox && restart_services 
        ;;
    rep)
        echo "♻️ 重置配置 (保留二进制)..."
        rm -rf "$CONF_DIR"/*.json "$CONF_DIR"/port*
        generate_config
        restart_services
        cmd_list
        ;;
    *)
        # 默认安装流程
        echo ">>> 开始安装 Argosbx 净化版..."
        [ ! -f "$BIN_DIR/xray" ] && download_xray
        [ ! -f "$BIN_DIR/sing-box" ] && download_singbox
        generate_config
        setup_services
        setup_shortcut
        echo "✅ 安装完成！你现在可以直接输入 'agsbx' 或 'agsbx list' 使用快捷指令。"
        cmd_list
        ;;
esac
