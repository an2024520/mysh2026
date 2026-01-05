#!/bin/bash

# ============================================================
# 脚本名称：sb_camouflage.sh
# 功能：一键切换 Sing-box 的 [标准模式] 与 [隐身模式]
# 作用：防止 VPS 厂商扫描进程名与文件路径
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# --- 路径定义 ---
# 标准模式路径
STD_BIN="/usr/local/bin/sing-box"
STD_CONF_DIR="/usr/local/etc/sing-box"
STD_CONF_FILE="${STD_CONF_DIR}/config.json"
STD_SERVICE="sing-box"
STD_SERVICE_FILE="/etc/systemd/system/sing-box.service"

# 隐身模式路径 (伪装成 System Helper)
HIDE_BIN="/usr/local/bin/sys-service-manager"
HIDE_CONF_DIR="/usr/local/include/sys-helper"
HIDE_CONF_FILE="${HIDE_CONF_DIR}/core.conf"
HIDE_SERVICE="sys-daemon"
HIDE_SERVICE_FILE="/etc/systemd/system/sys-daemon.service"

# 检查 Root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ============================================================
# 1. 执行隐藏 (标准 -> 隐身)
# ============================================================
do_hide() {
    # 前置检查
    if [[ ! -f "$STD_BIN" ]] && [[ -f "$HIDE_BIN" ]]; then
        echo -e "${RED}检测到当前已经是 [隐身模式]，无法重复隐藏！${PLAIN}"
        return
    fi
    if [[ ! -f "$STD_BIN" ]]; then
        echo -e "${RED}错误：未找到原始 Sing-box 文件，请确认是否已安装。${PLAIN}"
        return
    fi

    echo -e "${YELLOW}>>> 正在执行伪装流程...${PLAIN}"

    # 1. 停止旧服务
    systemctl stop "$STD_SERVICE"
    systemctl disable "$STD_SERVICE"

    # 2. 迁移文件
    echo -e "正在迁移文件路径..."
    mv "$STD_CONF_DIR" "$HIDE_CONF_DIR"
    mv "$STD_BIN" "$HIDE_BIN"
    mv "${HIDE_CONF_DIR}/config.json" "$HIDE_CONF_FILE"

    # 3. 删除旧服务文件
    rm -f "$STD_SERVICE_FILE"

    # 4. 创建伪装服务文件
    echo -e "正在创建伪装服务 [sys-daemon]..."
    cat > "$HIDE_SERVICE_FILE" <<EOF
[Unit]
Description=System Daemon Service Manager
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=${HIDE_BIN} run -c ${HIDE_CONF_FILE}
Restart=always
RestartSec=5s
SyslogIdentifier=sys-daemon
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # 5. 启动新服务
    systemctl daemon-reload
    systemctl enable "$HIDE_SERVICE"
    systemctl start "$HIDE_SERVICE"

    sleep 2
    if systemctl is-active --quiet "$HIDE_SERVICE"; then
        echo -e "${GREEN}✅ 隐身成功！${PLAIN}"
        echo -e "当前进程名已伪装为: ${SKYBLUE}sys-service-manager${PLAIN}"
        echo -e "配置文件已隐藏至  : ${SKYBLUE}/usr/local/include/sys-helper/${PLAIN}"
    else
        echo -e "${RED}❌ 启动失败，请检查日志。${PLAIN}"
        # 失败回滚建议手动处理，避免脚本死循环
    fi
}

# ============================================================
# 2. 执行还原 (隐身 -> 标准)
# ============================================================
do_restore() {
    # 前置检查
    if [[ ! -f "$HIDE_BIN" ]] && [[ -f "$STD_BIN" ]]; then
        echo -e "${RED}检测到当前已经是 [标准模式]，无需还原！${PLAIN}"
        return
    fi
    if [[ ! -f "$HIDE_BIN" ]]; then
        echo -e "${RED}错误：未找到伪装文件，可能尚未执行过隐藏操作。${PLAIN}"
        return
    fi

    echo -e "${YELLOW}>>> 正在执行还原流程...${PLAIN}"

    # 1. 停止伪装服务
    systemctl stop "$HIDE_SERVICE"
    systemctl disable "$HIDE_SERVICE"

    # 2. 还原文件
    echo -e "正在还原文件路径..."
    mv "$HIDE_BIN" "$STD_BIN"
    mv "$HIDE_CONF_FILE" "${HIDE_CONF_DIR}/config.json"
    mv "$HIDE_CONF_DIR" "$STD_CONF_DIR"

    # 3. 删除伪装服务文件
    rm -f "$HIDE_SERVICE_FILE"

    # 4. 重建标准服务文件 (保留 Restart=always 增强稳定性)
    echo -e "正在重建标准服务 [sing-box]..."
    cat > "$STD_SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${STD_BIN} run -c ${STD_CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # 5. 启动标准服务
    systemctl daemon-reload
    systemctl enable "$STD_SERVICE"
    systemctl start "$STD_SERVICE"

    sleep 2
    if systemctl is-active --quiet "$STD_SERVICE"; then
        echo -e "${GREEN}✅ 还原成功！已恢复为标准 sing-box 模式。${PLAIN}"
        echo -e "现在你可以正常使用原始的删除脚本了。"
    else
        echo -e "${RED}❌ 还原后启动失败，请检查日志。${PLAIN}"
    fi
}

# ============================================================
# 3. 主菜单
# ============================================================
clear
echo -e "#############################################################"
echo -e "#            Sing-box 伪装/还原工具箱 (Process Mask)        #"
echo -e "#############################################################"
echo -e ""
echo -e "当前状态检测："
if pgrep -x "sys-service-man" > /dev/null; then
    echo -e "模式：${GREEN} [已隐身] ${PLAIN} (运行中: sys-daemon)"
elif pgrep -x "sing-box" > /dev/null; then
    echo -e "模式：${YELLOW} [标准模式] ${PLAIN} (运行中: sing-box)"
else
    echo -e "模式：${RED} [未运行] ${PLAIN}"
fi
echo -e ""
echo -e "  ${GREEN}1.${PLAIN} 🛡️  开启隐身 (Hide)"
echo -e "  ${YELLOW}2.${PLAIN} 🔄 还原标准 (Restore)"
echo -e "  ${SKYBLUE}0.${PLAIN} 退出"
echo -e ""
read -p "请选择操作 [0-2]: " choice

case $choice in
    1)
        do_hide
        ;;
    2)
        do_restore
        ;;
    0)
        exit 0
        ;;
    *)
        echo -e "${RED}无效输入！${PLAIN}"
        ;;
esac