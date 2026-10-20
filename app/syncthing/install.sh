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

# 读取密码时会关闭终端回显，退出或中断时确保恢复，避免终端留在"盲打"状态
trap 'stty echo 2>/dev/null' EXIT
trap 'stty echo 2>/dev/null; exit 130' INT
trap 'stty echo 2>/dev/null; exit 143' TERM


# 2. 执行初始化（直接生成 $SERVICE_DIR 和 $SERVICE_NAME）
init_service || exit 1

echo "🚀 开始将服务安装到: $SERVICE_DIR"


# 3. 预建数据目录（容器内 /var/syncthing：配置 + 默认同步目录）
mkdir -p "$SERVICE_DIR/data"

# 4. 安装 docker-compose.yml 与 .env
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
cp resource/docker-compose.yml "$COMPOSE_FILE"

# 部署参数来源：.env（compose 的 Traefik 路由规则用 ${SYNCTHING_HOST} 引用）
ENV_FILE=.env
TARGET_ENV_FILE=$SERVICE_DIR/$ENV_FILE
cp resource/$ENV_FILE "$TARGET_ENV_FILE"


# 5. 证书与域名配置（resolver 从 traefik 静态池选择或引导新增，
#    域名声明随本应用 labels 动态下发，自动触发签发）
setup_app_certificate || exit 1
sed -i "s|__SYNCTHING_HOST__|$(sed_escape "$APP_HOST")|g" "$TARGET_ENV_FILE"
sed -i "s|__SYNCTHING_RESOLVER__|$(sed_escape "$APP_RESOLVER")|g" "$TARGET_ENV_FILE"
sed -i "s|__SYNCTHING_CERT_MAIN__|$(sed_escape "$CERT_MAIN")|g" "$TARGET_ENV_FILE"
sed -i "s|__SYNCTHING_CERT_SANS__|$(sed_escape "$CERT_SANS")|g" "$TARGET_ENV_FILE"


# 6. 放行同步与局域网发现端口（改为 bridge 网络后由 compose 发布到宿主机）
open_firewall_ports 22000/tcp 22000/udp 21027/udp


# 7. 收尾提示
printf -- "----------------------------------------\n"
printf "访问地址: https://%s\n" "$APP_HOST"
printf -- "----------------------------------------\n"
printf "下一步：cd %s && docker compose up -d\n" "$SERVICE_DIR"
printf "⚠️  请确认 %s 的 DNS 记录已指向本机。\n" "$APP_HOST"
printf "🔐 GUI 通过公网域名暴露且初始无认证，首次打开后请立即在\n"
printf "   「设置 → 图形用户界面」中设置用户名与密码。\n"
printf "🔌 与其他设备同步需可达 TCP/UDP 22000 与 UDP 21027（云主机请检查安全组）。\n"

# 新增 resolver 修改的是 traefik 静态配置，必须重启容器才生效
if [ "${RESOLVER_ADDED:-0}" = 1 ]; then
    printf "⚠️  本次新增了证书签发渠道（traefik 静态配置已变更），需重启 traefik 生效：\n"
    printf "   cd %s && docker compose restart\n" "$TRAEFIK_HOME"
fi

echo "✅ $INSTALL_NAME 安装完成！"