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
# 注意：trap 接管信号后默认的中止动作不再执行，handler 必须自行 exit，
# 否则 Ctrl+C 只会恢复 echo，脚本继续跑、无法中断（INT 惯例退出码 130，TERM 为 143）
trap 'stty echo 2>/dev/null' EXIT
trap 'stty echo 2>/dev/null; exit 130' INT
trap 'stty echo 2>/dev/null; exit 143' TERM


# ---------- 2. 安装模式判定 ----------
# DNS resolver 的新增统一走 configure.sh（入口: bash run.sh configure traefik），
# 或由业务应用在需要通配证书时引导新增；本脚本只负责安装/重装 traefik 本体。
MODE="fresh"
if [ -n "$TRAEFIK_HOME" ] && [ -f "$TRAEFIK_HOME/traefik.toml" ]; then
    printf "==========================================\n"
    printf "🔧 Traefik 已安装于: %s\n" "$TRAEFIK_HOME"
    if list_traefik_resolvers; then
        printf "🔐 现有 resolver 池:\n"
        for entry in "${RESOLVER_POOL[@]}"; do
            printf "   - %s\n" "$entry"
        done
    fi
    printf "==========================================\n"
    printf "  1) 完全重装（覆盖配置，保留 letsencrypt 证书存储；\n"
    printf "     如需新增 DNS resolver 请选取消后执行: bash run.sh configure traefik）\n"
    printf "  2) 取消\n"
    printf "请输入序号 (1/2) [2]: "
    read -r mode_choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    case "${mode_choice:-2}" in
        1) MODE="reinstall" ;;
        *) printf "已取消。新增 DNS resolver：bash run.sh configure traefik\n"; exit 0 ;;
    esac
fi

# ---------- 3. 目标目录确定 ----------
if [ "$MODE" = reinstall ]; then
    SERVICE_DIR="$TRAEFIK_HOME"
    printf "⚠️  将覆盖 %s 下的 traefik.toml/config/.env/docker-compose.yml（letsencrypt 数据保留），继续？(y/n) [n]: " "$SERVICE_DIR"
    read -r go || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    case "$go" in
        y|Y) printf "开始完全重装...\n" ;;
        *)   printf "已取消。\n"; exit 0 ;;
    esac
    SERVICE_NAME=$(basename "$SERVICE_DIR")
    # 清理旧声明式路由文件（历史方案遗留；域名声明现随应用 labels 下发）
    rm -f "$SERVICE_DIR"/config/acme-*.toml
else
    init_service || exit 1
fi

# 立即回填 TRAEFIK_HOME：collect_acme_meta / create_resolver 等按此定位配置文件
export TRAEFIK_HOME="$SERVICE_DIR"

echo "🚀 开始将服务安装到: $SERVICE_DIR"

CONFIG_DIR="${SERVICE_DIR}/config"
LETSENCRYPT_DIR="${SERVICE_DIR}/letsencrypt"
STATIC_CONFIG_FILE="${SERVICE_DIR}/traefik.toml"
ENV_FILE="${SERVICE_DIR}/.env"
COMPOSE_FILE="${SERVICE_DIR}/docker-compose.yml"


# ---------- 4. ACME 基础信息（邮箱与 CA 环境；已有则显示并询问是否沿用） ----------
# DNS resolver 池初始为空：首次需要签发证书的业务应用安装时引导新增，
# 或随时执行 bash run.sh configure traefik
printf "==========================================\n"
printf "🔐 请配置 Let's Encrypt 基础信息（供后续 DNS resolver 使用）\n"
printf "==========================================\n"
collect_acme_meta confirm_reuse || exit 1


# ---------- 5. 安装基础文件 ----------
mkdir -p "$CONFIG_DIR" "$LETSENCRYPT_DIR" "${SERVICE_DIR}/certs"
cp "$SCRIPT_PATH/resource/traefik.toml" "$STATIC_CONFIG_FILE"
cp "$SCRIPT_PATH/resource/config/dashboard.toml" "$CONFIG_DIR/dashboard.toml"
cp "$SCRIPT_PATH/resource/docker-compose.yml" "$COMPOSE_FILE"

# .env 仅存 DNS 凭据组（由 configure/应用新增 resolver 时追加），本体先写表头
printf "# Traefik 容器环境变量：DNS 服务商 API 凭据\n# lego 通过环境变量读取，用于 Let's Encrypt DNS-01 验证\n" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# 重装覆盖模板后，既有 DNS resolver 段被清空（证书存储文件保留）
if [ "$MODE" = reinstall ]; then
    printf "⚠️  重装已清空 resolver 池；DNS resolver 可经 bash run.sh configure traefik\n"
    printf "   重新添加（同名 provider 复用原证书存储），或在应用安装时引导新增。\n"
fi


# ---------- 6. 配置 Dashboard：先选证书方式，ACME 再定 resolver，最后推导访问域名 ----------
# ACME：从池选择/新增 resolver，或跳过（自签兜底）；静态：certResolver 置空，按 SNI 匹配
printf "==========================================\n"
printf "🔐 请配置 Traefik Dashboard\n"
printf "==========================================\n"
choose_cert_source "Traefik Dashboard" || exit 1
DASH_RESOLVER=""
if [ "$CERT_MODE" = auto ]; then
    choose_or_add_resolver "" allow_skip || exit 1
    DASH_RESOLVER="$APP_RESOLVER"
else
    printf "✅ 使用静态证书：请确认预置证书的 SAN 覆盖 Dashboard 访问域名，否则将回退自签默认证书。\n"
fi

# 默认访问域名推导：优先泛域名 resolver 的根域名（*.root@provider），
# 其次根域名池第一项，最后单域名 resolver 的域名；均无则需手动输入
default_dash=""
if [ -n "$DASH_RESOLVER" ] && [[ "$DASH_RESOLVER" == \*.*@* ]]; then
    default_dash="traefik.${DASH_RESOLVER#\*.}"
    default_dash="${default_dash%@*}"
elif [ -n "$ROOT_DOMAINS" ]; then
    default_dash="traefik.${ROOT_DOMAINS%% *}"
elif [ -n "$DASH_RESOLVER" ] && [[ "$DASH_RESOLVER" == *@* ]]; then
    default_dash="traefik.${DASH_RESOLVER%@*}"
fi
while true; do
    if [ -n "$default_dash" ]; then
        printf "请输入 Dashboard 访问域名（回车用默认）[%s]: " "$default_dash"
    else
        printf "请输入 Dashboard 访问域名（如 traefik.example.com）: "
    fi
    read -r DASHBOARD_DOMAIN || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    DASHBOARD_DOMAIN=${DASHBOARD_DOMAIN:-$default_dash}
    if [ -z "$DASHBOARD_DOMAIN" ]; then
        printf "❌ 无根域名可推导时 Dashboard 域名不能为空。\n"
        continue
    fi
    validate_root_domain "$DASHBOARD_DOMAIN" && break
done

# 确保 htpasswd 可用（缺失时经包管理器自动安装，覆盖主流发行版）；
# 安装失败必须中止，否则空哈希会静默写进 dashboard 认证配置
ensure_htpasswd || {
    printf "❌ htpasswd 不可用且自动安装失败，请手动安装后重试\n"
    printf "   （Debian/Ubuntu: apache2-utils | RHEL/CentOS/Fedora: httpd-tools | Alpine/openSUSE: apache2-utils | Arch: apache2）\n"
    exit 1
}

# 注意：这里的用户名/密码是 Traefik Dashboard 网页的登录凭证，
# 与安装提权用的系统管理员账户无关
printf "请输入 Dashboard 登录用户名（仅用于登录 Traefik Dashboard 网页，非系统管理员）: "
read -r DASHBOARD_USER || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }

printf "请输入 Dashboard 登录密码 (输入时不可见): "
stty -echo  # 隐藏密码输入
read -r DASHBOARD_PASS || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
stty echo   # 恢复显示
printf "\n"  # 换行，保持输出美观

# 生成密码哈希：-nB 表示在标准输出显示并使用 bcrypt 加密（Traefik 推荐）
HASH=$(htpasswd -nbB "$DASHBOARD_USER" "$DASHBOARD_PASS" | cut -d ":" -f 2)


# ---------- 7. 替换配置占位符 ----------
DASHBOARD_CONFIG_FILE="${CONFIG_DIR}/dashboard.toml"
sed -i "s|__DASH_BOARD_DOMAIN__|$(sed_escape "$DASHBOARD_DOMAIN")|g" "$DASHBOARD_CONFIG_FILE"
sed -i "s|__DASH_BOARD_CREDENTIAL__|$(sed_escape "${DASHBOARD_USER}:${HASH}")|g" "$DASHBOARD_CONFIG_FILE"
# Dashboard resolver 绑定：选中则替换占位符，跳过则删除整行（回退自签证书）
if [ -n "$DASH_RESOLVER" ]; then
    sed -i "s|__DASH_RESOLVER__|$(sed_escape "$DASH_RESOLVER")|g" "$DASHBOARD_CONFIG_FILE"
    printf "✅ Traefik Dashboard 认证配置已写入（证书 resolver: %s）！\n" "$DASH_RESOLVER"
else
    sed -i '/certResolver = "__DASH_RESOLVER__"/d' "$DASHBOARD_CONFIG_FILE"
    if [ "$CERT_MODE" = static ]; then
        printf "✅ Traefik Dashboard 配置已写入（静态证书按 SNI 匹配，未命中回退自签）！\n"
    else
        printf "✅ Traefik Dashboard 认证配置已写入（未绑定 resolver，暂用自签证书）！\n"
    fi
fi


# ---------- 8. 持久化 + 防火墙 + 收尾 ----------
set_installer_key TRAEFIK_HOME "$SERVICE_DIR" || exit 1

open_firewall_ports 80/tcp 443/tcp

printf -- "----------------------------------------\n"
printf "Dashboard:  https://%s/dashboard/\n" "$DASHBOARD_DOMAIN"
if [ -n "$DASH_RESOLVER" ]; then
    printf "Dashboard 证书: resolver %s\n" "$DASH_RESOLVER"
else
    printf "Dashboard 证书: 未绑定 resolver（自签兜底），可重跑本脚本或 configure 补配\n"
fi
printf -- "----------------------------------------\n"
printf "下一步：cd %s && docker compose up -d\n" "$SERVICE_DIR"
printf "ℹ️  业务应用安装时选择/新增 DNS resolver 并声明域名，签发经应用 labels\n"
printf "   动态下发（热加载）；resolver 池变更才需重启。\n"
printf "⚠️  请确认 %s 的 DNS 记录已指向本机（Dashboard 证书走 DNS-01）。\n" "$DASHBOARD_DOMAIN"

echo "✅ $INSTALL_NAME 安装完成！"
