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

# data: WordPress 站点文件；db: 容器模式下的 MySQL 数据目录
mkdir -p "$SERVICE_DIR/data" "$SERVICE_DIR/db"


# 3. 选择部署方式
choose_install_mode || exit 1
if [ "$INSTALL_MODE" = direct ]; then
    ask_host_port "WordPress 访问端口" 8080 || exit 1
else
    setup_app_certificate || exit 1
fi


# 4. 选择数据库部署方式（均为官方 MySQL Community 镜像）
printf "==========================================\n"
printf "🗄️  请选择 MySQL 部署方式\n"
printf "==========================================\n"
printf "  1) 容器 MySQL（随本服务一同启动，mysql:8.0）[默认]\n"
printf "  2) 外部 MySQL（连接已有实例，不启动本地容器）\n"
printf "请输入序号 (1/2) [1]: "
read -r MYSQL_MODE_CHOICE || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
case "${MYSQL_MODE_CHOICE:-1}" in
    2) MYSQL_MODE="external" ;;
    *) MYSQL_MODE="container" ;;
esac


# 5. 收集数据库参数
gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 8
    else
        od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

# 密码写入 .env 并作为容器环境变量，限制字符集避免破坏解析
validate_db_password() {
    [ ${#1} -ge 8 ] || return 1
    case "$1" in
        *[!A-Za-z0-9._@%+-]*) return 1 ;;
    esac
    return 0
}

read_db_password() {
    local label="$1" var_name="$2" allow_auto="$3" value
    while true; do
        printf "%s" "$label"
        stty -echo
        read -r value || {
            stty echo
            printf "\n❌ 输入已结束（EOF），已中止。\n" >&2
            exit 1
        }
        stty echo
        printf "\n"
        if [ -z "$value" ] && [ "$allow_auto" = auto ]; then
            value="$(gen_password)"
            printf "✅ 已自动生成随机密码\n"
            printf -v "$var_name" '%s' "$value"
            return 0
        fi
        if validate_db_password "$value"; then
            printf -v "$var_name" '%s' "$value"
            return 0
        fi
        printf "❌ 密码至少 8 位，且只能包含字母、数字与 . _ @ %% + -\n"
    done
}

read_db_ident() {
    local label="$1" default="$2" var_name="$3" value
    while true; do
        printf "%s [%s]: " "$label" "$default"
        read -r value || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
        value="${value:-$default}"
        case "$value" in
            ''|*[!A-Za-z0-9_.-]*)
                printf "❌ 不能为空，且只能包含字母、数字与 . _ -\n"
                continue
                ;;
        esac
        printf -v "$var_name" '%s' "$value"
        return 0
    done
}

if [ "$MYSQL_MODE" = "container" ]; then
    MYSQL_HOST="wordpress-mysql"
    MYSQL_PORT="3306"
    read_db_ident "请输入 MySQL 数据库名" "wordpress" MYSQL_DATABASE
    read_db_ident "请输入 MySQL 应用账号" "wordpress" MYSQL_USER
    # MySQL 官方镜像不允许用 MYSQL_USER 配置 root 账号
    while [ "$MYSQL_USER" = "root" ]; do
        printf "❌ 容器模式下的应用账号不能为 root，请重新输入。\n"
        read_db_ident "请输入 MySQL 应用账号" "wordpress" MYSQL_USER
    done
    read_db_password "请输入 MySQL 应用账号密码（至少 8 位，回车自动生成）: " MYSQL_PASSWORD auto
    read_db_password "请输入 MySQL root 密码（至少 8 位，回车自动生成）: " MYSQL_ROOT_PASSWORD auto
else
    printf "==========================================\n"
    printf "🔌 请配置外部 MySQL 连接信息\n"
    printf "==========================================\n"
    while true; do
        printf "请输入 MySQL 主机名或 IP: "
        read -r MYSQL_HOST || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
        case "$MYSQL_HOST" in
            ''|*[\"\'[:space:]\`\$]*) printf "❌ 主机名不能为空，且不能包含空格、引号、反引号与 \$。\n"; continue ;;
        esac
        break
    done
    while true; do
        printf "请输入 MySQL 端口 [3306]: "
        read -r MYSQL_PORT || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
        MYSQL_PORT="${MYSQL_PORT:-3306}"
        case "$MYSQL_PORT" in
            ''|*[!0-9]*) printf "❌ 端口须为数字，已回退为 3306。\n"; MYSQL_PORT=3306; break ;;
        esac
        if [ "$MYSQL_PORT" -ge 1 ] && [ "$MYSQL_PORT" -le 65535 ]; then break; fi
        printf "❌ 端口须在 1-65535。\n"
    done
    read_db_ident "请输入 MySQL 数据库名" "wordpress" MYSQL_DATABASE
    read_db_ident "请输入 MySQL 账号" "wordpress" MYSQL_USER
    read_db_password "请输入 MySQL 账号密码（至少 8 位）: " MYSQL_PASSWORD no
    MYSQL_ROOT_PASSWORD=""
    printf "⚠️  请确认数据库 %s 与账号 %s 已在外部实例上创建并授权。\n" "$MYSQL_DATABASE" "$MYSQL_USER"
fi


# 6. 安装 compose 与环境变量
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
TARGET_ENV_FILE="$SERVICE_DIR/.env"

if [ "$INSTALL_MODE" = direct ]; then
    cp resource/docker-compose.direct.yml "$COMPOSE_FILE"
else
    cp resource/docker-compose.yml "$COMPOSE_FILE"
fi
cp resource/.env "$TARGET_ENV_FILE"

if [ "$INSTALL_MODE" = direct ]; then
    sed -i "s|^\(WORDPRESS_PORT=\).*|\1$(sed_escape "$DIRECT_PORT")|" "$TARGET_ENV_FILE"
    sed -i '/^WORDPRESS_HOST=/d; /^WORDPRESS_RESOLVER=/d; /^WORDPRESS_CERT_MAIN=/d; /^WORDPRESS_CERT_SANS=/d' "$TARGET_ENV_FILE"
else
    sed -i "s|^\(WORDPRESS_HOST=\).*|\1$(sed_escape "$APP_HOST")|" "$TARGET_ENV_FILE"
    sed -i "s|^\(WORDPRESS_RESOLVER=\).*|\1$(sed_escape "$APP_RESOLVER")|" "$TARGET_ENV_FILE"
    sed -i "s|^\(WORDPRESS_CERT_MAIN=\).*|\1$(sed_escape "$CERT_MAIN")|" "$TARGET_ENV_FILE"
    sed -i "s|^\(WORDPRESS_CERT_SANS=\).*|\1$(sed_escape "$CERT_SANS")|" "$TARGET_ENV_FILE"
    sed -i '/^WORDPRESS_PORT=/d' "$TARGET_ENV_FILE"
fi

sed -i "s|^\(MYSQL_HOST=\).*|\1$(sed_escape "$MYSQL_HOST")|" "$TARGET_ENV_FILE"
sed -i "s|^\(MYSQL_PORT=\).*|\1$(sed_escape "$MYSQL_PORT")|" "$TARGET_ENV_FILE"
sed -i "s|^\(MYSQL_USER=\).*|\1$(sed_escape "$MYSQL_USER")|" "$TARGET_ENV_FILE"
sed -i "s|^\(MYSQL_PASSWORD=\).*|\1$(sed_escape "$MYSQL_PASSWORD")|" "$TARGET_ENV_FILE"
sed -i "s|^\(MYSQL_DATABASE=\).*|\1$(sed_escape "$MYSQL_DATABASE")|" "$TARGET_ENV_FILE"

# 外部 MySQL：移除本地数据库服务、depends_on 与无关变量/目录
strip_mysql_from_compose() {
    awk '
        /^  wordpress-mysql:/               { skip=1; next }
        /^networks:/                        { skip=0 }
        /^    depends_on:/                  { dep=1; next }
        dep==1 && /^      wordpress-mysql:/ { dep=2; next }
        dep==2 && /^        condition:/     { dep=0; next }
        !skip && !dep                       { print }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

if [ "$MYSQL_MODE" = "external" ]; then
    strip_mysql_from_compose "$COMPOSE_FILE"
    sed -i '/^MYSQL_ROOT_PASSWORD=/d' "$TARGET_ENV_FILE"
    rmdir "$SERVICE_DIR/db" 2>/dev/null
else
    sed -i "s|^\(MYSQL_ROOT_PASSWORD=\).*|\1$(sed_escape "$MYSQL_ROOT_PASSWORD")|" "$TARGET_ENV_FILE"
fi

# .env 与 compose 均含明文数据库密码，仅允许当前用户读写
chmod 600 "$TARGET_ENV_FILE"
chmod 600 "$COMPOSE_FILE"


# 7. 放行直接访问端口（反向代理模式由 Traefik 的 80/443 入口承接）
if [ "$INSTALL_MODE" = direct ]; then
    open_firewall_ports "$DIRECT_PORT/tcp"
fi


# 8. 收尾提示
printf -- "----------------------------------------\n"
if [ "$INSTALL_MODE" = direct ]; then
    printf "访问地址: http://<本机IP>:%s\n" "$DIRECT_PORT"
else
    printf "访问地址: https://%s\n" "$APP_HOST"
    printf "⚠️  请确认 %s 的 DNS 记录已指向本机。\n" "$APP_HOST"
fi
printf -- "----------------------------------------\n"
printf "下一步：cd %s && docker compose up -d\n" "$SERVICE_DIR"
printf "ℹ️  首次访问请按页面提示完成 WordPress 站点初始化。\n"

# 主账号切换会改写 .env 凭据，必须重建容器；新增 resolver 只需重启
if [ "${PRIMARY_SWITCHED:-0}" = 1 ]; then
    printf "⚠️  本次切换了 traefik 主账号（.env 凭据已变更），需重建容器生效：\n"
    printf "   cd %s && docker compose up -d --force-recreate\n" "$TRAEFIK_HOME"
elif [ "${RESOLVER_ADDED:-0}" = 1 ]; then
    printf "⚠️  本次新增了证书签发渠道（traefik 静态配置已变更），需重启 traefik 生效：\n"
    printf "   cd %s && docker compose restart\n" "$TRAEFIK_HOME"
fi

echo "✅ $INSTALL_NAME 安装完成！"