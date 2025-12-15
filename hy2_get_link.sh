#!/bin/bash
#默认开启证书认证：insecure=1
# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/hysteria/config.yaml"

# 1. 检查配置文件
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "找不到配置文件: $CONFIG_FILE"
    exit 1
fi

# 2. 提取配置信息
# 提取端口
PORT=$(grep "listen:" $CONFIG_FILE | awk -F':' '{print $3}' | tr -d ' ')
# 提取密码
PASSWORD=$(grep "password:" $CONFIG_FILE | head -n 1 | awk '{print $2}' | tr -d ' ')
# 提取 SNI (尝试从 proxy url 中提取域名，如果是自签模式的话)
SNI=$(grep "url:" $CONFIG_FILE | awk -F'/' '{print $3}')

# 如果提取不到 SNI (比如没配伪装)，默认给一个
if [[ -z "$SNI" ]]; then
    SNI="bing.com"
fi

# 3. 获取公网 IP
PUBLIC_IP=$(curl -s4 ifconfig.me)

# 4. 定义备注名称 (你可以修改这里，或者让脚本通过参数传入)
# 默认备注为: Hy2-IP地址
NODE_NAME="Hy2-${PUBLIC_IP}"

# 5. 生成链接
# 标准格式: hysteria2://密码@IP:端口?参数#备注
# insecure=1 表示允许不安全连接(自签证书必须加)，如果是 acme 证书则不需要这个参数
# 这里假设你是之前的自签证书环境，所以加上 insecure=1

LINK="hysteria2://${PASSWORD}@${PUBLIC_IP}:${PORT}/?insecure=1&sni=${SNI}&alpn=h3#${NODE_NAME}"

# 如果使用了 ACME 证书（端口通常是 443），链接不需要 insecure=1
if [[ "$PORT" == "443" ]]; then
   # 尝试获取 acme 域名
   DOMAIN=$(grep -A 1 "domains:" $CONFIG_FILE | tail -n 1 | tr -d ' -')
   if [[ -n "$DOMAIN" ]]; then
       # ACME 模式链接
       LINK="hysteria2://${PASSWORD}@${DOMAIN}:${PORT}/?sni=${DOMAIN}&alpn=h3#${NODE_NAME}"
   fi
fi

# 6. 输出结果
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}      Hysteria 2 节点分享链接          ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "节点备注: ${YELLOW}${NODE_NAME}${PLAIN}"
echo -e "IP 地址 : ${PUBLIC_IP}"
echo -e "端口    : ${PORT}"
echo -e "----------------------------------------"
echo -e "${YELLOW}${LINK}${PLAIN}"
echo -e "----------------------------------------"
echo -e "提示: 复制上方链接，在 v2rayN / Nekoray 中通过“从剪贴板导入”即可。"
echo -e ""
