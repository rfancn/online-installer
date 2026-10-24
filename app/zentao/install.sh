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

mkdir -p "$SERVICE_DIR/data" "$SERVICE_DIR/db"


# 3. 选择部署方式
choose_install_mode || exit 1
if [ "$INSTALL_MODE" = direct ]; then
    ask_host_port "ZenTao 访问端口" 8080 || exit 1
else
    setup_app_certificate || exit 1
fi


# 4. 配置 MySQL root 密码
#    密码会写入 .env，并同时供 zentao 容器连接数据库使用
gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 5
    else
        od -An -N5 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

while true; do
    printf "请输入 MySQL root 密码（至少 8 位，回车自动生成 10 位随机密码）: "
    stty -echo
    read -r MYSQL_ROOT_PASSWORD || {
        stty echo
        printf "\n❌ 输入已结束（EOF），已中止。\n" >&2
        exit 1
    }
    stty echo
    printf "\n"

    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        MYSQL_ROOT_PASSWORD="$(gen_password)"
        printf "✅ 已自动生成随机密码\n"
        break
    fi
    if [ ${#MYSQL_ROOT_PASSWORD} -lt 8 ]; then
        printf "❌ 密码至少 8 位，请重新输入。\n"
        continue
    fi
    # 避免破坏 .env 解析：仅允许字母、数字与 . _ @ %% + -
    case "$MYSQL_ROOT_PASSWORD" in
        *[!A-Za-z0-9._@%+-]*)
            printf "❌ 密码只能包含字母、数字与 . _ @ %% + -，请重新输入。\n"
            continue
            ;;
    esac
    break
done


# 5. 安装 compose 与环境变量
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
TARGET_ENV_FILE="$SERVICE_DIR/.env"

if [ "$INSTALL_MODE" = direct ]; then
    cp resource/docker-compose.direct.yml "$COMPOSE_FILE"
else
    cp resource/docker-compose.yml "$COMPOSE_FILE"
fi
cp resource/.env "$TARGET_ENV_FILE"

if [ "$INSTALL_MODE" = direct ]; then
    sed -i "s|__ZENTAO_PORT__|$(sed_escape "$DIRECT_PORT")|g" "$TARGET_ENV_FILE"
    sed -i '/^ZENTAO_HOST=/d; /^ZENTAO_RESOLVER=/d; /^ZENTAO_CERT_MAIN=/d; /^ZENTAO_CERT_SANS=/d' "$TARGET_ENV_FILE"
else
    sed -i "s|__ZENTAO_HOST__|$(sed_escape "$APP_HOST")|g" "$TARGET_ENV_FILE"
    sed -i "s|__ZENTAO_RESOLVER__|$(sed_escape "$APP_RESOLVER")|g" "$TARGET_ENV_FILE"
    sed -i "s|__ZENTAO_CERT_MAIN__|$(sed_escape "$CERT_MAIN")|g" "$TARGET_ENV_FILE"
    sed -i "s|__ZENTAO_CERT_SANS__|$(sed_escape "$CERT_SANS")|g" "$TARGET_ENV_FILE"
    sed -i '/^ZENTAO_PORT=/d' "$TARGET_ENV_FILE"
fi
strip_empty_cert_domain_labels "$COMPOSE_FILE"
sed -i "s|__MYSQL_ROOT_PASSWORD__|$(sed_escape "$MYSQL_ROOT_PASSWORD")|g" "$TARGET_ENV_FILE"

# .env 含数据库密码，仅允许当前用户读写
chmod 600 "$TARGET_ENV_FILE"


# 6. 放行直接访问端口（反向代理模式由 Traefik 的 80/443 入口承接）
if [ "$INSTALL_MODE" = direct ]; then
    open_firewall_ports "$DIRECT_PORT/tcp"
fi


# 7. 收尾提示
printf -- "----------------------------------------\n"
if [ "$INSTALL_MODE" = direct ]; then
    printf "访问地址: http://<本机IP>:%s\n" "$DIRECT_PORT"
else
    printf "访问地址: https://%s\n" "$APP_HOST"
fi
printf -- "----------------------------------------\n"
printf "下一步：cd %s && docker compose up -d\n" "$SERVICE_DIR"
if [ "$INSTALL_MODE" = proxy ]; then
    printf "⚠️  请确认 %s 的 DNS 记录已指向本机。\n" "$APP_HOST"
fi
printf "ℹ️  首次访问请按页面提示完成 ZenTao 初始化安装。\n"

# 主账号切换会改写 .env 凭据，必须重建容器；新增 resolver 只需重启
if [ "${PRIMARY_SWITCHED:-0}" = 1 ]; then
    printf "⚠️  本次切换了 traefik 主账号（.env 凭据已变更），需重建容器生效：\n"
    printf "   cd %s && docker compose up -d --force-recreate\n" "$TRAEFIK_HOME"
elif [ "${RESOLVER_ADDED:-0}" = 1 ]; then
    printf "⚠️  本次新增了证书签发渠道（traefik 静态配置已变更），需重启 traefik 生效：\n"
    printf "   cd %s && docker compose restart\n" "$TRAEFIK_HOME"
fi

echo "✅ $INSTALL_NAME 安装完成！"