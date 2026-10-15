#!/bin/bash

# 1. 引入公共库并自动计算服务名
# 使用标准的 $0 获取当前脚本的真实绝对路径
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
COMMON_SCRIPT="${SCRIPT_PATH}/../../script/common.sh"

# 检查公共库是否存在
if [ ! -f "$COMMON_SCRIPT" ]; then
    printf "❌ 致命错误: 找不到公共库 %s\n" "$COMMON_SCRIPT"
    exit 1
fi

# 引入公共库
. "$COMMON_SCRIPT"
load_common


# 2. 执行初始化（直接生成 $INSTALL_DIR 和 $SERVICE_NAME）
init_service || exit 1

echo "🚀 开始将服务安装到: $SERVICE_DIR"

mkdir -p "$SERVICE_DIR/conf" "$SERVICE_DIR/resources" "$SERVICE_DIR/logs" "$SERVICE_DIR/upload"

# 安装docker-compose.yml
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
cp resource/docker-compose.yml $COMPOSE_FILE

# 部署参数的唯一来源：.env（compose 用 ${...} 引用，config.yaml 的 dsn 由本脚本据此生成）
ENV_FILE=.env
TARGET_ENV_FILE=$SERVICE_DIR/$ENV_FILE
cp resource/$ENV_FILE $TARGET_ENV_FILE

CONFIG_FILE=conf/config.yaml
TARGET_CONFIG_FILE=$SERVICE_DIR/$CONFIG_FILE

cp resource/$CONFIG_FILE $TARGET_CONFIG_FILE

# 安装主题
THEME_NAME=theme-simple-corp-portal
TARGET_THEME_DIR="$SERVICE_DIR/resources/template/theme"
mkdir -p $TARGET_THEME_DIR
cp -fr resource/$THEME_NAME $TARGET_THEME_DIR


# 2.5 收集根域名与访问域名（写入 .env，供 Traefik 路由规则引用）
printf "==========================================\n"
printf "🌐 请配置域名\n"
printf "==========================================\n"
printf "（根域名需与 Traefik 泛域名证书一致，如 example.com）\n"
while true; do
    printf "请输入根域名: "
    read -r ROOT_DOMAIN
    case "$ROOT_DOMAIN" in
        ''|*[\"\'\ \`\$\*]*)
            printf "❌ 域名不能为空，且不能包含空格、引号、反引号、\$ 与 *。\n"
            continue
            ;;
    esac
    break
done

# 访问域名由根域名推导：默认落在 *.根域名 泛域名证书范围内
while true; do
    printf "请输入 airpress 访问域名 [airpress.%s]: " "$ROOT_DOMAIN"
    read -r AIRPRESS_HOST
    AIRPRESS_HOST=${AIRPRESS_HOST:-airpress.${ROOT_DOMAIN}}
    case "$AIRPRESS_HOST" in
        ''|*[\"\'\ \`\$]*)
            printf "❌ 域名不能为空，且不能包含空格、引号、反引号与 \$。\n"
            continue
            ;;
    esac
    break
done

# 不在泛域名范围内时 Traefik 会为它单独签一张证书，提示一下避免意外
# （证书为 main=*.根域名 + sans=根域名，两者都算已覆盖）
case "$AIRPRESS_HOST" in
    "$ROOT_DOMAIN"|*."$ROOT_DOMAIN") ;;
    *)
        printf "⚠️  %s 不在 *.%s 泛域名证书范围内，Traefik 将为它单独申请一张证书。\n" \
            "$AIRPRESS_HOST" "$ROOT_DOMAIN"
        ;;
esac
sed -i "s|^\(AIRPRESS_HOST=\).*|\1$(sed_escape "$AIRPRESS_HOST")|" "$TARGET_ENV_FILE"


# 3. 选择数据库类型
printf "==========================================\n"
printf "🗄️  请选择数据库类型\n"
printf "==========================================\n"
printf "  1) sqlite  (轻量，单文件，无需额外容器)\n"
printf "  2) mysql   (MySQL 数据库)\n"
printf "请输入序号 (1/2) [1]: "
read -r DB_CHOICE
DB_CHOICE=${DB_CHOICE:-1}

DB_TYPE="sqlite"
case "$DB_CHOICE" in
    1) DB_TYPE="sqlite" ;;
    2) DB_TYPE="mysql"  ;;
    *)
        printf "❌ 无效输入 '%s'，已回退为 sqlite。\n" "$DB_CHOICE"
        ;;
esac

# mysql 模式下进一步区分：随本服务一起起一个 MySQL 容器，还是连已有的外部 MySQL
MYSQL_MODE="container"
if [ "$DB_TYPE" = "mysql" ]; then
    printf "==========================================\n"
    printf "🗄️  请选择 MySQL 部署方式\n"
    printf "==========================================\n"
    printf "  1) 容器 MySQL  (随本服务一同启动，需要自动调优参数)\n"
    printf "  2) 外部 MySQL  (连接已有实例，不启动本地容器)\n"
    printf "请输入序号 (1/2) [1]: "
    read -r MYSQL_MODE_CHOICE
    case "$MYSQL_MODE_CHOICE" in
        2) MYSQL_MODE="external" ;;
        *) MYSQL_MODE="container" ;;
    esac
fi

# 从 docker-compose.yml 中移除 airpress-mysql 服务及其 depends_on
# （sqlite 与「外部 MySQL」两种模式都不需要本地 MySQL 容器）
strip_mysql_from_compose() {
    awk '
        /^  airpress-mysql:/                  { skip=1; next }
        /^networks:/                          { skip=0 }
        /^    depends_on:/                    { dep=1; next }
        dep==1 && /^      airpress-mysql:/    { dep=2; next }
        dep==2 && /^        condition:/       { dep=0; next }
        !skip && !dep                         { print }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# 按可用内存分档推导 MySQL 调优参数（buffer pool 约占可用内存的一半）
apply_mysql_tuning() {
    mem_g="$1"
    if   [ "$mem_g" -le 1 ];  then tier=1
    elif [ "$mem_g" -le 2 ];  then tier=2
    elif [ "$mem_g" -le 4 ];  then tier=4
    elif [ "$mem_g" -le 8 ];  then tier=8
    elif [ "$mem_g" -le 16 ]; then tier=16
    else tier=32
    fi

    case "$tier" in
        1)  INNODB_BUFFER_POOL_SIZE=256M; INNODB_BUFFER_POOL_INSTANCES=1; INNODB_LOG_FILE_SIZE=64M;  MAX_CONNECTIONS=100; THREAD_CACHE_SIZE=16 ;;
        2)  INNODB_BUFFER_POOL_SIZE=512M; INNODB_BUFFER_POOL_INSTANCES=1; INNODB_LOG_FILE_SIZE=128M; MAX_CONNECTIONS=150; THREAD_CACHE_SIZE=16 ;;
        4)  INNODB_BUFFER_POOL_SIZE=1G;   INNODB_BUFFER_POOL_INSTANCES=2; INNODB_LOG_FILE_SIZE=256M; MAX_CONNECTIONS=200; THREAD_CACHE_SIZE=32 ;;
        8)  INNODB_BUFFER_POOL_SIZE=2G;   INNODB_BUFFER_POOL_INSTANCES=4; INNODB_LOG_FILE_SIZE=512M; MAX_CONNECTIONS=300; THREAD_CACHE_SIZE=32 ;;
        16) INNODB_BUFFER_POOL_SIZE=4G; INNODB_BUFFER_POOL_INSTANCES=8; INNODB_LOG_FILE_SIZE=1G; MAX_CONNECTIONS=500; THREAD_CACHE_SIZE=32 ;;
        *)  INNODB_BUFFER_POOL_SIZE=8G;   INNODB_BUFFER_POOL_INSTANCES=8; INNODB_LOG_FILE_SIZE=2G;   MAX_CONNECTIONS=500; THREAD_CACHE_SIZE=64 ;;
    esac

    printf "🧩 内存档位 %sG：buffer_pool=%s instances=%s log_file=%s max_connections=%s\n" \
        "$tier" "$INNODB_BUFFER_POOL_SIZE" "$INNODB_BUFFER_POOL_INSTANCES" \
        "$INNODB_LOG_FILE_SIZE" "$MAX_CONNECTIONS"
}

if [ "$DB_TYPE" = "sqlite" ]; then
    # sqlite 模式：启用 sqlite3，注释掉 mysql dsn，并移除 MySQL 容器
    sed -i 's/^  enable: false *$/  enable: true/' "$TARGET_CONFIG_FILE"
    sed -i 's|^  dsn: |  # dsn: |' "$TARGET_CONFIG_FILE"
    strip_mysql_from_compose "$COMPOSE_FILE"
    # sqlite 不需要 MySQL 连接信息，删掉 .env 里 MYSQL_ 开头的变量（AIRPRESS_HOST 必须保留，
    # compose 的 Traefik 路由规则仍要引用它）
    sed -i '/^MYSQL_/d' "$TARGET_ENV_FILE"
    printf "✅ 已切换为 sqlite：docker-compose.yml 中的 MySQL 服务已移除。\n"
else
    # mysql 模式：收集连接信息与（仅容器模式下的）可用内存
    printf "==========================================\n"
    printf "🔐 请配置数据库密码\n"
    printf "==========================================\n"
    printf "（至少 8 位，且不能包含 @ : / ? \\\\ \" ' 与空格，以免破坏 DSN 与 YAML 解析）\n"
    while true; do
        printf "请输入数据库密码: "
        stty -echo  # 隐藏密码输入
        read -r MYSQL_PASSWORD
        stty echo  # 恢复输入
        printf "\n"  # 换行，保持输出美观

        if [ ${#MYSQL_PASSWORD} -lt 8 ]; then
            printf "❌ 密码至少 8 位，请重新输入。\n"
            continue
        fi
        # 会破坏 DSN 或 .env 解析的字符一律拒绝，省去后续层层转义
        case "$MYSQL_PASSWORD" in
            *[@:/?\\\"\'\ \$\&]*)
                printf "❌ 密码包含不允许的字符 (@ : / ? \\\\ \" ' 空格 & $)，请重新输入。\n"
                continue
                ;;
        esac
        break
    done

    printf "==========================================\n"
    printf "🔌 请配置 MySQL 主机名\n"
    printf "==========================================\n"
    if [ "$MYSQL_MODE" = "container" ]; then
        # 容器 MySQL：主机名就是容器名，可直接回车使用默认值
        printf "（docker-compose 中 mysql 服务的容器名，airpress-server 将用它作为 DSN 主机名）\n"
        printf "请输入 MySQL 主机名 [airpress-mysql57]: "
        read -r MYSQL_HOST
        MYSQL_HOST=${MYSQL_HOST:-airpress-mysql57}
        MYSQL_PORT=3306
        MYSQL_USER=airpress
        MYSQL_DB=airpress
    else
        # 外部 MySQL：主机名、端口、账号、库名都必须由用户显式提供
        while true; do
            printf "请输入 MySQL 主机名或 IP: "
            read -r MYSQL_HOST
            [ -n "$MYSQL_HOST" ] && break
            printf "❌ 主机名不能为空。\n"
        done
        printf "请输入 MySQL 端口 [3306]: "
        read -r MYSQL_PORT
        MYSQL_PORT=${MYSQL_PORT:-3306}
        case "$MYSQL_PORT" in
            ''|*[!0-9]*)
                printf "❌ 端口 '%s' 不是数字，已回退为 3306。\n" "$MYSQL_PORT"
                MYSQL_PORT=3306
                ;;
        esac
        # 用户名与库名同样要避开会破坏 DSN 的字符
        while true; do
            printf "请输入 MySQL 用户名: "
            read -r MYSQL_USER
            case "$MYSQL_USER" in
                ''|*[@:/?\\\"\'\ ]*)
                    printf "❌ 用户名不能为空，且不能包含 @ : / ? \\\\ \" ' 与空格。\n"
                    continue
                    ;;
            esac
            break
        done
        while true; do
            printf "请输入 MySQL 数据库名: "
            read -r MYSQL_DB
            case "$MYSQL_DB" in
                ''|*[@:/?\\\"\'\ ]*)
                    printf "❌ 库名不能为空，且不能包含 @ : / ? \\\\ \" ' 与空格。\n"
                    continue
                    ;;
            esac
            break
        done
    fi

    # 外部 MySQL 由用户自行运维，不接管其参数，因此不询问内存、不做调优
    if [ "$MYSQL_MODE" = "container" ]; then
        mkdir -p "$SERVICE_DIR/db"

        printf "==========================================\n"
        printf "🧠 请配置 MySQL 可用内存\n"
        printf "==========================================\n"
        printf "请输入可分配给 MySQL 的内存（单位 G，正整数）[4]: "
        read -r MYSQL_MEM_G
        MYSQL_MEM_G=${MYSQL_MEM_G:-4}
        case "$MYSQL_MEM_G" in
            ''|*[!0-9]*)
                printf "❌ 输入 '%s' 不是正整数，已回退为 4G。\n" "$MYSQL_MEM_G"
                MYSQL_MEM_G=4
                ;;
        esac
        [ "$MYSQL_MEM_G" -lt 1 ] && MYSQL_MEM_G=1

        apply_mysql_tuning "$MYSQL_MEM_G"
    fi

    ESCAPED_PASSWORD=$(sed_escape "$MYSQL_PASSWORD")
    ESCAPED_HOST=$(sed_escape "$MYSQL_HOST")
    ESCAPED_USER=$(sed_escape "$MYSQL_USER")
    ESCAPED_DB=$(sed_escape "$MYSQL_DB")

    if [ "$MYSQL_MODE" = "external" ]; then
        # 外部 MySQL：不启动本地容器，移除 compose 里的 mysql 服务与 depends_on，
        # 也不创建 db 数据目录（数据不在本机）
        strip_mysql_from_compose "$COMPOSE_FILE"
        rmdir "$SERVICE_DIR/db" 2>/dev/null
        # 调优参数只对本地容器有意义，外部实例由用户自行运维
        sed -i '/^MYSQL_INNODB_\|^MYSQL_MAX_CONNECTIONS=\|^MYSQL_THREAD_CACHE_SIZE=/d' "$TARGET_ENV_FILE"
        printf "✅ 已切换为外部 MySQL：本地 MySQL 容器已从 docker-compose.yml 移除。\n"
        printf "⚠️  请确认数据库 %s 与账号 %s 已在外部实例上创建好。\n" "$MYSQL_DB" "$MYSQL_USER"
    fi

    # 1) 先把收集到的信息写入 .env —— 它是 MySQL 配置的唯一来源
    sed -i "s|^\(MYSQL_USER=\).*|\1${ESCAPED_USER}|" "$TARGET_ENV_FILE"
    sed -i "s|^\(MYSQL_PASSWORD=\).*|\1${ESCAPED_PASSWORD}|" "$TARGET_ENV_FILE"
    sed -i "s|^\(MYSQL_HOST=\).*|\1${ESCAPED_HOST}|" "$TARGET_ENV_FILE"
    sed -i "s|^\(MYSQL_PORT=\).*|\1${MYSQL_PORT}|" "$TARGET_ENV_FILE"
    sed -i "s|^\(MYSQL_DB=\).*|\1${ESCAPED_DB}|" "$TARGET_ENV_FILE"
    sed -i "s|^\(MYSQL_INNODB_BUFFER_POOL_SIZE=\).*|\1${INNODB_BUFFER_POOL_SIZE}|" "$TARGET_ENV_FILE"
    sed -i "s|^\(MYSQL_INNODB_BUFFER_POOL_INSTANCES=\).*|\1${INNODB_BUFFER_POOL_INSTANCES}|" "$TARGET_ENV_FILE"
    sed -i "s|^\(MYSQL_INNODB_LOG_FILE_SIZE=\).*|\1${INNODB_LOG_FILE_SIZE}|" "$TARGET_ENV_FILE"
    sed -i "s|^\(MYSQL_MAX_CONNECTIONS=\).*|\1${MAX_CONNECTIONS}|" "$TARGET_ENV_FILE"
    sed -i "s|^\(MYSQL_THREAD_CACHE_SIZE=\).*|\1${THREAD_CACHE_SIZE}|" "$TARGET_ENV_FILE"

    # 2) 再由 .env 生成 config.yaml 的 dsn，保证两边不会各写一份而走偏
    #    注意：模板占位符后面已带 ?charset=... 查询串，这里只补到库名为止
    DSN="${MYSQL_USER}:${MYSQL_PASSWORD}@tcp(${MYSQL_HOST}:${MYSQL_PORT})/${MYSQL_DB}"
    sed -i "s|__MYSQL_USER__:__MYSQL_PASSWORD__@tcp(__MYSQL_HOST__:__MYSQL_PORT__)/__MYSQL_DB__|$(sed_escape "$DSN")|" "$TARGET_CONFIG_FILE"
fi

# 收紧 .env 权限：mysql 密码以明文存放在此，且只有宿主机上的 docker compose 需要读它
chmod 600 "$TARGET_ENV_FILE" 2>/dev/null
# 收紧 docker-compose.yml 权限：它含 MySQL 明文密码，且只有宿主机的 compose 需要读它
# （config.yaml 不在此列——它要被挂载进容器供应用读取，贸然改成 600 可能让容器内
#  非 root 用户读不到配置；确认镜像以 root 运行后可自行再收紧）
chmod 600 "$COMPOSE_FILE"

echo "✅ $INSTALL_NAME 安装完成！"

