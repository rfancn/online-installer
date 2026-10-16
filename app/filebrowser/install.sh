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


# 6. 确认访问域名（根域名来自 traefik 全局配置；二级域名默认服务名，需用户确认）
require_root_domain || exit 1
while true; do
    printf "请输入二级域名（完整访问域名为 <二级域名>.%s）[%s]: " "$ROOT_DOMAIN" "$SERVICE_NAME"
    read -r HOST_LABEL
    HOST_LABEL=${HOST_LABEL:-$SERVICE_NAME}
    case "$HOST_LABEL" in
        ''|*[\"\'\ \`\$\*]*)
            printf "❌ 二级域名不能为空，且不能包含空格、引号、反引号、\$ 与 *。\n"
            continue
            ;;
    esac
    APP_HOST="${HOST_LABEL}.${ROOT_DOMAIN}"

    printf "请确认访问域名: https://%s (y/n) [y]: " "$APP_HOST"
    read -r host_confirm
    case "${host_confirm:-y}" in
        y|Y) break ;;
        n|N) continue ;;
        *)   printf "❌ 无效输入 '%s'，请输入 y 或 n。\n" "$host_confirm" ;;
    esac
done
sed -i "s|__FILEBROWSER_HOST__|$(sed_escape "$APP_HOST")|g" "$TARGET_ENV_FILE"


# 7. 收尾提示
printf -- "----------------------------------------\n"
printf "访问地址: https://%s\n" "$APP_HOST"
printf -- "----------------------------------------\n"
printf "下一步：cd %s && docker compose up -d\n" "$SERVICE_DIR"
printf "⚠️  请确认 %s 的 DNS 记录已指向本机。\n" "$APP_HOST"
printf "🔑 首次启动的 admin 随机初始密码见：docker compose logs filebrowser（登录后请立即修改）。\n"

echo "✅ $INSTALL_NAME 安装完成！"
