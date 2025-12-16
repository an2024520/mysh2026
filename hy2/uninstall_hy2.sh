echo "正在停止并删除 Hysteria 2 服务..."

# 停止并禁用服务
systemctl stop hysteria-server
systemctl disable hysteria-server

# 删除服务文件、配置文件和程序本体
rm /etc/systemd/system/hysteria-server.service
rm /usr/local/bin/hysteria
rm -rf /etc/hysteria

# 重新加载 Systemd 配置
systemctl daemon-reload
systemctl reset-failed

echo "Hysteria 2 已彻底删除。"
echo "请注意：如果您手动添加了防火墙规则 (如 iptables, ufw)，可能需要手动清理它们。"
