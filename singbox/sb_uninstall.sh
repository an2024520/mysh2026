#!/bin/bash

# ============================================================
#  Sing-box 彻底卸载脚本
#  - 功能: 停止服务 / 删除文件 / 清理 Systemd
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${RED}警告：此操作将卸载 Sing-box 并移除相关服务！${PLAIN}"
read -p "确定要继续吗？(y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo "操作已取消。"
    exit 0
fi

echo -e "${YELLOW}正在停止 Sing-box 服务...${PLAIN}"
systemctl stop sing-box
systemctl disable sing-box >/dev/null 2>&1

# 删除服务文件
if [[ -f "/etc/systemd/system/sing-box.service" ]]; then
    rm -f "/etc/systemd/system/sing-box.service"
    echo -e "已删除 systemd 服务文件。"
fi
systemctl daemon-reload

# 删除二进制文件
if [[ -f "/usr/local/bin/sing-box" ]]; then
    rm -f "/usr/local/bin/sing-box"
    echo -e "已删除核心二进制文件。"
fi

# 删除日志
rm -rf "/var/log/sing-box"
echo -e "已删除日志文件。"

# 删除配置 (询问)
if [[ -d "/usr/local/etc/sing-box" ]]; then
    read -p "是否同时删除配置文件目录 (/usr/local/etc/sing-box)? [y/n] (默认 y): " del_conf
    if [[ "$del_conf" != "n" ]]; then
        rm -rf "/usr/local/etc/sing-box"
        echo -e "已删除配置目录。"
    else
        echo -e "${GREEN}配置文件已保留。${PLAIN}"
    fi
fi

echo -e "----------------------------------------------------"
echo -e "${GREEN}Sing-box 卸载完成。${PLAIN}"
echo -e "----------------------------------------------------"
