#!/bin/bash

# 1. 引入公共库并初始化（load_common 内部完成：定位项目根、读取/指定服务根目录、创建 Docker 网络）
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
# 统一入口 run.sh 可能从任意目录调起；切到脚本所在目录，
# 使 resource/ 等相对路径在任何 cwd 下都有效
cd "$SCRIPT_PATH" || exit 1
COMMON_SCRIPT="${SCRIPT_PATH}/../../script/common.sh"

[ -f "$COMMON_SCRIPT" ] || { printf "❌ 致命错误: 找不到公共库 %s\n" "$COMMON_SCRIPT"; exit 1; }
. "$COMMON_SCRIPT"
load_common || exit 1

# 读取密码时会关闭终端回显，退出或中断时确保恢复
trap 'stty echo 2>/dev/null' EXIT
trap 'stty echo 2>/dev/null; exit 130' INT
trap 'stty echo 2>/dev/null; exit 143' TERM


# 2. 执行初始化（直接生成 $SERVICE_DIR 和 $SERVICE_NAME）
init_service || exit 1

echo "🚀 开始将服务安装到: $SERVICE_DIR"

# config: /etc/gitlab；logs: /var/log/gitlab；data: /var/opt/gitlab
mkdir -p "$SERVICE_DIR/config" "$SERVICE_DIR/logs" "$SERVICE_DIR/data"


# 3. 交互读取直接访问模式的外部主机地址
#    GitLab 依赖 external_url 生成页面链接，直接访问时需显式指定 IP/域名
ask_direct_host() {
    local default_host
    default_host=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$default_host" ] || default_host="127.0.0.1"

    while true; do
        printf "请输入直接访问使用的主机地址（IP 或域名）[%s]: " "$default_host"
        read -r DIRECT_HOST || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        DIRECT_HOST=${DIRECT_HOST:-$default_host}
        case "$DIRECT_HOST" in
            ''|*[[:space:]]*) printf "❌ 主机地址不能为空，且不能包含空格。\n"; continue ;;
        esac
        return 0
    done
}


# 4. 选择部署方式
choose_install_mode || exit 1

COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
TARGET_ENV_FILE="$SERVICE_DIR/.env"

if [ "$INSTALL_MODE" = direct ]; then
    ask_direct_host || exit 1
    ask_host_port "GitLab 访问端口" 8929 || exit 1
    cp resource/docker-compose.direct.yml "$COMPOSE_FILE"
else
    setup_app_certificate || exit 1
    cp resource/docker-compose.yml "$COMPOSE_FILE"
fi
cp resource/.env "$TARGET_ENV_FILE"

if [ "$INSTALL_MODE" = direct ]; then
    # 直接访问：容器内仍监听 HTTP 80，由宿主机端口映射对外
    sed -i "s|__GITLAB_HOST__|$(sed_escape "$DIRECT_HOST")|g" "$TARGET_ENV_FILE"
    sed -i "s|__GITLAB_PORT__|$(sed_escape "$DIRECT_PORT")|g" "$TARGET_ENV_FILE"
    sed -i "s|__GITLAB_EXTERNAL_URL__|$(sed_escape "http://${DIRECT_HOST}:${DIRECT_PORT}")|g" "$TARGET_ENV_FILE"
    sed -i '/^GITLAB_RESOLVER=/d; /^GITLAB_CERT_MAIN=/d; /^GITLAB_CERT_SANS=/d' "$TARGET_ENV_FILE"
else
    # 反向代理：TLS 由 Traefik 终止，external_url 使用 https
    sed -i "s|__GITLAB_HOST__|$(sed_escape "$APP_HOST")|g" "$TARGET_ENV_FILE"
    sed -i "s|__GITLAB_RESOLVER__|$(sed_escape "$APP_RESOLVER")|g" "$TARGET_ENV_FILE"
    sed -i "s|__GITLAB_CERT_MAIN__|$(sed_escape "$CERT_MAIN")|g" "$TARGET_ENV_FILE"
    sed -i "s|__GITLAB_CERT_SANS__|$(sed_escape "$CERT_SANS")|g" "$TARGET_ENV_FILE"
    sed -i "s|__GITLAB_EXTERNAL_URL__|$(sed_escape "https://${APP_HOST}")|g" "$TARGET_ENV_FILE"
    sed -i '/^GITLAB_PORT=/d' "$TARGET_ENV_FILE"
fi
strip_empty_cert_domain_labels "$COMPOSE_FILE"

# .env 含访问地址等部署信息，仅允许当前用户读写
chmod 600 "$TARGET_ENV_FILE"


# 5. 放行直接访问端口（反向代理模式由 Traefik 的 80/443 入口承接）
if [ "$INSTALL_MODE" = direct ]; then
    open_firewall_ports "$DIRECT_PORT/tcp"
fi


# 6. 收尾提示
printf -- "----------------------------------------\n"
if [ "$INSTALL_MODE" = direct ]; then
    printf "访问地址: http://%s:%s\n" "$DIRECT_HOST" "$DIRECT_PORT"
else
    printf "访问地址: https://%s\n" "$APP_HOST"
    printf "⚠️  请确认 %s 的 DNS 记录已指向本机。\n" "$APP_HOST"
fi
printf -- "----------------------------------------\n"
printf "下一步：cd %s && docker compose up -d\n" "$SERVICE_DIR"
printf "ℹ️  首次启动需要数分钟完成初始化；初始 root 密码见 %s/config/initial_root_password\n" "$SERVICE_DIR"

# 主账号切换会改写 .env 凭据，必须重建容器；新增 resolver 只需重启
if [ "${PRIMARY_SWITCHED:-0}" = 1 ]; then
    printf "⚠️  本次切换了 traefik 主账号（.env 凭据已变更），需重建容器生效：\n"
    printf "   cd %s && docker compose up -d --force-recreate\n" "$TRAEFIK_HOME"
elif [ "${RESOLVER_ADDED:-0}" = 1 ]; then
    printf "⚠️  本次新增了证书签发渠道（traefik 静态配置已变更），需重启 traefik 生效：\n"
    printf "   cd %s && docker compose restart\n" "$TRAEFIK_HOME"
fi

echo "✅ $INSTALL_NAME 安装完成！"