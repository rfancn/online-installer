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

# 4. 安装 docker-compose.yml 与 settings 模板
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
cp resource/docker-compose.yml "$COMPOSE_FILE"
cp resource/config/settings.json "$SERVICE_DIR/config/settings.json"

# 5. 部署参数来源：.env（compose 的 Traefik 路由规则用 ${FILEBROWSER_HOST} 引用）
ENV_FILE=.env
TARGET_ENV_FILE=$SERVICE_DIR/$ENV_FILE
cp resource/$ENV_FILE $TARGET_ENV_FILE


# 6. 收集根域名与访问域名（与 airpress 同模式）
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
    printf "请输入 filebrowser 访问域名 [filebrowser.%s]: " "$ROOT_DOMAIN"
    read -r FILEBROWSER_HOST
    FILEBROWSER_HOST=${FILEBROWSER_HOST:-filebrowser.${ROOT_DOMAIN}}
    case "$FILEBROWSER_HOST" in
        ''|*[\"\'\ \`\$]*)
            printf "❌ 域名不能为空，且不能包含空格、引号、反引号与 \$。\n"
            continue
            ;;
    esac
    break
done

# 不在泛域名范围内时 Traefik 会为它单独签一张证书，提示一下避免意外
# （证书为 main=*.根域名 + sans=根域名，两者都算已覆盖）
case "$FILEBROWSER_HOST" in
    "$ROOT_DOMAIN"|*."$ROOT_DOMAIN") ;;
    *)
        printf "⚠️  %s 不在 *.%s 泛域名证书范围内，Traefik 将为它单独申请一张证书。\n" \
            "$FILEBROWSER_HOST" "$ROOT_DOMAIN"
        ;;
esac
sed -i "s|__FILEBROWSER_HOST__|$(sed_escape "$FILEBROWSER_HOST")|g" "$TARGET_ENV_FILE"


# 7. 收尾提示
printf -- "----------------------------------------\n"
printf "访问地址: https://%s\n" "$FILEBROWSER_HOST"
printf -- "----------------------------------------\n"
printf "下一步：cd %s && docker compose up -d\n" "$SERVICE_DIR"
printf "⚠️  请确认 %s 的 DNS 记录已指向本机。\n" "$FILEBROWSER_HOST"
printf "🔑 首次启动的 admin 随机初始密码见：docker compose logs filebrowser（登录后请立即修改）。\n"

echo "✅ $INSTALL_NAME 安装完成！"
