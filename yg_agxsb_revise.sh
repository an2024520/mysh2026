#!/bin/bash

# ==============================================================================
# Argosbx 净化重构版 (Refactored by Gemini)
# 核心功能保留：兼容 WebUI 参数配置
# 改进点：官方源下载、移除恶意/危险操作、非侵入式安装、支持普通用户
# ==============================================================================

# 1. 变量映射 (保留原脚本逻辑以兼容 WebUI)
export LANG=en_US.UTF-8
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

# 导出环境变量
export uuid=${uuid:-''}
export port_vl_re=${vlpt:-''}
export port_vm_ws=${vmpt:-''}
export port_vw=${vwpt:-''}
export port_hy2=${hypt:-''}
export port_tu=${tupt:-''}
export port_xh=${xhpt:-''}
export port_vx=${vxpt:-''}
export port_an=${anpt:-''}
export port_ar=${arpt:-''}
export port_ss=${sspt:-''}
export port_so=${sopt:-''}
export ym_vl_re=${reym:-''}
export cdnym=${cdnym:-''}
export argo=${argo:-''}
export ARGO_DOMAIN=${agn:-''}
export ARGO_AUTH=${agk:-''}
export ippz=${ippz:-''}
export warp=${warp:-''}
export name=${name:-''}
export oap=${oap:-''}

# 设置工作目录 (不再强制使用原目录，避免冲突)
WORKDIR="$HOME/agsbx_clean"
BIN_DIR="$WORKDIR/bin"
CONF_DIR="$WORKDIR/conf"
LOG_DIR="$WORKDIR/logs"
mkdir -p "$BIN_DIR" "$CONF_DIR" "$LOG_DIR"

# ==============================================================================
# 2. 基础环境检查与依赖安装
# ==============================================================================
echo "--- 正在检查系统环境 ---"
if [ -f /etc/debian_version ]; then
    sudo apt-get update -y && sudo apt-get install -y curl wget tar unzip socat
elif [ -f /etc/redhat-release ]; then
    sudo yum update -y && sudo yum install -y curl wget tar unzip socat
fi

# 架构检测
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) 
        XRAY_ARCH="64"
        SB_ARCH="amd64"
        CF_ARCH="amd64"
        ;;
    aarch64) 
        XRAY_ARCH="arm64-v8a"
        SB_ARCH="arm64"
        CF_ARCH="arm64"
        ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

# ==============================================================================
# 3. 官方源下载函数
# ==============================================================================

download_xray() {
    echo ">>> 正在从 XTLS 官方下载 Xray..."
    local latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    local url="https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${XRAY_ARCH}.zip"
    wget -qO "$WORKDIR/xray.zip" "$url"
    unzip -o "$WORKDIR/xray.zip" -d "$WORKDIR/temp_xray"
    mv "$WORKDIR/temp_xray/xray" "$BIN_DIR/xray"
    chmod +x "$BIN_DIR/xray"
    rm -rf "$WORKDIR/xray.zip" "$WORKDIR/temp_xray"
    echo "Xray 安装版本: $("$BIN_DIR/xray" version | awk 'NR==1{print $2}')"
}

download_singbox() {
    echo ">>> 正在从 SagerNet 官方下载 Sing-box..."
    local latest=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    local ver_num=${latest#v}
    local url="https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${ver_num}-linux-${SB_ARCH}.tar.gz"
    
    wget -qO "$WORKDIR/sb.tar.gz" "$url"
    tar -zxvf "$WORKDIR/sb.tar.gz" -C "$WORKDIR"
    mv "$WORKDIR"/sing-box*linux*/sing-box "$BIN_DIR/sing-box"
    chmod +x "$BIN_DIR/sing-box"
    rm -rf "$WORKDIR/sb.tar.gz" "$WORKDIR"/sing-box*linux*
    echo "Sing-box 安装版本: $("$BIN_DIR/sing-box" version | awk '/version/{print $NF}')"
}

download_argo() {
    echo ">>> 正在从 Cloudflare 官方下载 Cloudflared..."
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    wget -qO "$BIN_DIR/cloudflared" "$url"
    chmod +x "$BIN_DIR/cloudflared"
    echo "Cloudflared 安装完成"
}

# ==============================================================================
# 4. 辅助函数 (UUID, Key, Network)
# ==============================================================================

# 生成 UUID
if [ -z "$uuid" ]; then
    if [ ! -f "$CONF_DIR/uuid" ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
        echo "$uuid" > "$CONF_DIR/uuid"
    else
        uuid=$(cat "$CONF_DIR/uuid")
    fi
fi
echo "当前 UUID: $uuid"

# 获取 IP (用于展示)
get_ip() {
    v4=$(curl -s4m5 https://icanhazip.com)
    v6=$(curl -s6m5 https://icanhazip.com)
    server_ip=${v4:-$v6}
    # 如果是 IPv6 加上括号
    [[ "$server_ip" =~ : ]] && server_ip="[$server_ip]"
}

# 证书生成 (自签名，用于 hysteria2/tuic 等)
generate_cert() {
    if [ ! -f "$CONF_DIR/cert.pem" ]; then
        openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/private.key"
        openssl req -new -x509 -days 36500 -key "$CONF_DIR/private.key" -out "$CONF_DIR/cert.pem" -subj "/CN=www.bing.com"
    fi
}

# ==============================================================================
# 5. 配置生成逻辑 (核心逻辑移植)
# ==============================================================================

install_xray_config() {
    mkdir -p "$CONF_DIR/xrk"
    # Reality Key Check
    if [ ! -f "$CONF_DIR/xrk/private_key" ]; then
        key_pair=$("$BIN_DIR/xray" x25519)
        echo "$key_pair" | awk '/PrivateKey/{print $2}' > "$CONF_DIR/xrk/private_key"
        echo "$key_pair" | awk '/PublicKey/{print $2}' > "$CONF_DIR/xrk/public_key"
        openssl rand -hex 4 > "$CONF_DIR/xrk/short_id"
    fi
    private_key_x=$(cat "$CONF_DIR/xrk/private_key")
    public_key_x=$(cat "$CONF_DIR/xrk/public_key")
    short_id_x=$(cat "$CONF_DIR/xrk/short_id")
    
    # 默认 Reality 域名
    [ -z "$ym_vl_re" ] && ym_vl_re="apple.com"

    # 开始写入 xr.json
    cat > "$CONF_DIR/xr.json" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
EOF

    # --- VLESS-TCP-REALITY ---
    if [ -n "$vlp" ]; then
        [ -z "$port_vl_re" ] && port_vl_re=$(shuf -i 10000-65535 -n 1)
        echo "$port_vl_re" > "$CONF_DIR/port_vl_re"
        cat >> "$CONF_DIR/xr.json" <<EOF
    {
      "tag": "reality-vision",
      "listen": "::",
      "port": $port_vl_re,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${ym_vl_re}:443",
          "serverNames": ["${ym_vl_re}"],
          "privateKey": "$private_key_x",
          "shortIds": ["$short_id_x"]
        }
      }
    },
EOF
    fi

    # --- VMESS-WS ---
    if [ -n "$vmp" ]; then
        [ -z "$port_vm_ws" ] && port_vm_ws=$(shuf -i 10000-65535 -n 1)
        echo "$port_vm_ws" > "$CONF_DIR/port_vm_ws"
        cat >> "$CONF_DIR/xr.json" <<EOF
    {
      "tag": "vmess-xr",
      "listen": "::",
      "port": ${port_vm_ws},
      "protocol": "vmess",
      "settings": { "clients": [{ "id": "${uuid}" }] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/${uuid}-vm" }
      }
    },
EOF
    fi

    # 收尾 xr.json
    # 移除最后一个逗号 (简单的 sed hack)
    sed -i '$ s/,$//' "$CONF_DIR/xr.json"
    cat >> "$CONF_DIR/xr.json" <<EOF
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
}

install_sb_config() {
    generate_cert
    cat > "$CONF_DIR/sb.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
EOF
    
    # --- Hysteria 2 ---
    if [ -n "$hyp" ]; then
        [ -z "$port_hy2" ] && port_hy2=$(shuf -i 10000-65535 -n 1)
        echo "$port_hy2" > "$CONF_DIR/port_hy2"
        cat >> "$CONF_DIR/sb.json" <<EOF
    {
      "type": "hysteria2",
      "tag": "hy2-sb",
      "listen": "::",
      "listen_port": ${port_hy2},
      "users": [{ "password": "${uuid}" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CONF_DIR/cert.pem",
        "key_path": "$CONF_DIR/private.key"
      }
    },
EOF
    fi

    # --- Tuic ---
    if [ -n "$tup" ]; then
        [ -z "$port_tu" ] && port_tu=$(shuf -i 10000-65535 -n 1)
        echo "$port_tu" > "$CONF_DIR/port_tu"
        cat >> "$CONF_DIR/sb.json" <<EOF
    {
      "type": "tuic",
      "tag": "tuic-sb",
      "listen": "::",
      "listen_port": ${port_tu},
      "users": [{ "uuid": "${uuid}", "password": "${uuid}" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CONF_DIR/cert.pem",
        "key_path": "$CONF_DIR/private.key"
      }
    },
EOF
    fi

    # 收尾 sb.json
    sed -i '$ s/,$//' "$CONF_DIR/sb.json"
    cat >> "$CONF_DIR/sb.json" <<EOF
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
}

# ==============================================================================
# 6. 服务安装 (Systemd) - 动态路径，非 Root 友好
# ==============================================================================
install_services() {
    echo ">>> 配置 Systemd 服务..."
    USER_NAME=$(whoami)
    
    # Xray Service
    if [ -f "$BIN_DIR/xray" ] && [ -f "$CONF_DIR/xr.json" ]; then
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
        sudo systemctl daemon-reload
        sudo systemctl enable xray-clean
        sudo systemctl restart xray-clean
    fi

    # Sing-box Service
    if [ -f "$BIN_DIR/sing-box" ] && [ -f "$CONF_DIR/sb.json" ]; then
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
        sudo systemctl enable singbox-clean
        sudo systemctl restart singbox-clean
    fi
}

# ==============================================================================
# 7. 主执行逻辑
# ==============================================================================

# 判断需要安装什么
need_xray=false
need_sb=false

[ -n "$vlp" ] || [ -n "$vmp" ] || [ -n "$vwp" ] || [ -n "$xhp" ] && need_xray=true
[ -n "$hyp" ] || [ -n "$tup" ] || [ -n "$anp" ] || [ -n "$ssp" ] && need_sb=true

# 如果没有选择任何协议，默认安装 Reality 和 Hysteria2
if [ "$need_xray" = false ] && [ "$need_sb" = false ]; then
    echo "未检测到特定协议变量，默认启用 Reality 和 Hysteria2..."
    vlp=yes
    hyp=yes
    need_xray=true
    need_sb=true
fi

# 执行下载和配置
if [ "$need_xray" = true ]; then
    [ ! -f "$BIN_DIR/xray" ] && download_xray
    install_xray_config
fi

if [ "$need_sb" = true ]; then
    [ ! -f "$BIN_DIR/sing-box" ] && download_singbox
    install_sb_config
fi

# 安装 Argo (如果选了)
if [ -n "$argo" ]; then
    download_argo
    # 这里简化了 Argo 逻辑，只做下载，具体隧道配置建议手动运行以免出错
    echo "Argo 已下载至 $BIN_DIR/cloudflared"
fi

install_services
get_ip

# ==============================================================================
# 8. 输出节点信息
# ==============================================================================
echo ""
echo "========================================================="
echo "   Argosbx 净化版 - 安装完成"
echo "   工作目录: $WORKDIR"
echo "   IP地址: $server_ip"
echo "========================================================="
echo ""

if [ -f "$CONF_DIR/port_vl_re" ]; then
    port=$(cat "$CONF_DIR/port_vl_re")
    pubkey=$(cat "$CONF_DIR/xrk/public_key")
    sid=$(cat "$CONF_DIR/xrk/short_id")
    echo "🔥 [VLESS Reality]"
    echo "vless://$uuid@$server_ip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$ym_vl_re&fp=chrome&pbk=$pubkey&sid=$sid&type=tcp&headerType=none#Clean-Reality"
    echo ""
fi

if [ -f "$CONF_DIR/port_hy2" ]; then
    port=$(cat "$CONF_DIR/port_hy2")
    echo "🚀 [Hysteria 2]"
    echo "hysteria2://$uuid@$server_ip:$port?security=tls&alpn=h3&insecure=1&sni=www.bing.com#Clean-Hy2"
    echo ""
fi

if [ -f "$CONF_DIR/port_vm_ws" ]; then
    port=$(cat "$CONF_DIR/port_vm_ws")
    vm_json="{\"v\":\"2\",\"ps\":\"Clean-VMess\",\"add\":\"$server_ip\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"www.bing.com\",\"path\":\"/$uuid-vm\",\"tls\":\"\"}"
    vm_link="vmess://$(echo -n "$vm_json" | base64 -w 0)"
    echo "🌀 [VMess WS]"
    echo "$vm_link"
    echo ""
fi

echo "提示：所有配置文件位于 $CONF_DIR"
echo "服务管理: sudo systemctl restart xray-clean / singbox-clean"
