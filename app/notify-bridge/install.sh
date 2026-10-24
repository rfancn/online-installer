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

CONFIG_FILE="$SERVICE_DIR/config.toml"

# 生成随机 webhook token（5 字节，10 位十六进制）
gen_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 5
    else
        od -An -N5 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

# 转义 TOML 基本字符串中的反斜杠和双引号
toml_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 3. 选择部署方式
choose_install_mode || exit 1
if [ "$INSTALL_MODE" = direct ]; then
    ask_host_port "notify-bridge 访问端口" 8080 || exit 1
else
    setup_app_certificate || exit 1
fi

# 4. 基础配置
TOKEN="$(gen_token)"
if [ -z "$TOKEN" ]; then
    printf "❌ 致命错误: 随机 token 生成失败\n"
    exit 1
fi

cp resource/config.toml "$CONFIG_FILE"
sed -i "s|__TOKEN__|$(sed_escape "$TOKEN")|g" "$CONFIG_FILE"

# 5. 路由配置
ROUTE_KEYS=""
while true; do
    printf "==========================================\n"
    printf "🔗 新建通知路由\n"
    printf "==========================================\n"

    # 路由名会作为 URL 路径，只允许字母、数字、- 和 _
    while true; do
        read_required "请输入路由名（仅字母、数字、-、_）: " ROUTE_KEY || exit 1
        if [[ ! "$ROUTE_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
            printf "❌ 路由名只能包含字母、数字、- 和 _。\n" >&2
            continue
        fi
        case " $ROUTE_KEYS " in
            *" $ROUTE_KEY "*)
                printf "❌ 路由名 '%s' 已存在，请更换。\n" "$ROUTE_KEY" >&2
                continue
                ;;
        esac
        break
    done

    choose_option "请选择来源类型:" "zentao" SOURCE_TYPE || exit 1
    choose_option "请选择目标类型:" "mattermost" TARGET_TYPE || exit 1

    printf -- "------------------------------------------\n"
    printf "⚙️  Zentao 来源配置\n"
    read_default "Zentao URL" "http://zentao" ZENTAO_URL || exit 1
    read_required "Zentao 账号: " ZENTAO_ACCOUNT || exit 1
    read_secret "Zentao 密码: " ZENTAO_PASSWORD || exit 1

    printf -- "------------------------------------------\n"
    printf "⚙️  Mattermost 目标配置\n"
    read_default "Mattermost URL" "http://mattermost-app" MATTERMOST_URL || exit 1
    read_required "Mattermost 机器人用户名: " MATTERMOST_BOT_USER || exit 1
    read_secret "Mattermost 机器人 Token: " MATTERMOST_BOT_TOKEN || exit 1

    cat >> "$CONFIG_FILE" <<EOF

    [app.routes.$ROUTE_KEY]
            [app.routes.$ROUTE_KEY.source]
                type = "$SOURCE_TYPE"
                url = "$(toml_escape "$ZENTAO_URL")"
                account = "$(toml_escape "$ZENTAO_ACCOUNT")"
                password = "$(toml_escape "$ZENTAO_PASSWORD")"

            [app.routes.$ROUTE_KEY.target]
                type = "$TARGET_TYPE"
                url = "$(toml_escape "$MATTERMOST_URL")"
                bot_token = "$(toml_escape "$MATTERMOST_BOT_TOKEN")"
                bot_user = "$(toml_escape "$MATTERMOST_BOT_USER")"
EOF

    ROUTE_KEYS="$ROUTE_KEYS $ROUTE_KEY"

    printf "是否继续新建路由？(y/N): "
    read -r MORE || break
    case "$MORE" in
        y|Y) ;;
        *) break ;;
    esac
done

# 6. 安装 compose 与环境变量
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
TARGET_ENV_FILE="$SERVICE_DIR/.env"

if [ "$INSTALL_MODE" = direct ]; then
    cp resource/docker-compose.direct.yml "$COMPOSE_FILE"
    cp resource/.env "$TARGET_ENV_FILE"
    sed -i "s|__NOTIFY_BRIDGE_PORT__|$(sed_escape "$DIRECT_PORT")|g" "$TARGET_ENV_FILE"
    sed -i '/^NOTIFY_BRIDGE_HOST=/d; /^NOTIFY_BRIDGE_RESOLVER=/d; /^NOTIFY_BRIDGE_CERT_MAIN=/d; /^NOTIFY_BRIDGE_CERT_SANS=/d' "$TARGET_ENV_FILE"
else
    cp resource/docker-compose.yml "$COMPOSE_FILE"
    cp resource/.env "$TARGET_ENV_FILE"
    sed -i "s|__NOTIFY_BRIDGE_HOST__|$(sed_escape "$APP_HOST")|g" "$TARGET_ENV_FILE"
    sed -i "s|__NOTIFY_BRIDGE_RESOLVER__|$(sed_escape "$APP_RESOLVER")|g" "$TARGET_ENV_FILE"
    sed -i "s|__NOTIFY_BRIDGE_CERT_MAIN__|$(sed_escape "$CERT_MAIN")|g" "$TARGET_ENV_FILE"
    sed -i "s|__NOTIFY_BRIDGE_CERT_SANS__|$(sed_escape "$CERT_SANS")|g" "$TARGET_ENV_FILE"
    sed -i '/^NOTIFY_BRIDGE_PORT=/d' "$TARGET_ENV_FILE"
fi
strip_empty_cert_domain_labels "$COMPOSE_FILE"

# 配置中包含账号密码与 token，仅允许当前用户读写
chmod 600 "$CONFIG_FILE"

# 7. 放行直接访问端口（反向代理模式由 Traefik 的 80/443 入口承接）
if [ "$INSTALL_MODE" = direct ]; then
    open_firewall_ports "$DIRECT_PORT/tcp"
fi

# 8. 收尾提示
printf "==========================================\n"
printf "✅ %s 安装完成！\n" "$INSTALL_NAME"
printf "📂 安装目录: %s\n" "$SERVICE_DIR"
if [ "$INSTALL_MODE" = direct ]; then
    printf "🌐 访问地址: http://<本机IP>:%s\n" "$DIRECT_PORT"
else
    printf "🌐 访问地址: https://%s\n" "$APP_HOST"
fi
printf "🔑 Webhook Token: %s\n" "$TOKEN"
printf "🔗 已创建路由:\n"
for key in $ROUTE_KEYS; do
    printf "   POST /%s\n" "$key"
    printf "   - 请求头: X-Webhook-Token: %s\n" "$TOKEN"
    printf "   - 或 Bearer: Authorization: Bearer %s\n" "$TOKEN"
done
printf -- "----------------------------------------\n"
printf "下一步：cd %s && docker compose up -d\n" "$SERVICE_DIR"
if [ "$INSTALL_MODE" = proxy ]; then
    printf "⚠️  请确认 %s 的 DNS 记录已指向本机。\n" "$APP_HOST"
fi

# 主账号切换会改写 .env 凭据，必须重建容器；新增 resolver 只需重启
if [ "${PRIMARY_SWITCHED:-0}" = 1 ]; then
    printf "⚠️  本次切换了 traefik 主账号（.env 凭据已变更），需重建容器生效：\n"
    printf "   cd %s && docker compose up -d --force-recreate\n" "$TRAEFIK_HOME"
elif [ "${RESOLVER_ADDED:-0}" = 1 ]; then
    printf "⚠️  本次新增了证书签发渠道（traefik 静态配置已变更），需重启 traefik 生效：\n"
    printf "   cd %s && docker compose restart\n" "$TRAEFIK_HOME"
fi
printf "==========================================\n"