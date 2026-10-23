#!/bin/bash

# 1. 引入公共库并初始化（load_common 内部完成：定位项目根、读取/指定服务根目录、创建 Docker 网络）
# 使用标准的 $0 获取当前脚本的真实绝对路径
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
# 统一入口 install.sh 可能从任意目录调起；切到脚本所在目录，
# 使 resource/ 等相对路径在任何 cwd 下都有效
cd "$SCRIPT_PATH" || exit 1
COMMON_SCRIPT="${SCRIPT_PATH}/../../script/common.sh"

[ -f "$COMMON_SCRIPT" ] || { printf "❌ 致命错误: 找不到公共库 %s\n" "$COMMON_SCRIPT"; exit 1; }
. "$COMMON_SCRIPT"
load_common || exit 1

# 中断时确保退出（trap 接管信号后默认中止动作不再执行，handler 必须自行 exit）
trap 'stty echo 2>/dev/null' EXIT
trap 'stty echo 2>/dev/null; exit 130' INT
trap 'stty echo 2>/dev/null; exit 143' TERM


# 2. 执行初始化（直接生成 $SERVICE_DIR 和 $SERVICE_NAME）
init_service || exit 1

echo "🚀 开始将服务安装到: $SERVICE_DIR"


# 3. 预建挂载目录；日志文件必须先在宿主机侧存在，
#    否则 Docker 会把 ./logs/filebrowser.log 挂载点建成目录导致容器起不来
mkdir -p "$SERVICE_DIR/data" "$SERVICE_DIR/config" "$SERVICE_DIR/database" "$SERVICE_DIR/logs"
touch "$SERVICE_DIR/logs/filebrowser.log"

# 4. 选择部署方式，安装对应的 compose 与 settings 模板
choose_install_mode || exit 1

COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
cp resource/config/settings.json "$SERVICE_DIR/config/settings.json"

ENV_FILE=.env
TARGET_ENV_FILE=$SERVICE_DIR/$ENV_FILE
cp resource/$ENV_FILE "$TARGET_ENV_FILE"

if [ "$INSTALL_MODE" = direct ]; then
    # 直接访问：发布宿主机端口，不涉及域名与证书
    ask_host_port "FileBrowser 访问端口" 8080 || exit 1
    cp resource/docker-compose.direct.yml "$COMPOSE_FILE"
    sed -i "s|__FILEBROWSER_PORT__|$(sed_escape "$DIRECT_PORT")|g" "$TARGET_ENV_FILE"
    sed -i '/^FILEBROWSER_HOST=/d; /^FILEBROWSER_RESOLVER=/d; /^FILEBROWSER_CERT_MAIN=/d; /^FILEBROWSER_CERT_SANS=/d' "$TARGET_ENV_FILE"
else
    # 反向代理：域名声明随本应用 labels 动态下发，自动触发签发
    cp resource/docker-compose.yml "$COMPOSE_FILE"
    setup_app_certificate || exit 1
    sed -i "s|__FILEBROWSER_HOST__|$(sed_escape "$APP_HOST")|g" "$TARGET_ENV_FILE"
    sed -i "s|__FILEBROWSER_RESOLVER__|$(sed_escape "$APP_RESOLVER")|g" "$TARGET_ENV_FILE"
    sed -i "s|__FILEBROWSER_CERT_MAIN__|$(sed_escape "$CERT_MAIN")|g" "$TARGET_ENV_FILE"
    sed -i "s|__FILEBROWSER_CERT_SANS__|$(sed_escape "$CERT_SANS")|g" "$TARGET_ENV_FILE"
    sed -i '/^FILEBROWSER_PORT=/d' "$TARGET_ENV_FILE"
fi


# 5. 放行直接访问端口（反向代理模式由 Traefik 的 80/443 入口承接）
if [ "$INSTALL_MODE" = direct ]; then
    open_firewall_ports "$DIRECT_PORT/tcp"
fi


# 6. 收尾提示
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
printf "🔑 首次启动的 admin 随机初始密码见：docker compose logs filebrowser（登录后请立即修改）。\n"

# 主账号切换会改写 .env 凭据，必须重建容器；新增 resolver 只需重启
if [ "${PRIMARY_SWITCHED:-0}" = 1 ]; then
    printf "⚠️  本次切换了 traefik 主账号（.env 凭据已变更），需重建容器生效：\n"
    printf "   cd %s && docker compose up -d --force-recreate\n" "$TRAEFIK_HOME"
elif [ "${RESOLVER_ADDED:-0}" = 1 ]; then
    printf "⚠️  本次新增了证书签发渠道（traefik 静态配置已变更），需重启 traefik 生效：\n"
    printf "   cd %s && docker compose restart\n" "$TRAEFIK_HOME"
fi

echo "✅ $INSTALL_NAME 安装完成！"
