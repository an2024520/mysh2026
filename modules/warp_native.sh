#!/bin/bash

# 定义存储 WARP 凭证的配置文件路径
WARP_CONF_FILE="/etc/my_script/warp_native.conf"
mkdir -p "$(dirname "$WARP_CONF_FILE")"

# 检查依赖
check_warp_dependencies() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "正在安装 Python3 (用于计算 WARP Reserved 值)..."
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y python3
        elif [ -f /etc/redhat-release ]; then
            yum install -y python3
        fi
    fi
}

# 核心逻辑：获取 WARP 凭证 (提取自 Argosbx_Pure.sh)
get_warp_credentials() {
    check_warp_dependencies
    
    echo "========================================"
    echo "       Native WARP 凭证配置"
    echo "========================================"
    echo "1. 自动注册 (使用 wgcf 工具)"
    echo "2. 手动输入 (已有私钥和 Reserved)"
    echo "========================================"
    read -p "请选择 [1-2]: " choice

    local wp_key=""
    local wp_ip=""
    local wp_res=""

    if [ "$choice" == "1" ]; then
        echo "正在下载 wgcf 工具并注册账户..."
        
        # 判断架构下载对应 wgcf
        local arch=$(uname -m)
        local wgcf_arch="amd64"
        case "$arch" in
            aarch64) wgcf_arch="arm64" ;;
            x86_64) wgcf_arch="amd64" ;;
            *) echo "不支持的架构: $arch"; return 1 ;;
        esac

        # 临时工作目录
        local tmp_dir=$(mktemp -d)
        pushd "$tmp_dir" >/dev/null

        # 下载并运行 wgcf (逻辑源自 Argosbx)
        wget -qO wgcf "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${wgcf_arch}"
        chmod +x wgcf
        
        echo "注册账户中..."
        ./wgcf register --accept-tos >/dev/null 2>&1
        ./wgcf generate >/dev/null 2>&1

        if [ ! -f wgcf-profile.conf ]; then
            echo "错误：WARP 注册失败，无法生成配置文件。"
            popd >/dev/null
            rm -rf "$tmp_dir"
            return 1
        fi

        # --- 提取核心参数 (核心提取逻辑) ---
        # 1. 提取 PrivateKey
        wp_key=$(grep 'PrivateKey' wgcf-profile.conf | cut -d ' ' -f 3 | tr -d '\n\r ')
        
        # 2. 提取 Address (优先取 IPv6，因为 Native WARP 通常用 v6 连接)
        local raw_addr=$(grep 'Address' wgcf-profile.conf | cut -d '=' -f 2 | tr -d ' ')
        # 如果有多个IP(逗号分隔)，通常第二个是IPv6
        if [[ "$raw_addr" == *","* ]]; then
            wp_ip=$(echo "$raw_addr" | awk -F',' '{print $2}' | cut -d'/' -f1 | tr -d '\n\r ')
        else
            wp_ip=$(echo "$raw_addr" | cut -d'/' -f1 | tr -d '\n\r ')
        fi

        # 3. 计算 Reserved 值 (这是 Sing-box/Xray 连接 WARP 的关键)
        # Argosbx 使用 Python 将 base64 的 ClientID 转为 uint8 数组 [x, x, x]
        local client_id=$(grep "client_id" wgcf-account.toml | cut -d '"' -f 2)
        if [ -n "$client_id" ]; then
            wp_res=$(python3 -c "import base64; d=base64.b64decode('${client_id}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')")
        else
            wp_res="[]"
        fi

        echo "注册成功！"
        echo "PrivateKey: $wp_key"
        echo "Reserved:   $wp_res"
        
        popd >/dev/null
        rm -rf "$tmp_dir"

    elif [ "$choice" == "2" ]; then
        read -p "请输入 WARP Private Key: " wp_key
        read -p "请输入 Reserved 值 (格式如 [123, 45, 67]): " wp_res
        # 手动模式下 IP 可以给个默认的或者是空，配置生成时会处理
        wp_ip="2606:4700:110:8d8d:1845:c39f:2dd5:a03a"
    else
        return 1
    fi

    # 保存配置
    cat > "$WARP_CONF_FILE" <<EOF
WP_KEY="$wp_key"
WP_IP="$wp_ip"
WP_RES="$wp_res"
EOF
    echo "配置已保存至 $WARP_CONF_FILE"
}

# 生成 JSON 片段函数
# 用法: generate_warp_json "xray" 或 "singbox"
generate_warp_json() {
    local core_type="$1"
    
    if [ ! -f "$WARP_CONF_FILE" ]; then
        return 1
    fi
    source "$WARP_CONF_FILE"

    # 处理 Address 格式 (Argosbx 逻辑)
    # 如果获取到的已经是v6，则补充 v4 本地地址；如果是v4，则补充v6
    local warp_addr_json
    if [[ "$WP_IP" =~ .*:.* ]]; then 
        warp_addr_json="\"172.16.0.2/32\", \"${WP_IP}/128\""
    else 
        warp_addr_json="\"${WP_IP}/32\", \"2606:4700:110:8d8d:1845:c39f:2dd5:a03a/128\""
    fi

    # 固定参数
    local pub_key="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    local endpoint_host="engage.cloudflareclient.com" # 或者 162.159.192.1

    if [ "$core_type" == "xray" ]; then
        cat <<EOF
{
  "tag": "warp-out",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${WP_KEY}",
    "address": [ ${warp_addr_json} ],
    "peers": [
      {
        "publicKey": "${pub_key}",
        "endpoint": "${endpoint_host}:2408",
        "reserved": ${WP_RES}
      }
    ]
  }
}
EOF
    elif [ "$core_type" == "singbox" ]; then
        cat <<EOF
{
  "type": "wireguard",
  "tag": "warp-out",
  "address": [ ${warp_addr_json} ],
  "private_key": "${WP_KEY}",
  "peers": [
    {
      "server": "${endpoint_host}",
      "server_port": 2408,
      "public_key": "${pub_key}",
      "reserved": ${WP_RES}
    }
  ]
}
EOF
    fi
}
