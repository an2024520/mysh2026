#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> 开始部署 Xray 最新版 (适配 v25.12.8+ 格式)...${PLAIN}"

# 1. 检查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# 2. 清理旧环境 (确保纯净)
echo -e "${YELLOW}正在清理旧版本...${PLAIN}"
systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1
rm -rf /usr/local/bin/xray /usr/local/bin/xray_core /usr/local/etc/xray /etc/systemd/system/xray.service
systemctl daemon-reload

# 3. 安装依赖
apt update -y
apt install -y curl wget jq openssl uuid-runtime unzip

# 4. 下载 Xray 最新版 (动态获取 Latest)
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) XRAY_ARCH="64" ;;
    arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}正在获取 GitHub 最新版本信息...${PLAIN}"
# 这一步会抓取到 v25.12.8 或更新版本
LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)

if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
    echo -e "${RED}获取版本失败，请检查网络。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}即将安装版本: ${LATEST_VERSION}${PLAIN}"
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

mkdir -p /usr/local/bin/xray_core
wget -O /tmp/xray.zip "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在解压...${PLAIN}"
unzip -o /tmp/xray.zip -d /usr/local/bin/xray_core
rm -f /tmp/xray.zip
chmod +x /usr/local/bin/xray_core/xray

XRAY_BIN="/usr/local/bin/xray_core/xray"

# 5. 生成密钥 (适配 v25.12.8 新格式)
echo -e "${YELLOW}正在生成 Reality 密钥...${PLAIN}"

UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 4)

# --- 核心修改：适配新旧两种输出格式 ---
RAW_KEYS=$($XRAY_BIN x25519)

# 尝试抓取 "PrivateKey:" (新版无空格)
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "PrivateKey:" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# 如果抓不到，尝试抓取 "Private Key:" (旧版有空格，做个兼容)
if [[ -z "$PRIVATE_KEY" ]]; then
    PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "Private Key:" | awk -F ":" '{print $2}' | tr -d ' \r\n')
fi

# 拿到私钥后，让 Xray 反推公钥 (这是最稳的方法)
if [[ -n "$PRIVATE_KEY" ]]; then
    # 注意：反推命令的输出格式通常包含 "Public Key: xxxx"
    PUB_RAW=$($XRAY_BIN x25519 -i "$PRIVATE_KEY")
    PUBLIC_KEY=$(echo "$PUB_RAW" | grep "Public" | awk -F ":" '{print $2}' | tr -d ' \r\n')
fi

# 调试输出
echo -e "Private Key: ${PRIVATE_KEY}"
echo -e "Public Key : ${PUBLIC_KEY}"

if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
    echo -e "${RED}严重错误：密钥解析失败！可能 Xray 输出格式又变了。${PLAIN}"
    echo -e "原始输出如下："
    echo "$RAW_KEYS"
    exit 1
fi

# 6. 配置参数
PORT=443
# 使用微软作为伪装域名 (Reality 推荐)
SNI="www.microsoft.com"
# XHTTP 路径
XHTTP_PATH="/$(openssl rand -hex 4)"

# 7. 写入配置文件 config.json
mkdir -p /usr/local/etc/xray
CONFIG_FILE="/usr/local/etc/xray/config.json"

cat <<EOF > $CONFIG_FILE
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

# 8. 配置 Systemd
cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service (v25.12.8+)
Documentation=https://github.com/xtls
After=network.target

[Service]
User=root
# 确保使用绝对路径
ExecStart=/usr/local/bin/xray_core/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 9. 启动
echo -e "${YELLOW}正在启动服务...${PLAIN}"
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 10. 输出结果
PUBLIC_IP=$(curl -s4 ifconfig.me)
NODE_NAME="Xray-v25-${PUBLIC_IP}"

# 生成 VLESS 链接
# 注意：fp=chrome 是 Reality 的推荐指纹
SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_NAME}"

sleep 2
if systemctl is-active --quiet xray; then
    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}   Xray 最新版 (${LATEST_VERSION}) 部署成功   ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "IP 地址     : ${YELLOW}${PUBLIC_IP}${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "UUID        : ${YELLOW}${UUID}${PLAIN}"
    echo -e "Reality公钥 : ${YELLOW}${PUBLIC_KEY}${PLAIN}"
    echo -e "XHTTP 路径  : ${YELLOW}${XHTTP_PATH}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN / Nekoray 导入链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "⚠️  客户端提示:"
    echo -e "1. 你使用的是 Xray 最新版，请务必确保客户端内核也是最新 (v1.8.24+ 或 v24.x)。"
    echo -e "2. 移动端推荐使用 v2rayNG 最新版或 Sing-box。"
else
    echo -e "${RED}启动失败！请运行以下命令查看日志：${PLAIN}"
    echo -e "journalctl -u xray -e"
fi
