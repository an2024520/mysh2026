#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}正在开始部署 Xray (VLESS + Reality + XHTTP)...${PLAIN}"

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# 2. 安装基础工具
echo -e "${YELLOW}正在安装必要工具...${PLAIN}"
apt update -y
apt install -y curl wget jq openssl uuid-runtime

# 3. 获取架构并下载最新 Xray
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) XRAY_ARCH="64" ;;
    arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}正在获取 Xray 最新版本...${PLAIN}"
# 获取 GitHub 最新 Release 版本号
LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)

if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
    echo -e "${RED}获取版本失败，网络连接可能存在问题。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}检测到最新版本: ${LATEST_VERSION}${PLAIN}"
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

# 创建目录并下载
mkdir -p /usr/local/bin/xray_core
wget -O /tmp/xray.zip "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！请检查网络。${PLAIN}"
    exit 1
fi

unzip -o /tmp/xray.zip -d /usr/local/bin/xray_core
chmod +x /usr/local/bin/xray_core/xray
rm -f /tmp/xray.zip

# 链接到系统路径
ln -sf /usr/local/bin/xray_core/xray /usr/local/bin/xray

# 4. 生成配置参数

# UUID
UUID=$(uuidgen)

# Reality 密钥对 (使用 xray 命令生成)
KEYS=$(/usr/local/bin/xray/xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')

# ShortID (生成 8 位 hex)
SHORT_ID=$(openssl rand -hex 4)

# 端口选择
read -p "请输入端口 (默认 443，推荐保持 443): " PORT
[[ -z "$PORT" ]] && PORT=443

# 伪装域名 (SNI)
read -p "请输入 Reality 伪装域名 (默认 www.microsoft.com): " SNI
[[ -z "$SNI" ]] && SNI="www.microsoft.com"

# XHTTP 路径 (Path)
read -p "请输入 XHTTP 路径 (默认 /debug，留空随机): " XHTTP_PATH
if [[ -z "$XHTTP_PATH" ]]; then
    XHTTP_PATH="/$(openssl rand -hex 4)"
fi

# 5. 生成配置文件 config.json
mkdir -p /usr/local/etc/xray

cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$XHTTP_PATH"
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

# 6. 配置 Systemd 服务
cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 7. 启动服务
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 8. 生成分享链接
PUBLIC_IP=$(curl -s4 ifconfig.me)
NODE_NAME="Xray-Reality-XHTTP"

# 标准 VLESS 链接格式
# vless://UUID@IP:PORT?security=reality&encryption=none&pbk=公钥&headerType=none&type=xhttp&sni=域名&sid=ShortID&path=路径&fp=chrome#备注
SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_NAME}"

echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}    Xray (VLESS+Reality+XHTTP) 部署完成   ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "地址 (IP)   : ${YELLOW}${PUBLIC_IP}${PLAIN}"
echo -e "端口 (Port) : ${YELLOW}${PORT}${PLAIN}"
echo -e "用户 ID (UUID): ${YELLOW}${UUID}${PLAIN}"
echo -e "伪装域名 (SNI): ${YELLOW}${SNI}${PLAIN}"
echo -e "路径 (Path) : ${YELLOW}${XHTTP_PATH}${PLAIN}"
echo -e "Short ID    : ${YELLOW}${SHORT_ID}${PLAIN}"
echo -e "Reality 公钥: ${YELLOW}${PUBLIC_KEY}${PLAIN}"
echo -e "----------------------------------------"
echo -e "🚀 [v2rayN / Nekoray 导入链接]:"
echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
echo -e "----------------------------------------"
echo -e "⚠️  客户端注意事项:"
echo -e "1. **核心版本**：XHTTP 是新协议，客户端的 Xray Core 必须 >= v1.8.24 (推荐 v24.11.21 以上)。"
echo -e "2. **v2rayN**：请确保设置 -> Xray Core 路径正确，并已更新内核。"
echo -e "3. **NekoRay**：切换核心为 Xray，并确保版本最新。"
echo -e ""
