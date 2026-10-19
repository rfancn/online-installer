#!/bin/bash

# ================= app/hipoint/install.sh =================
# hipoint：纯 Traefik 反向代理接入（本应用不起自己的容器）。做两件事：
#   1) 已装 traefik 动态目录生成 hipoint.toml（file provider，watch 热加载）：
#      - 仅处理 xxx.根域名 的请求，xxx 作为 hd-sub-domain；主域名本身不转发
#      - 子域名的根路径 / `/admin` → PC 管理端（剥离第一段）
#      - 子域名的其余请求 → API 服务（剥离第一段）
#      - 微信回调子域名 → 微信回调静态服务（原路径，不剥离，带 hd-sub-domain）
#   2) 生成 PC 管理端与微信回调的 nginx 配置存 $SERVICE_DIR/nginx，软链到 /etc/nginx/conf.d。
# 翻译自原 nginx：Host/X-Forwarded-For 由 Traefik 默认透传不补；X-Real-IP 沿用
# 仓库既有策略省略（应用统一读 XFF）；Cache-Control/SPA 回退由 nginx 提供不重复设。

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

# 从访问域名派生 hd-sub-domain：剥去根域名后缀
derive_sub() {
    local h="$1"
    if [ -n "$SELECTED_ROOT_DOMAIN" ]; then
        printf '%s' "${h%.${SELECTED_ROOT_DOMAIN}}"
    else
        printf '%s' "${h%%.*}"
    fi
}

# 交互读取二级域名（输出到 stdout，提示走 stderr）
# 参数: $1=提示文案 $2=默认值（为空则必须输入，不允许直接回车）
prompt_subdomain() {
    local label="$1" default="$2" d
    while true; do
        if [ -n "$default" ]; then
            printf "%s [%s]: " "$label" "$default" >&2
        else
            printf "%s: " "$label" >&2
        fi
        IFS= read -r d || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        if [ -z "$d" ] && [ -z "$default" ]; then
            printf "❌ 二级域名不能为空，请重新输入。\n" >&2
            continue
        fi
        d="${d:-$default}"
        case "$d" in
            *[\"\'\ \`\$\*\.]*)
                printf "❌ 二级域名不能包含空格、引号、反引号、\$、* 与 .。\n" >&2
                continue ;;
        esac
        printf '%s' "$d"
        return 0
    done
}

# 交互读取监听端口（输出到 stdout，提示走 stderr）
prompt_port() {
    local label="$1" default="$2" p
    while true; do
        printf "%s [%s]: " "$label" "$default" >&2
        IFS= read -r p || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        p="${p:-$default}"
        case "$p" in
            ''|*[!0-9]*) printf "❌ 端口须为数字，请重新输入。\n" >&2; continue ;;
        esac
        [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { printf "❌ 端口须在 1-65535。\n" >&2; continue; }
        printf '%s' "$p"
        return 0
    done
}


# ---------- 1. 服务目录（存放本应用生成结果留档，便于后续手改/卸载） ----------
init_service || exit 1
printf "🚀 开始安装 hipoint（Traefik 反向代理接入）\n"


# ---------- 2. 主域名（根域名）+ 证书签发方式/渠道 ----------
printf "==========================================\n"
printf "🌐 hipoint 主域名（根域名，用于派生子域名与证书，如 example.com）\n"
printf "==========================================\n"
if [ -z "$TRAEFIK_HOME" ] || [ ! -f "$TRAEFIK_HOME/traefik.toml" ]; then
    printf "❌ 尚未安装 traefik（%s 中无 TRAEFIK_HOME 或未找到其配置）。\n" "$INSTALLER_CONF"
    printf "   请先执行: bash run.sh install traefik\n"
    exit 1
fi
choose_cert_source "hipoint" || exit 1
while true; do
    printf "请输入主域名（根域名，如 example.com）: "
    IFS= read -r ROOT_DOMAIN || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    validate_root_domain "$ROOT_DOMAIN" || continue
    break
done
SELECTED_ROOT_DOMAIN="$ROOT_DOMAIN"
APP_RESOLVER_DOMAIN="$ROOT_DOMAIN"

if [ "$CERT_MODE" = auto ]; then
    list_traefik_resolvers || { printf "ℹ️  尚无证书签发渠道，本次将引导新增。\n"; RESOLVER_POOL=(); }
    choose_or_add_resolver "$ROOT_DOMAIN" || exit 1
else
    APP_RESOLVER=""
    CERT_MAIN=""
    CERT_SANS=""
    printf "✅ 使用静态证书：请确认预置证书的 SAN 覆盖各服务域名。\n"
fi

# 根域名登记进全局池，供后续应用匹配
seen_root=""
for rd in $ROOT_DOMAINS; do [ "$rd" = "$ROOT_DOMAIN" ] && seen_root=1; done
[ -n "$seen_root" ] || save_global_root_domains $ROOT_DOMAINS "$ROOT_DOMAIN" || exit 1


# ---------- 3. 服务信息：PC 管理端端口、API 端口、微信回调子域名、租户子域名 ----------
printf "==========================================\n"
printf "🧩 服务配置（主域名: %s）\n" "$ROOT_DOMAIN"
printf "==========================================\n"

# 静态服务默认端口从 8080 起依次递增
STATIC_PORT_BASE=8080

ADMIN_PORT=$(prompt_port "PC管理端端口" "$STATIC_PORT_BASE") || exit 1
WX_SUB=$(prompt_subdomain "微信回调子域名" "") || exit 1
WX_PORT=$(prompt_port "微信回调端口" "$((STATIC_PORT_BASE + 1))") || exit 1
API_PORT=$(prompt_port "API端口" "1000") || exit 1
WX_HOST="${WX_SUB}.${ROOT_DOMAIN}"

# 租户子域名：主域名不承载业务，至少需要一个；可添加多个，每个生成 Host 路由并把子域名写入 hd-sub-domain
TENANT_SUBS=()
printf "==========================================\n"
printf "🧩 租户子域名（至少一个，可添加多个，输入空行结束）\n"
printf "==========================================\n"
while true; do
    if [ ${#TENANT_SUBS[@]} -eq 0 ]; then
        printf "租户子域名（必填）: "
    else
        printf "继续增加租户子域名（回车结束）: "
    fi
    IFS= read -r tsub || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    tsub=$(trim "$tsub")
    if [ -z "$tsub" ]; then
        [ ${#TENANT_SUBS[@]} -eq 0 ] || break
        printf "❌ 至少需要一个租户子域名，请重新输入。\n"
        continue
    fi
    case "$tsub" in
        *[\"\'\ \`\$\*\.]*)
            printf "❌ 二级域名不能包含空格、引号、反引号、\$、* 与 .。\n"
            continue ;;
    esac
    if [ "$tsub" = "$WX_SUB" ]; then
        printf "❌ 不能与微信回调子域名相同（%s）。\n" "$WX_SUB"
        continue
    fi
    dup=0
    for x in "${TENANT_SUBS[@]}"; do [ "$x" = "$tsub" ] && dup=1; done
    if [ "$dup" = 1 ]; then
        printf "ℹ️  %s 已添加，跳过。\n" "$tsub"
    else
        TENANT_SUBS+=("$tsub")
    fi
done

ADMIN_BACKEND="http://host.docker.internal:${ADMIN_PORT}"
WX_BACKEND="http://host.docker.internal:${WX_PORT}"
API_BACKEND="http://host.docker.internal:${API_PORT}"
ADMIN_LOG_PREFIX="admin.${ROOT_DOMAIN}"
WX_LOG_PREFIX="wx.${ROOT_DOMAIN}"
ADMIN_ROOT="/usr/share/nginx/html/admin"
WX_ROOT="/usr/share/nginx/html/wx"

# 租户子域名：根路径/`/admin` → PC 管理端，其余路径剥离第一段 → API + hd-sub-domain
TENANT_HOSTS=()
for tsub in "${TENANT_SUBS[@]}"; do
    TENANT_HOSTS+=("${tsub}.${ROOT_DOMAIN}")
done

printf "ℹ️  主域名 %s 本身不转发业务请求，仅子域名参与路由。\n" "$ROOT_DOMAIN"
printf "✅ PC管理端: https://<租户>.%s/ 或 /admin/ → %s（剥离第一段）\n" "$ROOT_DOMAIN" "$ADMIN_BACKEND"
printf "✅ API 服务: https://<租户>.%s/api/ 及其余路径 → %s（剥离第一段，hd-sub-domain=租户）\n" "$ROOT_DOMAIN" "$API_BACKEND"
printf "✅ 微信回调: https://%s/ → %s（原路径，不剥离，hd-sub-domain=%s）\n" "$WX_HOST" "$WX_BACKEND" "$WX_SUB"
for h in "${TENANT_HOSTS[@]}"; do
    printf "✅ 租户: https://%s/ 或 /admin/ → PC 管理端；其余路径剥离第一段 → API（hd-sub-domain=%s）\n" \
        "$h" "$(derive_sub "$h")"
done


# ---------- 4. 动态配置生成器（逐段 printf 输出到 stdout） ----------
# 仅有通配证书声明时下发 [[...tls.domains]]；留空由 Traefik 按 rule 域名自动签发
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

    printf '# --- API 服务后端 ---\n'
    printf '[http.services.hipoint-api-svc.loadBalancer]\n'
    printf '  [[http.services.hipoint-api-svc.loadBalancer.servers]]\n'
    printf '    url = "%s"\n\n' "$(toml_escape "$API_BACKEND")"

    printf '# --- PC 管理端后端 ---\n'
    printf '[http.services.hipoint-pcadmin-svc.loadBalancer]\n'
    printf '  [[http.services.hipoint-pcadmin-svc.loadBalancer.servers]]\n'
    printf '    url = "%s"\n\n' "$(toml_escape "$ADMIN_BACKEND")"

    printf '# --- 微信回调后端 ---\n'
    printf '[http.services.hipoint-wx-svc.loadBalancer]\n'
    printf '  [[http.services.hipoint-wx-svc.loadBalancer.servers]]\n'
    printf '    url = "%s"\n\n' "$(toml_escape "$WX_BACKEND")"

    printf '# --- 路径前缀剥离：统一剥离 URL 第一段（微信回调子域名除外） ---\n'
    printf '[http.middlewares.hipoint-firstpath-strip.stripPrefixRegex]\n'
    printf '  regex = "^/[^/]+"\n\n'

    # 微信回调子域名：所有路径原样转发 wx 静态服务（不剥离），子域名写入 hd-sub-domain
    local wx_s
    wx_s=$(slug "$WX_HOST")
    printf '# --- 微信回调子域名：原路径 → wx 静态服务（不剥离，hd-sub-domain=%s） ---\n' "$WX_SUB"
    printf '[http.middlewares.hipoint-hdr-%s.headers]\n' "$wx_s"
    printf '  customRequestHeaders = { "hd-sub-domain" = "%s" }\n\n' "$(toml_escape "$WX_SUB")"
    printf '[http.routers.hipoint-callback]\n'
    printf '  rule = "Host(`%s`)"\n' "$WX_HOST"
    printf '  entryPoints = ["websecure"]\n'
    printf '  service = "hipoint-wx-svc"\n'
    printf '  middlewares = ["hipoint-hdr-%s"]\n' "$wx_s"
    printf '  priority = 200\n'
    printf '  [http.routers.hipoint-callback.tls]\n'
    [ -n "$APP_RESOLVER" ] && printf '    certResolver = "%s"\n' "$APP_RESOLVER"
    tls_domains_block "http.routers.hipoint-callback"
    printf '\n'

    # 租户子域名：子域名作为 hd-sub-domain；根路径/`/admin` → PC，其余剥离第一段 → API
    local h s sub
    for h in "${TENANT_HOSTS[@]}"; do
        s=$(slug "$h"); sub=$(derive_sub "$h")
        printf '# --- 租户: %s（hd-sub-domain=%s；根路径/`/admin` → PC；其余剥离第一段 → API）---\n' "$h" "$sub"
        printf '[http.middlewares.hipoint-hdr-%s.headers]\n' "$s"
        printf '  customRequestHeaders = { "hd-sub-domain" = "%s" }\n\n' "$(toml_escape "$sub")"

        printf '[http.routers.hipoint-pcadmin-%s]\n' "$s"
        printf '  rule = "Host(`%s`) && (Path(`/`) || Path(`/admin`) || PathPrefix(`/admin/`))"\n' "$h"
        printf '  entryPoints = ["websecure"]\n'
        printf '  service = "hipoint-pcadmin-svc"\n'
        printf '  middlewares = ["hipoint-firstpath-strip", "hipoint-hdr-%s"]\n' "$s"
        printf '  priority = 200\n'
        printf '  [http.routers.hipoint-pcadmin-%s.tls]\n' "$s"
        [ -n "$APP_RESOLVER" ] && printf '    certResolver = "%s"\n' "$APP_RESOLVER"
        tls_domains_block "http.routers.hipoint-pcadmin-$s"
        printf '\n'

        printf '[http.routers.hipoint-api-%s]\n' "$s"
        printf '  rule = "Host(`%s`)"\n' "$h"
        printf '  entryPoints = ["websecure"]\n'
        printf '  service = "hipoint-api-svc"\n'
        printf '  middlewares = ["hipoint-firstpath-strip", "hipoint-hdr-%s"]\n' "$s"
        printf '  priority = 100\n'
        printf '  [http.routers.hipoint-api-%s.tls]\n' "$s"
        [ -n "$APP_RESOLVER" ] && printf '    certResolver = "%s"\n' "$APP_RESOLVER"
        tls_domains_block "http.routers.hipoint-api-$s"
        printf '\n'
    done
}


# ---------- 5. 落地：留档副本 + traefik 动态目录（watch 热加载） ----------
DYNAMIC_DIR="${TRAEFIK_HOME}/config"
mkdir -p "$DYNAMIC_DIR" || { printf "❌ 无法创建动态目录 %s\n" "$DYNAMIC_DIR"; exit 1; }

if ! render_toml > "${SERVICE_DIR}/hipoint.toml"; then
    printf "❌ 生成配置失败。\n"; exit 1
fi
cp "${SERVICE_DIR}/hipoint.toml" "${DYNAMIC_DIR}/hipoint.toml" || {
    printf "❌ 写入 %s 失败。\n" "${DYNAMIC_DIR}/hipoint.toml"; exit 1; }
printf "✅ 动态配置已写入: %s（留档: %s/hipoint.toml）\n" "${DYNAMIC_DIR}/hipoint.toml" "$SERVICE_DIR"


# ---------- 6. 静态服务 nginx 配置：PC 管理端与微信回调各生成一个 server ----------
# 参数: $1=服务名 $2=监听端口 $3=server_name $4=日志前缀 $5=静态根目录
gen_nginx_conf() {
    local name="$1" port="$2" host="$3" log_prefix="$4" root_dir="$5"
    local src="${SERVICE_DIR}/nginx/hipoint-${name}.conf"
    local link="/etc/nginx/conf.d/hipoint-${name}.conf"
    sed \
        -e "s|__SOURCE__|$(sed_escape "$src")|g" \
        -e "s|__NGINX_PORT__|$(sed_escape "$port")|g" \
        -e "s|__SERVER_NAME__|$(sed_escape "$host")|g" \
        -e "s|__LOG_PREFIX__|$(sed_escape "$log_prefix")|g" \
        -e "s|__ROOT_DIR__|$(sed_escape "$root_dir")|g" \
        "${SCRIPT_PATH}/resource/nginx/admin.conf.tpl" > "$src" \
        || { printf "❌ 生成 nginx 配置失败: %s\n" "$src"; return 1; }
    printf "✅ nginx 配置已生成: %s\n" "$src"
    # ln -sfn 覆盖旧链接；写 /etc/nginx 需提权，经 pkg_exec（sudo/su）
    if pkg_exec ln -sfn "$src" "$link"; then
        printf "✅ 已软链: %s → %s\n" "$link" "$src"
    else
        printf "❌ 软链到 %s 失败，请手动执行: sudo ln -sfn '%s' '%s'\n" "$link" "$src" "$link"
        return 1
    fi
}

command -v nginx >/dev/null 2>&1 || {
    printf "⚠️  未检测到 nginx，正在尝试安装...\n"
    pkg_install nginx
}
if ! command -v nginx >/dev/null 2>&1; then
    printf "❌ nginx 仍不可用，已跳过 nginx 静态配置落地（Traefik 路由已就绪）。\n"
    printf "   装好 nginx 后按模板 %s/resource/nginx/admin.conf.tpl 生成配置：\n" "$SCRIPT_PATH"
    printf "   - PC 管理端: *.%s:%s → %s\n" "$ROOT_DOMAIN" "$ADMIN_PORT" "$ADMIN_ROOT"
    printf "   - 微信回调:  %s:%s → %s\n" "$WX_HOST" "$WX_PORT" "$WX_ROOT"
else
    mkdir -p "${SERVICE_DIR}/nginx"
    gen_nginx_conf pcadmin "$ADMIN_PORT" "*.${ROOT_DOMAIN}" "$ADMIN_LOG_PREFIX" "$ADMIN_ROOT" || exit 1
    gen_nginx_conf wx      "$WX_PORT"    "$WX_HOST"    "$WX_LOG_PREFIX"    "$WX_ROOT"    || exit 1
fi


# ---------- 7. 收尾提示 ----------
printf -- "----------------------------------------\n"
printf "PC 管理端（租户子域名）:\n"
printf "  - https://<租户>.%s/ 或 /admin/  →  %s（剥离第一段，root %s）\n" "$ROOT_DOMAIN" "$ADMIN_BACKEND" "$ADMIN_ROOT"
printf "API 服务（租户子域名）:\n"
printf "  - https://<租户>.%s/api/ 及其余路径  →  %s（剥离第一段）\n" "$ROOT_DOMAIN" "$API_BACKEND"
printf "微信回调:\n"
printf "  - https://%s/  →  %s (root %s，原路径不剥离，hd-sub-domain=%s)\n" "$WX_HOST" "$WX_BACKEND" "$WX_ROOT" "$WX_SUB"
for h in "${TENANT_HOSTS[@]}"; do
    printf "  - https://%s/ 或 /admin/ → PC；其他路径剥离第一段 → API（hd-sub-domain=%s）\n" \
        "$h" "$(derive_sub "$h")"
done
printf -- "----------------------------------------\n"

# host.docker.internal 依赖 traefik 容器的 host-gateway 映射；已装的 traefik 若缺则须重建
NEEDS_HOSTGW=0
case "${API_BACKEND}${ADMIN_BACKEND}${WX_BACKEND}" in *host.docker.internal*) NEEDS_HOSTGW=1 ;; esac
if [ "$NEEDS_HOSTGW" = 1 ] && ! grep -q 'host.docker.internal' "${TRAEFIK_HOME}/docker-compose.yml" 2>/dev/null; then
    printf "⚠️  后端指向宿主机，但当前 traefik 容器未映射 host.docker.internal。\n"
    printf "   请为 %s/docker-compose.yml 补 extra_hosts: [\"host.docker.internal:host-gateway\"]\n" "$TRAEFIK_HOME"
    printf "   再执行: cd %s && docker compose up -d（重建 traefik，会短暂中断走它的站点）\n" "$TRAEFIK_HOME"
elif [ "${RESOLVER_ADDED:-0}" = 1 ]; then
    printf "⚠️  本次新增了证书签发渠道（traefik 静态配置已变更），需重启 traefik 生效：\n"
    printf "   cd %s && docker compose restart\n" "$TRAEFIK_HOME"
else
    printf "ℹ️  配置写入动态目录后由 Traefik watch 自动热加载，无需重启。\n"
fi

# nginx 改了配置需重载才生效；静态目录须自行放入各服务构建产物
if command -v nginx >/dev/null 2>&1 && {
    [ -e /etc/nginx/conf.d/hipoint-pcadmin.conf ] || [ -e /etc/nginx/conf.d/hipoint-wx.conf ]
}; then
    printf -- "----------------------------------------\n"
    printf "🔁 静态服务配置需重载 nginx 生效：\n"
    printf "   sudo nginx -t && sudo systemctl reload nginx   （或 sudo nginx -s reload）\n"
    printf "   静态目录 %s、%s 请确认已放入对应构建产物。\n" "$ADMIN_ROOT" "$WX_ROOT"
fi

echo "✅ $INSTALL_NAME 安装完成！"