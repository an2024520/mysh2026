#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> 开始安装 Xray (VLESS + Reality + XHTTP) 修正版...${PLAIN}"

# 1. 检查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# 2. 清理旧环境 (防止冲突)
echo -e "${YELLOW}正在清理旧的 Xray 安装...${PLAIN}"
systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1
rm -rf /usr/local/bin/xray /usr/local/bin/xray_core /usr/local/etc/xray /etc/systemd/system/xray.service
systemctl daemon-reload

# 3. 安装依赖
echo -e "${YELLOW}正在安装必要工具...${PLAIN}"
apt update -y
apt install -y curl wget jq openssl uuid-runtime unzip

# 4. 下载 Xray 核心
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) XRAY_ARCH="64" ;;
    arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}正在获取最新版本信息...${PLAIN}"
LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
    echo -e "${RED}获取版本失败，请检查网络。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}下载版本: ${LATEST_VERSION}${PLAIN}"
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

mkdir -p /usr/local/bin/xray_core
wget -O /tmp/xray.zip "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在解压安装...${PLAIN}"
unzip -o /tmp/xray.zip -d /usr/local/bin/xray_core
rm -f /tmp/xray.zip
# 赋予执行权限
chmod +x /usr/local/bin/xray_core/xray

# 验证二进制文件
XRAY_BIN="/usr/local/bin/xray_core/xray"
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}严重错误: 安装后找不到 Xray 文件！${PLAIN}"
    exit 1
fi

# 5. 生成密钥和配置参数
echo -e "${YELLOW}正在生成身份密钥...${PLAIN}"

# UUID
UUID=$(uuidgen)
# Reality 密钥对 (使用刚安装的 xray 生成)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
# ShortID
SHORT_ID=$(openssl rand -hex 4)

if [[ -z "$PRIVATE_KEY" ]]; then
    echo -e "${RED}密钥生成失败，无法继续。${PLAIN}"
    exit 1
fi

# 端口和域名设置
PORT=443
SNI="www.microsoft.com"
XHTTP_PATH="/$(openssl rand -hex 4)"

# 6. 写入配置文件
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

# 7. 配置 Systemd (修正路径版)
cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target

[Service]
User=root
# 关键修改: 这里直接指向解压出来的绝对路径
ExecStart=/usr/local/bin/xray_core/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动服务
echo -e "${YELLOW}正在启动服务...${PLAIN}"
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 9. 生成链接并输出
PUBLIC_IP=$(curl -s4 ifconfig.me)
NODE_NAME="Xray-Reality-${PUBLIC_IP}"

# VLESS 链接
SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_NAME}"

# 10. 验证与结果
sleep 2
if systemctl is-active --quiet xray; then
    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    Xray (VLESS+Reality+XHTTP) 安装成功   ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "IP 地址     : ${YELLOW}${PUBLIC_IP}${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "UUID        : ${YELLOW}${UUID}${PLAIN}"
    echo -e "Flow        : ${YELLOW}空 (XHTTP 不需要 Flow)${PLAIN}"
    echo -e "Reality 公钥: ${YELLOW}${PUBLIC_KEY}${PLAIN}"
    echo -e "伪装域名    : ${YELLOW}${SNI}${PLAIN}"
    echo -e "XHTTP 路径  : ${YELLOW}${XHTTP_PATH}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN / Nekoray 导入链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "⚠️ 注意事项:"
    echo -e "1. 客户端核心必须更新到 Xray v1.8.24 以上。"
    echo -e "2. 如果连不上，请检查是否在云服务商安全组放行了 UDP 443 端口。"
    echo -e ""
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u xray -e${PLAIN}"
fi
