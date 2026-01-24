#!/bin/bash

# ============================================================
#  ACME 证书管理脚本 v1.1
#  - 新增: 卸载/清理功能
#  - 优化: 菜单化操作
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
    # 仅在安装模式下检查依赖
    if [[ -n $(command -v apt-get) ]]; then
        apt-get update -y && apt-get install -y socat curl cron
    elif [[ -n $(command -v yum) ]]; then
        yum install -y socat curl cronie
        systemctl enable crond && systemctl start crond
    fi
}

install_acme_core() {
    if ! command -v acme.sh &> /dev/null && [[ ! -f ~/.acme.sh/acme.sh ]]; then
        echo -e "${GREEN}>>> 安装 acme.sh...${PLAIN}"
        read -p "请输入注册邮箱 (可随意填写): " ACME_EMAIL
        [[ -z "$ACME_EMAIL" ]] && ACME_EMAIL="cert@example.com"
        curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
        source ~/.bashrc
    else
        echo -e "${YELLOW}>>> acme.sh 已安装，跳过核心安装。${PLAIN}"
    fi
}

issue_cert() {
    install_deps
    install_acme_core
    
    echo -e "\n${GREEN}>>> 请选择证书申请模式:${PLAIN}"
    echo -e "  1. HTTP 模式 (占用 80 端口，适合无 CDN)"
    echo -e "  2. DNS 模式 (Cloudflare API，适合 IPv6/CDN)"
    read -p "请选择 [1-2]: " MODE

    read -p "请输入申请证书的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1

    mkdir -p "/root/cert/${DOMAIN}"

    case "$MODE" in
        1)
            if lsof -i :80 &> /dev/null; then
                echo -e "${RED}警告: 80 端口被占用，请先停止 Nginx/Apache。${PLAIN}"
                exit 1
            fi
            ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
            ;;
        2)
            echo -e "${YELLOW}提示: 需 Cloudflare API Token (Zone.DNS Edit 权限)${PLAIN}"
            read -p "请输入 Token: " CF_TOKEN
            [[ -z "$CF_TOKEN" ]] && echo -e "${RED}Token 不能为空！${PLAIN}" && exit 1
            export CF_Token="$CF_TOKEN"
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -k ec-256 --force
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}" && exit 1
            ;;
    esac

    if [[ $? -eq 0 ]]; then
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --fullchain-file "/root/cert/${DOMAIN}/fullchain.crt" \
            --key-file       "/root/cert/${DOMAIN}/private.key" \
            --reloadcmd      "echo 'Cert updated'"

        echo "CERT_PATH=\"/root/cert/${DOMAIN}/fullchain.crt\"" > "$INFO_FILE"
        echo "KEY_PATH=\"/root/cert/${DOMAIN}/private.key\"" >> "$INFO_FILE"
        echo "DOMAIN=\"${DOMAIN}\"" >> "$INFO_FILE"
        
        echo -e "${GREEN}>>> 证书申请成功！路径已记录至 $INFO_FILE${PLAIN}"
    else
        echo -e "${RED}>>> 申请失败。${PLAIN}"
    fi
}

uninstall_acme() {
    echo -e "\n${RED}>>> [危险] 正在执行卸载程序...${PLAIN}"
    read -p "确定要彻底移除 acme.sh 及其定时任务吗? [y/N]: " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "操作取消" && exit 0

    # 1. 调用官方卸载 (清理 cron 和 alias)
    if [[ -f ~/.acme.sh/acme.sh ]]; then
        ~/.acme.sh/acme.sh --uninstall
    fi

    # 2. 物理删除残留
    rm -rf ~/.acme.sh
    rm -f "$INFO_FILE"

    echo -e "${GREEN}>>> acme.sh 核心文件及配置已清理。${PLAIN}"

    # 3. 询问是否删除证书文件
    read -p "是否删除已申请的证书文件 (/root/cert/)? [y/N]: " DEL_CERT
    if [[ "$DEL_CERT" == "y" || "$DEL_CERT" == "Y" ]]; then
        rm -rf /root/cert
        echo -e "${GREEN}>>> 证书文件已删除。${PLAIN}"
    else
        echo -e "${YELLOW}>>> 证书文件已保留在 /root/cert/ 。${PLAIN}"
    fi
}

show_menu() {
    echo -e "\n${GREEN}=== ACME 证书管理器 v1.1 ===${PLAIN}"
    echo -e "  1. 申请/续签证书 (安装)"
    echo -e "  2. 卸载 acme.sh (清理)"
    echo -e "  0. 退出"
    echo -e "------------------------"
    read -p "请选择: " OPT
    case "$OPT" in
        1) issue_cert ;;
        2) uninstall_acme ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
}

# Main
check_root
show_menu