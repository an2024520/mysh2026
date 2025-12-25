#!/bin/bash

# ============================================================
#  Sing-box 核心安装脚本 (v9.2 Dependency Fix)
#  - 修复: 补全 ca-certificates/tar 等缺失依赖 (防崩溃)
#  - 优化: 统一使用 curl (移除 wget 依赖)
#  - 兼容: 适配全局劫持，同时支持独立运行
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

BIN_PATH="/usr/local/bin/sing-box"
CONF_DIR="/usr/local/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
LOG_DIR="/var/log/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# =================================================
# 自动化模式 - 幂等性检查
# =================================================
if [[ "$AUTO_SETUP" == "true" ]] && [[ -f "$BIN_PATH" ]]; then
    CURRENT_VER=$($BIN_PATH version 2>/dev/null | head -n 1 | awk '{print $3}')
    echo -e "${GREEN}>>> [自动模式] 检测到 Sing-box (v${CURRENT_VER}) 已安装，跳过。${PLAIN}"
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    exit 0
fi

echo -e "${GREEN}>>> 开始安装/重置 Sing-box 核心环境...${PLAIN}"

# 2. [核心修复] 安装必要依赖
# 即使代理通了，没证书(ca-certificates)或没解压工具(tar)也会挂
echo -e "${YELLOW}正在安装运行依赖 (curl, tar, ca-certificates)...${PLAIN}"
apt update -y >/dev/null 2>&1
apt install -y curl tar openssl ca-certificates

# 3. 检查系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64) DOWNLOAD_ARCH="amd64" ;;
    aarch64) DOWNLOAD_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac
echo -e "检测到架构: ${SKYBLUE}$ARCH${PLAIN} -> ${DOWNLOAD_ARCH}"

# 4. 获取最新版本
echo -e "${YELLOW}正在获取最新 Release 版本信息...${PLAIN}"

# 逻辑: 如果有全局代理变量，优先使用；否则依赖入口脚本的函数劫持或直连
# 这里的处理是为了让脚本具备“独立运行”的能力
TARGET_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
if [[ -n "$GH_PROXY_URL" ]]; then
    API_URL="${GH_PROXY_URL}${TARGET_URL}"
else
    API_URL="${TARGET_URL}"
fi

# 使用 curl 获取 (带 -k 兼容部分自签 Worker 证书)
LATEST_VERSION=$(curl -sL -k -m 10 "$API_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

# 兜底重试
if [[ -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}API 获取失败，尝试原始地址...${PLAIN}"
    LATEST_VERSION=$(curl -sL -k -m 10 "${TARGET_URL}" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
fi

if [[ -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}错误: 无法获取 Sing-box 版本信息，请检查网络。${PLAIN}"
    exit 1
fi

VERSION_NUM=${LATEST_VERSION#v}
echo -e "最新版本: ${GREEN}$LATEST_VERSION${PLAIN}"

# 5. 下载并解压
TMP_DIR=$(mktemp -d)
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION_NUM}-linux-${DOWNLOAD_ARCH}.tar.gz"
FILENAME="sing-box.tar.gz"

if [[ -n "$GH_PROXY_URL" ]]; then
    FULL_DL_URL="${GH_PROXY_URL}${DOWNLOAD_URL}"
else
    FULL_DL_URL="${DOWNLOAD_URL}"
fi

echo -e "${YELLOW}正在下载核心文件...${PLAIN}"
# 统一使用 curl 下载，移除 wget 依赖
curl -L -k -o "${TMP_DIR}/${FILENAME}" "$FULL_DL_URL"

if [[ $? -ne 0 ]]; then
    echo -e "${RED}下载失败！请检查网络连接。${PLAIN}"
    rm -rf "$TMP_DIR"
    exit 1
fi

echo -e "正在解压..."
tar -xzf "${TMP_DIR}/${FILENAME}" -C "$TMP_DIR"

# 移动二进制文件
EXTRACTED_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "sing-box*")
if [[ -f "${EXTRACTED_DIR}/sing-box" ]]; then
    systemctl stop sing-box 2>/dev/null
    mv "${EXTRACTED_DIR}/sing-box" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    echo -e "${GREEN}核心文件已安装至: $BIN_PATH${PLAIN}"
else
    echo -e "${RED}解压异常，未找到二进制文件！${PLAIN}"
    rm -rf "$TMP_DIR"
    exit 1
fi
rm -rf "$TMP_DIR"

# 6. 初始化配置环境
mkdir -p "$CONF_DIR"
mkdir -p "$LOG_DIR"
touch "${LOG_DIR}/access.log"
touch "${LOG_DIR}/error.log"
chown -R nobody:nogroup "$LOG_DIR" 2>/dev/null || chown -R nobody:nobody "$LOG_DIR" 2>/dev/null

if [[ ! -f "$CONF_FILE" ]]; then
    echo -e "${YELLOW}生成默认基础配置...${PLAIN}"
    cat > "$CONF_FILE" <<EOF
{
  "log": {
    "level": "info",
    "output": "${LOG_DIR}/access.log",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": []
  }
}
EOF
else
    echo -e "${YELLOW}保留现有配置。${PLAIN}"
fi

# 7. 配置 Systemd 服务
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${BIN_PATH} run -c ${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动服务
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box

echo -e "----------------------------------------------------"
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}Sing-box 安装成功！${PLAIN} [v${VERSION_NUM}]"
else
    echo -e "${RED}服务启动失败，请检查日志。${PLAIN}"
fi
echo -e "----------------------------------------------------"
