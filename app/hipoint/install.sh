#!/bin/bash

# ================= app/hipoint/install.sh =================
# hipoint：纯 Traefik 反向代理接入（本应用不起自己的容器）。
# 在已装 traefik 的动态目录下生成 hipoint.toml（file provider，watch 热加载）：
#   - 管理前端(pc-admin)：根路径兜底 → 静态服务后端 + Cache-Control no-store
#   - API 多租户：每个租户域名 /api/ → StripPrefix → 共用 API 后端 + hd-sub-domain
# hd-sub-domain 由各域名剥去根域名自动派生（如 wx.h1dian.com → wx）。
# 翻译自原 nginx：Host/X-Forwarded-For 由 Traefik 默认透传不补；X-Real-IP 沿用
# 仓库既有策略省略（应用统一读 XFF）；root/try_files/index 属静态服务自身职责不译。

# 统一入口可能从任意目录调起；切到脚本所在目录使相对路径在任何 cwd 下有效
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_PATH" || exit 1
COMMON_SCRIPT="${SCRIPT_PATH}/../../script/common.sh"

[ -f "$COMMON_SCRIPT" ] || { printf "❌ 致命错误: 找不到公共库 %s\n" "$COMMON_SCRIPT"; exit 1; }
. "$COMMON_SCRIPT"
load_common || exit 1

# 交互输入退出/中断时恢复回显并保证 Ctrl+C 能终止（与其余安装脚本一致）
trap 'stty echo 2>/dev/null' EXIT
trap 'stty echo 2>/dev/null; exit 130' INT
trap 'stty echo 2>/dev/null; exit 143' TERM


# ---------- 小工具 ----------
# 去首尾空白
trim() { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# 后端地址归一化：补 http:// 前缀；把容器内够不着宿主的 localhost/127.0.0.1
# 改写为 host.docker.internal（依赖 traefik compose 的 host-gateway 映射）
normalize_url() {
    local u
    u=$(trim "$1")
    [ -n "$u" ] || return 1
    case "$u" in
        *://*) : ;;
        *) u="http://$u" ;;
    esac
    printf '%s' "$u" | sed -E 's#^(https?)://(localhost|127\.0\.0\.1)([:/])#\1://host.docker.internal\3#'
}

# TOML 双引号字符串内的最小转义（\ 与 "）
toml_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# 域名 → Traefik 资源名安全的 slug（非字母数字统一转 -，去首尾 -）
slug() { printf '%s' "$1" | tr -cs 'A-Za-z0-9' '-' | sed -E 's/^-+//; s/-+$//'; }

# 从访问域名派生 hd-sub-domain：剥去根域名后缀；精确模式无根域名时退化为首个标签
derive_sub() {
    local h="$1"
    if [ -n "$SELECTED_ROOT_DOMAIN" ]; then
        printf '%s' "${h%.${SELECTED_ROOT_DOMAIN}}"
    else
        printf '%s' "${h%%.*}"
    fi
}


# ---------- 1. 服务目录（存放本应用生成结果留档，便于后续手改/卸载） ----------
init_service || exit 1
printf "🚀 开始安装 hipoint（Traefik 反向代理接入）\n"


# ---------- 2. 主访问域名 + 证书 resolver（复用公共流程） ----------
printf "==========================================\n"
printf "🌐 hipoint 主访问域名（管理前端所在域名，如 hipoint.h1dian.com）\n"
printf "==========================================\n"
setup_app_certificate || exit 1
MAIN_HOST="$APP_HOST"


# ---------- 3. API 租户域名集合（主域名自带 API；通配模式可继续追加 api-only 租户） ----------
API_HOSTS=("$MAIN_HOST")
if [ -n "$SELECTED_ROOT_DOMAIN" ]; then
    printf "==========================================\n"
    printf "🧩 追加 API 租户域名（仅转发 /api/，hd-sub-domain 自动=剥掉 .%s）\n" "$SELECTED_ROOT_DOMAIN"
    printf "   例：wx.%s。每行一个，空行结束。\n" "$SELECTED_ROOT_DOMAIN"
    printf "==========================================\n"
    while true; do
        printf "追加租户域名（回车结束）: "
        IFS= read -r extra || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
        extra=$(trim "$extra")
        [ -z "$extra" ] && break
        validate_root_domain "$extra" || continue
        case "$extra" in
            *".${SELECTED_ROOT_DOMAIN}") API_HOSTS+=("$extra") ;;
            *) printf "❌ 租户域名须以 .%s 结尾（否则通配证书不覆盖），请重新输入。\n" "$SELECTED_ROOT_DOMAIN" ;;
        esac
    done
else
    printf "ℹ️  精确域名模式：仅主域名生成 API 路由，hd-sub-domain 取首个标签 '%s'。\n" "$(derive_sub "$MAIN_HOST")"
fi


# ---------- 4. 后端地址（宿主机 host.docker.internal 或任意 ip/域名，安装时采集） ----------
printf "==========================================\n"
printf "🔌 后端地址（填 http://host.docker.internal:<端口> 转发到宿主机，或任意 http://ip:端口 / 域名）\n"
printf "==========================================\n"
while true; do
    printf "API 后端地址（nginx 原 :1000）[http://host.docker.internal:1000]: "
    IFS= read -r API_BACKEND || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    API_BACKEND=$(normalize_url "${API_BACKEND:-http://host.docker.internal:1000}") && break
    printf "❌ 地址不能为空，请重新输入。\n"
done
while true; do
    printf "管理前端静态服务地址（如 http://host.docker.internal:8080）: "
    IFS= read -r ADMIN_BACKEND || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    ADMIN_BACKEND=$(normalize_url "$ADMIN_BACKEND") && break
    printf "❌ 静态服务地址不能为空，请重新输入。\n"
done


# ---------- 5. 动态配置生成器（可变租户数，逐段 printf 输出到 stdout） ----------
# 通配模式才下发 [[...tls.domains]]；精确模式留空由 Traefik 按 rule 域名自动签发
tls_domains_block() {
    local path="$1"
    [ -n "$CERT_MAIN" ] || return 0
    printf '    [[%s.tls.domains]]\n' "$path"
    printf '      main = "%s"\n'     "$(toml_escape "$CERT_MAIN")"
    printf '      sans = ["%s"]\n'   "$(toml_escape "$CERT_SANS")"
}

render_toml() {
    printf '# ================= hipoint 动态配置（由 install.sh 生成，请勿手改） =================\n'
    printf '# 生成时间: %s\n\n' "$(date '+%F %T')"

    printf '# --- API 共用后端（多租户同打到 :1000）---\n'
    printf '[http.services.hipoint-api-svc.loadBalancer]\n'
    printf '  [[http.services.hipoint-api-svc.loadBalancer.servers]]\n'
    printf '    url = "%s"\n\n' "$(toml_escape "$API_BACKEND")"

    printf '# --- 管理前端静态后端 ---\n'
    printf '[http.services.hipoint-admin-svc.loadBalancer]\n'
    printf '  [[http.services.hipoint-admin-svc.loadBalancer.servers]]\n'
    printf '    url = "%s"\n\n' "$(toml_escape "$ADMIN_BACKEND")"

    printf '# --- API：剥离 /api 前缀（对应 nginx rewrite ^/api/(.*)$ /$1，各租户共用）---\n'
    printf '[http.middlewares.hipoint-api-stripprefix.stripprefix]\n'
    printf '  prefix = "/api"\n\n'

    printf '# --- 管理前端：禁用缓存（对应 nginx add_header Cache-Control）---\n'
    printf '[http.middlewares.hipoint-admin-cache.headers]\n'
    printf '  customResponseHeaders = { "Cache-Control" = "no-store, no-cache, must-revalidate" }\n\n'

    printf '# --- 管理前端路由：根路径兜底 ---\n'
    printf '[http.routers.hipoint-admin]\n'
    printf '  rule = "Host(`%s`)"\n' "$MAIN_HOST"
    printf '  entryPoints = ["websecure"]\n'
    printf '  service = "hipoint-admin-svc"\n'
    printf '  middlewares = ["hipoint-admin-cache"]\n'
    printf '  priority = 50\n'
    printf '  [http.routers.hipoint-admin.tls]\n'
    printf '    certResolver = "%s"\n' "$APP_RESOLVER"
    tls_domains_block "http.routers.hipoint-admin"
    printf '\n'

    local h s sub
    for h in "${API_HOSTS[@]}"; do
        s=$(slug "$h"); sub=$(derive_sub "$h")
        printf '# --- API 租户: %s（hd-sub-domain=%s）---\n' "$h" "$sub"
        printf '[http.middlewares.hipoint-api-hdr-%s.headers]\n' "$s"
        printf '  customRequestHeaders = { "hd-sub-domain" = "%s" }\n\n' "$(toml_escape "$sub")"
        printf '[http.routers.hipoint-api-%s]\n' "$s"
        printf '  rule = "Host(`%s`) && PathPrefix(`/api/`)"\n' "$h"
        printf '  entryPoints = ["websecure"]\n'
        printf '  service = "hipoint-api-svc"\n'
        printf '  middlewares = ["hipoint-api-stripprefix", "hipoint-api-hdr-%s"]\n' "$s"
        printf '  priority = 100\n'
        printf '  [http.routers.hipoint-api-%s.tls]\n' "$s"
        printf '    certResolver = "%s"\n' "$APP_RESOLVER"
        tls_domains_block "http.routers.hipoint-api-$s"
        printf '\n'
    done
}


# ---------- 6. 落地：留档副本 + traefik 动态目录（watch 热加载） ----------
DYNAMIC_DIR="${TRAEFIK_HOME}/config"
mkdir -p "$DYNAMIC_DIR" || { printf "❌ 无法创建动态目录 %s\n" "$DYNAMIC_DIR"; exit 1; }

if ! render_toml > "${SERVICE_DIR}/hipoint.toml"; then
    printf "❌ 生成配置失败。\n"; exit 1
fi
cp "${SERVICE_DIR}/hipoint.toml" "${DYNAMIC_DIR}/hipoint.toml" || {
    printf "❌ 写入 %s 失败。\n" "${DYNAMIC_DIR}/hipoint.toml"; exit 1; }
printf "✅ 动态配置已写入: %s（留档: %s/hipoint.toml）\n" "${DYNAMIC_DIR}/hipoint.toml" "$SERVICE_DIR"


# ---------- 7. 收尾提示 ----------
printf -- "----------------------------------------\n"
printf "管理前端: https://%s/\n" "$MAIN_HOST"
printf "API 租户 (%d 个):\n" "${#API_HOSTS[@]}"
for h in "${API_HOSTS[@]}"; do
    printf "  - https://%s/api/  →  %s   (hd-sub-domain=%s)\n" "$h" "$API_BACKEND" "$(derive_sub "$h")"
done
printf "静态后端: %s\n" "$ADMIN_BACKEND"
printf -- "----------------------------------------\n"

# host.docker.internal 依赖 traefik 容器的 host-gateway 映射；已装的 traefik 若缺则须重建
NEEDS_HOSTGW=0
case "${API_BACKEND}${ADMIN_BACKEND}" in *host.docker.internal*) NEEDS_HOSTGW=1 ;; esac
if [ "$NEEDS_HOSTGW" = 1 ] && ! grep -q 'host.docker.internal' "${TRAEFIK_HOME}/docker-compose.yml" 2>/dev/null; then
    printf "⚠️  后端指向宿主机，但当前 traefik 容器未映射 host.docker.internal。\n"
    printf "   请为 %s/docker-compose.yml 补 extra_hosts: [\"host.docker.internal:host-gateway\"]\n" "$TRAEFIK_HOME"
    printf "   再执行: cd %s && docker compose up -d（重建 traefik，会短暂中断走它的站点）\n" "$TRAEFIK_HOME"
elif [ "${RESOLVER_ADDED:-0}" = 1 ]; then
    printf "⚠️  本次新增了 resolver（traefik 静态配置已变更），需重启 traefik 生效：\n"
    printf "   cd %s && docker compose restart\n" "$TRAEFIK_HOME"
else
    printf "ℹ️  配置写入动态目录后由 Traefik watch 自动热加载，无需重启。\n"
fi

echo "✅ $INSTALL_NAME 安装完成！"
