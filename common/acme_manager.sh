#!/bin/bash

# ============================================================
#  ACME 证书管理脚本 (适配低配 VPS)
#  功能: 申请/续签/管理证书 + 导出路径信息
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

INFO_FILE="/etc/acme_info"

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本！${PLAIN}" && exit 1
}

install_deps() {
    echo -e "${GREEN}>>> 检查并安装依赖 (socat, curl, cron)...${PLAIN}"
    if [[ -n $(command -v apt-get) ]]; then
        apt-get update -y && apt-get install -y socat curl cron
    elif [[ -n $(command -v yum) ]]; then
        yum install -y socat curl cronie
        systemctl enable crond && systemctl start crond
    fi
}

install_acme() {
    if ! command -v acme.sh &> /dev/null; then
        echo -e "${GREEN}>>> 安装 acme.sh...${PLAIN}"
        read -p "请输入注册邮箱 (可随意填写): " ACME_EMAIL
        [[ -z "$ACME_EMAIL" ]] && ACME_EMAIL="cert@example.com"
        curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
        source ~/.bashrc
    else
        echo -e "${YELLOW}>>> acme.sh 已安装，跳过安装步骤。${PLAIN}"
    fi
}

issue_cert() {
    echo -e "\n${GREEN}>>> 请选择证书申请模式:${PLAIN}"
    echo -e "  1. HTTP 模式 (需要占用 80 端口，适合无 CDN 环境)"
    echo -e "  2. DNS 模式 (Cloudflare API，适合纯 IPv6 或开启 CDN 环境)"
    read -p "请选择 [1-2]: " MODE

    read -p "请输入申请证书的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1

    mkdir -p "/root/cert/${DOMAIN}"

    case "$MODE" in
        1)
            # HTTP Mode
            if lsof -i :80 &> /dev/null; then
                echo -e "${RED}警告: 80 端口被占用，请先停止占用 80 端口的服务 (如 Nginx)。${PLAIN}"
                exit 1
            fi
            echo -e "${GREEN}>>> 开始申请证书 (HTTP Standalone)...${PLAIN}"
            ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
            ;;
        2)
            # DNS Mode (Cloudflare)
            echo -e "${YELLOW}提示: 请准备好 Cloudflare API Token (需有 Zone.DNS 编辑权限)${PLAIN}"
            read -p "请输入 Cloudflare API Token: " CF_TOKEN
            if [[ -z "$CF_TOKEN" ]]; then
                echo -e "${RED}Token 不能为空！${PLAIN}"
                exit 1
            fi
            export CF_Token="$CF_TOKEN"
            echo -e "${GREEN}>>> 开始申请证书 (DNS Cloudflare)...${PLAIN}"
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -k ec-256 --force
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}" && exit 1
            ;;
    esac

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}>>> 证书申请失败，请检查报错信息。${PLAIN}"
        exit 1
    fi

    # 安装证书到指定目录
    echo -e "${GREEN}>>> 安装证书到 /root/cert/${DOMAIN} ...${PLAIN}"
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "/root/cert/${DOMAIN}/fullchain.crt" \
        --key-file       "/root/cert/${DOMAIN}/private.key" \
        --reloadcmd      "echo 'Cert updated'"

    # 导出路径信息
    echo "CERT_PATH=\"/root/cert/${DOMAIN}/fullchain.crt\"" > "$INFO_FILE"
    echo "KEY_PATH=\"/root/cert/${DOMAIN}/private.key\"" >> "$INFO_FILE"
    echo "DOMAIN=\"${DOMAIN}\"" >> "$INFO_FILE"

    echo -e "\n${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}  证书申请与安装成功！${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "公钥路径: /root/cert/${DOMAIN}/fullchain.crt"
    echo -e "私钥路径: /root/cert/${DOMAIN}/private.key"
    echo -e "路径信息已保存至: ${YELLOW}${INFO_FILE}${PLAIN}"
    echo -e "acme.sh 已配置自动续期。"
}

# Main
check_root
install_deps
install_acme
issue_cert