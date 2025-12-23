#!/bin/bash

# ============================================================
#  Cloudflare Tunnel (Argo) 一键部署脚本 (Debian/Ubuntu)
#  - 支持: Systemd 守护进程 / 开机自启
#  - 特性: 自动检测 IPv6 环境并应用修复参数
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

# 2. 收集 Token
echo -e "${GREEN}>>> Cloudflare Tunnel 部署向导${PLAIN}"
read -p "请输入 Cloudflare Tunnel Token (必填): " CF_TOKEN

if [[ -z "$CF_TOKEN" ]]; then
    echo -e "${RED}错误: Token 不能为空！${PLAIN}"
    exit 1
fi

# 3. 安装 Cloudflared
echo -e "${YELLOW}正在安装 Cloudflared...${PLAIN}"

# 删除旧版（如果存在）
if command -v cloudflared &> /dev/null; then
    rm -f /usr/bin/cloudflared
fi

# 根据架构下载
ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" == "amd64" ]]; then
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
elif [[ "$ARCH" == "arm64" ]]; then
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
else
    echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
    exit 1
fi

# 安装 deb 包
dpkg -i cloudflared.deb
rm -f cloudflared.deb

# 4. 智能环境检测 (核心修改点)
# ------------------------------------------------
echo -e "${YELLOW}正在检测网络环境...${PLAIN}"

EXTRA_ARGS=""

# 检测 IPv4 连通性 (超时时间 3秒)
if curl -4 -s --connect-timeout 3 https://1.1.1.1 >/dev/null; then
    echo -e "网络环境: ${GREEN}IPv4/Dual-Stack (标准模式)${PLAIN}"
else
    echo -e "网络环境: ${YELLOW}IPv6-Only (增强模式)${PLAIN}"
    echo -e "${GREEN}>>> 已自动启用 IPv6 专用参数 (--edge-ip-version 6 --protocol http2)${PLAIN}"
    # 强制使用 IPv6 连接 Edge，并使用 http2 协议防止 QUIC 在 NAT64 下断流
    EXTRA_ARGS="--edge-ip-version 6 --protocol http2"
fi
# ------------------------------------------------

# 5. 配置 Systemd 服务
echo -e "${YELLOW}正在配置系统服务...${PLAIN}"
cloudflared service uninstall 2>/dev/null

# 手动写入 Service 文件以确保参数正确
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
User=root
# 动态注入 EXTRA_ARGS 参数
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate $EXTRA_ARGS run --token $CF_TOKEN
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# 6. 启动服务
systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

echo -e "------------------------------------------------"
sleep 2
if systemctl is-active --quiet cloudflared; then
    echo -e "${GREEN}Cloudflare Tunnel 部署成功！${PLAIN}"
    echo -e "运行状态: ${GREEN}Active (Running)${PLAIN}"
    if [[ -n "$EXTRA_ARGS" ]]; then
        echo -e "应用参数: ${YELLOW}$EXTRA_ARGS${PLAIN}"
    fi
else
    echo -e "${RED}服务启动失败！请检查日志: journalctl -u cloudflared -e${PLAIN}"
fi
echo -e "------------------------------------------------"
