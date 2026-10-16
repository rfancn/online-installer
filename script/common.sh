#!/bin/sh
# ================= script/common.sh =================

# 定义全局共享网络名称
TRAEFIK_NETWORK="web"

# 本库位于 <项目根>/script/ 下，据此定位配置文件（被 source 时用 BASH_SOURCE 取自身路径）
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"
INSTALLER_CONF="${PROJECT_ROOT}/.installer.conf"

# 交互式读取封装：EOF（输入耗尽/Ctrl+D）时立即失败返回，
# 供各校验循环使用 `ask VAR "提示" || return 1`，避免读空导致死循环
ask() {
    local __var="$1" __prompt="${2:-}"
    [ -n "$__prompt" ] && printf '%s' "$__prompt"
    if ! IFS= read -r "$__var"; then
        printf '\n❌ 输入已结束（EOF），已中止。\n' >&2
        return 1
    fi
}

# 0. 解析服务根目录：首次运行交互确认并写入 .installer.conf，后续自动复用
resolve_service_base() {
    # 已有记录则直接复用，不再询问
    if [ -f "$INSTALLER_CONF" ]; then
        . "$INSTALLER_CONF"
        if [ -n "$SERVICE_BASE" ]; then
            printf "✅ 使用已记录的服务根目录: %s\n" "$SERVICE_BASE"
            return 0
        fi
    fi

    # 首次运行：交互输入，默认当前 home 下的 service 目录
    default_base="${HOME:-/root}/service"
    while true; do
        printf "请输入服务根目录 [%s]: " "$default_base"
        read -r input_base || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        input_base=${input_base:-$default_base}

        case "$input_base" in
            /*) break ;;
            *)  printf "❌ 服务根目录必须是以 / 开头的绝对路径，请重新输入。\n" ;;
        esac
    done

    # 提前验证可创建，避免装完才发现权限问题
    if ! mkdir -p "$input_base" 2>/dev/null; then
        printf "❌ 无法创建服务根目录 '%s'，请检查权限后重试。\n" "$input_base"
        return 1
    fi

    # 写入配置文件，供后续运行复用
    {
        printf "# online-installer 服务根目录配置（首次运行 install.sh 时生成）\n"
        printf "# 修改或删除本文件可重新指定服务根目录\n"
        printf "SERVICE_BASE=%s\n" "$input_base"
    } > "$INSTALLER_CONF" || {
        printf "❌ 无法写入配置文件 '%s'。\n" "$INSTALLER_CONF"
        return 1
    }

    SERVICE_BASE="$input_base"
    printf "✅ 服务根目录已记录到 %s，后续运行将自动复用。\n" "$INSTALLER_CONF"
    return 0
}

# 0.5 检测包管理器（load_common 初始化时确定）：
#     PKG_MANAGER = apt|dnf|yum|apk|zypper|pacman，未识别时为空
#     PKG_ELEV    = 提权方式，留待首次 pkg_exec 时探测（sudo → su 管理员账户回退）
#     PKG_SU_ADMIN = su 模式下使用的管理员账户（探测时交互指定，回车默认 root）
detect_pkg_manager() {
    PKG_ELEV=""
    PKG_SU_ADMIN=""

    if command -v apt-get >/dev/null 2>&1; then   PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then     PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then     PKG_MANAGER="yum"
    elif command -v apk >/dev/null 2>&1; then     PKG_MANAGER="apk"
    elif command -v zypper >/dev/null 2>&1; then  PKG_MANAGER="zypper"
    elif command -v pacman >/dev/null 2>&1; then  PKG_MANAGER="pacman"
    else                                          PKG_MANAGER=""
    fi
}

# 1. 加载公共库的快捷函数
load_common() {
    # 使用标准的 $0 获取脚本路径
    SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

    # 自动获取上级目录名作为默认安装名
    INSTALL_NAME=$(basename "$(cd "$SCRIPT_DIR" && pwd)")

    # 检测本机包管理器，供后续依赖安装使用
    detect_pkg_manager

    # 确定服务根目录（首次交互指定，之后从配置文件复用）
    resolve_service_base || return 1

    # 在加载公共库时，自动调用网络初始化函数
    init_docker_network || return 1
}


# 1. 初始化 Docker 全局网络的函数
init_docker_network() {
    # 先确认 docker 命令存在，避免把"未安装"误报成"网络创建失败"
    if ! command -v docker >/dev/null 2>&1; then
        printf "❌ 未找到 docker 命令，请先在本机安装 Docker。\n"
        return 1
    fi

    # 用 inspect 检查网络是否存在；失败原因需区分：
    # "网络不存在"（正常，继续创建）/"连不上 daemon"/"无 socket 权限"（均应直接报错退出）
    if inspect_err=$(docker network inspect "$TRAEFIK_NETWORK" 2>&1); then
        printf "✅ 检测到 Docker 网络 '%s' 已存在。\n" "$TRAEFIK_NETWORK"
        return 0
    fi
    case "$inspect_err" in
        *"Cannot connect to the Docker daemon"*)
            printf "❌ 无法连接 Docker 守护进程，请先启动服务（systemctl start docker）：\n%s\n" "$inspect_err"
            return 1
            ;;
        *"permission denied"*)
            printf "❌ 无权访问 Docker socket，请将用户加入 docker 组或改用 sudo：\n%s\n" "$inspect_err"
            return 1
            ;;
    esac

    # 走到这里说明 daemon 可达、仅网络不存在，执行创建并保留真实报错
    printf "⚠️  未检测到 Docker 网络 '%s'，正在自动创建...\n" "$TRAEFIK_NETWORK"
    if create_err=$(docker network create "$TRAEFIK_NETWORK" 2>&1); then
        printf "✅ 网络 '%s' 创建成功！\n" "$TRAEFIK_NETWORK"
        return 0
    else
        printf "❌ 网络 '%s' 创建失败，Docker 返回：\n%s\n" "$TRAEFIK_NETWORK" "$create_err"
        return 1
    fi
}

# 1.5 放行防火墙端口：按存在的工具自动适配
#     ufw（Debian/Ubuntu）/ firewall-cmd（RHEL/Rocky/Fedora 的 firewalld）
#     两者都无则跳过并提示（可能无防火墙，或安全组在云平台层需自行放行）
open_firewall_ports() {
    local port fw_args=""
    if command -v ufw >/dev/null 2>&1; then
        for port in "$@"; do
            pkg_exec ufw allow "$port" || printf "⚠️  ufw 放行 '%s' 失败，请手动处理。\n" "$port"
        done
    elif command -v firewall-cmd >/dev/null 2>&1; then
        # firewalld 守护进程未运行时，主机层本就不拦流量，直接跳过；
        # 不主动 start firewalld——启用防火墙可能当场中断既有连接，留给用户决定
        if ! firewall-cmd --state >/dev/null 2>&1; then
            printf "ℹ️  firewalld 服务未运行，无主机防火墙拦截，跳过端口放行（云主机请确认安全组）。\n"
            return 0
        fi

        for port in "$@"; do
            fw_args="$fw_args --add-port=$port"
        done
        # shellcheck disable=SC2086  # fw_args 为固定的 --add-port= 参数序列，需按空格拆分
        pkg_exec firewall-cmd --permanent $fw_args && pkg_exec firewall-cmd --reload ||
            printf "⚠️  firewalld 放行 '%s' 失败，请手动处理。\n" "$*"
    else
        printf "⚠️  未检测到 ufw/firewalld，跳过防火墙配置；若有其他防火墙或云平台安全组，请自行放行 %s。\n" "$*"
    fi
}

# 2. 初始化服务目录的函数（支持用户确认或自定义服务名）
init_service() {
    current_name="$INSTALL_NAME"

    while true; do
        current_dir="${SERVICE_BASE}/${current_name}"

        printf "==========================================\n"
        printf "🔧 准备初始化服务: %s\n" "$current_name"
        printf "📂 目标服务目录: %s\n" "$current_dir"
        printf "==========================================\n"

        # 提示用户确认
        printf "请确认以上服务目录是否正确？(y/n) [y]: "
        read -r confirm || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        confirm=${confirm:-y}  # 默认值为 y

        # 判断用户输入
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            # 1. 用户确认，导出最终变量并跳出循环
            SERVICE_NAME="$current_name"
            SERVICE_DIR="$current_dir"
            export SERVICE_NAME SERVICE_DIR
            break
            
        elif [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
            # 2. 用户拒绝，提示输入自定义服务名
            printf "请输入自定义的服务名称: "
            read -r custom_name || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            
            # 防止用户直接回车输入空值
            if [ -n "$custom_name" ]; then
                current_name="$custom_name"
                printf "\n⚠️  已切换服务名为: %s\n\n" "$current_name"
            else
                printf "\n⚠️  输入不能为空，请重新确认。\n\n"
            fi
            
        else
            # 3. 输入了其他无效字符，提示错误并重新循环
            printf "\n❌ 无效输入 '%s'，请输入 y 或 n。\n\n" "$confirm"
        fi
    done

    # 4. 核心防御检查：如果目标目录已经存在，则报错并中断
    if [ -d "$SERVICE_DIR" ]; then
        printf "❌ 致命错误: 目标目录 '%s' 已经存在！\n" "$SERVICE_DIR"
        printf "请删除该目录或更换服务名称后重试。\n"
        return 1
    fi

    # 5. 检查通过，执行创建目录操作
    mkdir -p "$SERVICE_DIR" || { printf "❌ 目录创建失败，请检查权限！\n"; return 1; }

    printf "✅ 服务目录准备就绪: %s\n" "$SERVICE_DIR"
    return 0
}

# 3. 转义 sed 替换内容中的特殊字符（\ & 以及分隔符 |）
# 用法: sed -i "s|__PLACEHOLDER__|$(sed_escape "$VALUE")|g" 文件
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# 3.5 ACME resolver 池与域名的全局管理（纯 DNS-01）：
#     resolver 命名 = <根域名>@<提供商别名>，如 sysummit.com@aliyun；
#     静态段存于 traefik.toml（TOML 引号键），根域名池存 .installer.conf

# lego 提供商标识 → 别名（用于 resolver 命名，贴近用户习惯）
resolver_alias() {
    case "$1" in
        alidns)         printf 'aliyun' ;;
        tencentcloud)   printf 'tencentcloud' ;;
        cloudflare)     printf 'cloudflare' ;;
        *)              printf '%s' "$1" ;;
    esac
}

# resolver 名 = 根域名@提供商别名
resolver_name() {
    printf '%s@%s' "$1" "$(resolver_alias "$2")"
}

# 向 .installer.conf 更新单个键值（不存在则追加，存在则替换，杜绝重复键）
set_installer_key() {
    local key="$1" value="$2" tmp="${INSTALLER_CONF}.tmp"
    {
        grep -v "^${key}=" "$INSTALLER_CONF" 2>/dev/null || true
        printf '%s="%s"\n' "$key" "$value"
    } > "$tmp" || { printf "❌ 无法写入 %s\n" "$INSTALLER_CONF"; return 1; }
    mv "$tmp" "$INSTALLER_CONF" || return 1
}

# 保存根域名池（并清理旧单值 ROOT_DOMAIN 键完成迁移）
# 用法: save_global_root_domains a.com b.com
save_global_root_domains() {
    [ $# -ge 1 ] || { printf "❌ 内部错误: 根域名列表为空，无法保存。\n"; return 1; }
    local tmp="${INSTALLER_CONF}.tmp"
    {
        grep -v -e '^ROOT_DOMAINS=' -e '^ROOT_DOMAIN=' "$INSTALLER_CONF" 2>/dev/null || true
        printf 'ROOT_DOMAINS="%s"\n' "$*"
    } > "$tmp" || { printf "❌ 无法写入 %s\n" "$INSTALLER_CONF"; return 1; }
    mv "$tmp" "$INSTALLER_CONF" || return 1
}

# 校验根域名格式（非空、无空格引号 $ * 等），供各收集流程复用
# 错误提示走 stderr：该函数可能被 $(...) 捕获上下文的循环调用
validate_root_domain() {
    case "$1" in
        ''|*[\"\'\ \`\$\*]*)
            printf "❌ 域名不能为空，且不能包含空格、引号、反引号、\$ 与 *。\n" >&2
            return 1 ;;
    esac
    return 0
}

# 从 traefik 静态配置解析 resolver 池: RESOLVER_POOL=("名字|lego提供商" ...)
# 段名格式: [certificatesResolvers."<root>@<alias>".acme]（含引号键）
list_traefik_resolvers() {
    RESOLVER_POOL=()
    local static r p line
    { [ -n "$TRAEFIK_HOME" ] && [ -f "$TRAEFIK_HOME/traefik.toml" ]; } || return 1
    static="$TRAEFIK_HOME/traefik.toml"
    while IFS= read -r line; do
        case "$line" in
            \[certificatesResolvers.*.acme\]) ;;
            *) continue ;;
        esac
        r=$(printf '%s' "$line" | sed 's/^\[certificatesResolvers\.//; s/\.acme\]$//; s/^"//; s/"$//')
        # 从对应 dnsChallenge 子段提取 lego 提供商标识
        # （子段带缩进，先剥前导空白再精确比较；awk 串比较避免正则特殊字符）
        p=$(awk -v want="[certificatesResolvers.\"${r}\".acme.dnsChallenge]" '
            { t = $0; sub(/^[ \t]+/, "", t) }
            t == want { f = 1; next }
            f && t ~ /^\[/ { exit }
            f && t ~ /provider = / { match(t, /"[^"]*"/); print substr(t, RSTART + 1, RLENGTH - 2); exit }
        ' "$static")
        RESOLVER_POOL+=("${r}|${p:-unknown}")
    done < "$static"
    [ ${#RESOLVER_POOL[@]} -gt 0 ]
}

# 收集/沿用 ACME 邮箱与 CA 环境（traefik.toml 已有则沿用，
# .installer.conf 已存则复用，都没有才交互询问；供 traefik 安装与应用新增 resolver 共用）
collect_acme_meta() {
    if [ -n "$TRAEFIK_HOME" ] && [ -f "$TRAEFIK_HOME/traefik.toml" ]; then
        local e c
        e=$(grep -m1 'email = ' "$TRAEFIK_HOME/traefik.toml" | sed 's/.*= *"\(.*\)".*/\1/')
        c=$(grep -m1 'caServer = ' "$TRAEFIK_HOME/traefik.toml" | sed 's/.*= *"\(.*\)".*/\1/')
        if [ -n "$e" ] && [ -n "$c" ]; then
            ACME_EMAIL="$e"; ACME_CA_SERVER="$c"
            return 0
        fi
    fi
    [ -n "$ACME_EMAIL" ] && [ -n "$ACME_CA_SERVER" ] && return 0

    printf "==========================================\n"
    printf "📧 请配置证书通知邮箱与 Let's Encrypt 环境\n"
    printf "==========================================\n"
    while true; do
        printf "请输入邮箱: "
        read -r ACME_EMAIL || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        case "$ACME_EMAIL" in
            '')     printf "❌ 邮箱不能为空。\n"; continue ;;
            *[\"\'\ \`\$]*) printf "❌ 邮箱不能包含空格、引号、反引号与 \$。\n"; continue ;;
            *@*)    break ;;
            *)      printf "❌ 邮箱格式不正确（缺少 @）。\n"; continue ;;
        esac
    done
    printf "  1) 生产  (正式证书，浏览器信任，有速率限制)\n"
    printf "  2) 测试  (staging，不受速率限制，浏览器不信任)\n"
    printf "请选择 Let's Encrypt 环境 (1/2) [1]: "
    read -r ca_choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    case "$ca_choice" in
        2) ACME_CA_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
           printf "⚠️  已选择测试环境：证书不被浏览器信任，仅用于验证流程。\n" ;;
        *) ACME_CA_SERVER="https://acme-v02.api.letsencrypt.org/directory" ;;
    esac
    # 落盘全局，供后续 traefik/应用新增 resolver 复用
    set_installer_key ACME_EMAIL "$ACME_EMAIL" || return 1
    set_installer_key ACME_CA_SERVER "$ACME_CA_SERVER" || return 1
    return 0
}

# 新增一个 resolver 到 traefik 静态配置（section + 独立 storage + traefik .env 凭据组）
# 参数: $1 = 根域名；依赖 DNS_PROVIDER、DNS_ENV_NAMES/VALUES、ACME_EMAIL/ACME_CA_SERVER、TRAEFIK_HOME
create_resolver() {
    local root="$1" name
    name=$(resolver_name "$root" "$DNS_PROVIDER")
    local static="${TRAEFIK_HOME}/traefik.toml"
    local envf="${TRAEFIK_HOME}/.env"
    local ldir="${TRAEFIK_HOME}/letsencrypt"

    # 同名 resolver（同根域名+同提供商）已存在则拒绝（防重复定义）
    if grep -qF "[certificatesResolvers.\"${name}\".acme]" "$static" 2>/dev/null; then
        printf "❌ resolver %s 已存在，请直接选用。\n" "$name"
        return 1
    fi

    mkdir -p "$ldir"
    cat >> "$static" <<EOF

[certificatesResolvers."${name}".acme]
  email = "${ACME_EMAIL}"
  storage = "/letsencrypt/acme-${name}.json"       # 证书存储（每 resolver 独立文件，禁止共用）
  caServer = "${ACME_CA_SERVER}"                    # 生产或 staging 的 ACME 目录地址
  keyType = "EC256"                                 # EC256 比默认 RSA4096 更小、握手更快

  # 泛域名证书只能 DNS-01 验证，凭据经 .env 注入（见各厂商环境变量）
  [certificatesResolvers."${name}".acme.dnsChallenge]
    provider = "${DNS_PROVIDER}"
    delayBeforeCheck = 30                           # 等 DNS 记录传播，传播慢可适当调大
    resolvers = ["223.5.5.5:53", "1.1.1.1:53"]
EOF

    touch "${ldir}/acme-${name}.json"
    chmod 600 "${ldir}/acme-${name}.json"

    {
        printf '\n# %s DNS 凭据（resolver: %s）\n' "$DNS_PROVIDER" "$name"
        local i
        for i in "${!DNS_ENV_NAMES[@]}"; do
            printf '%s=%s\n' "${DNS_ENV_NAMES[$i]}" "${DNS_ENV_VALUES[$i]}"
        done
    } >> "$envf"
    chmod 600 "$envf" 2>/dev/null

    APP_RESOLVER="$name"
    return 0
}

# 新增 resolver 交互流程（traefik 的 add-resolver 子命令与应用内引导共用）
# 参数: $1 = 可选根域名（应用通配模式已知时传入；为空则询问）
# 结果: APP_RESOLVER；实际写入时 RESOLVER_ADDED=1，命中既有则 0
add_dns_resolver() {
    local root="${1:-}" name entry
    if [ -z "$root" ]; then
        printf "请输入该 resolver 关联的根域名（如 sysummit.com）: "
        read -r root || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        validate_root_domain "$root" || return 1
    fi
    choose_dns_provider || return 1
    name=$(resolver_name "$root" "$DNS_PROVIDER")

    list_traefik_resolvers 2>/dev/null || true
    for entry in "${RESOLVER_POOL[@]}"; do
        if [ "${entry%%|*}" = "$name" ]; then
            printf "ℹ️  resolver %s 已存在，直接复用（无需重启）。\n" "$name"
            APP_RESOLVER="$name"
            RESOLVER_ADDED=0
            return 0
        fi
    done

    collect_dns_credentials || return 1
    collect_acme_meta || return 1
    create_resolver "$root" || return 1
    RESOLVER_ADDED=1
    printf "✅ 已新增 resolver %s（根域名 %s，provider: %s）\n" "$APP_RESOLVER" "$root" "$DNS_PROVIDER"
    return 0
}

# 选择证书 resolver：列出既有池 + 末尾「新增 resolver」
# 参数: $1 = 通配模式的根域名（只列出 <该根域名>@* 的 resolver，并以其为新增默认）；
#       为空 = 精确域名模式，列出全部（须自行确认所选提供商托管该域名 NS）
# 结果: APP_RESOLVER；实际新增成功时 RESOLVER_ADDED=1（调用方据此提示重启 traefik）
choose_or_add_resolver() {
    local wr="${1:-}"
    printf "==========================================\n"
    if [ -n "$wr" ]; then
        printf "🔐 为根域名 %s 选择证书 resolver（命名: 根域名@提供商）\n" "$wr"
    else
        printf "🔐 请选择证书签发 resolver（须托管该域名 DNS 的提供商）\n"
    fi
    printf "==========================================\n"
    local i choice entry shown=0
    while true; do
        i=1
        shown=0
        for entry in "${RESOLVER_POOL[@]}"; do
            # 通配模式只显示根域名匹配的 resolver
            # [[ ]] 才支持右侧模式匹配；[ ] 的 != 是字面比较
            if [ -n "$wr" ] && [[ "${entry%%|*}" != "${wr}@"* ]]; then
                continue
            fi
            printf "  %d) %s（provider: %s）\n" "$i" "${entry%%|*}" "${entry##*|}"
            i=$((i + 1))
            shown=$((shown + 1))
        done
        if [ -n "$wr" ]; then
            printf "  %d) 新增 resolver %s@<提供商>\n" "$i" "$wr"
        else
            printf "  %d) 新增 resolver（输入根域名与提供商）\n" "$i"
        fi
        printf "请输入序号 (1-%d) [1]: " "$i"
        read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        [ -n "$choice" ] || choice=1
        case "$choice" in
            *[!0-9]*) printf "❌ 无效输入，请输入数字序号。\n"; continue ;;
        esac
        if [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
            # 定位第 choice 个「已显示」条目（与过滤逻辑一致地重新数一遍）
            local n=0
            for entry in "${RESOLVER_POOL[@]}"; do
                # [[ ]] 才支持右侧模式匹配；[ ] 的 != 是字面比较
            if [ -n "$wr" ] && [[ "${entry%%|*}" != "${wr}@"* ]]; then
                    continue
                fi
                n=$((n + 1))
                if [ "$n" -eq "$choice" ]; then
                    APP_RESOLVER="${entry%%|*}"
                    RESOLVER_ADDED=0
                    printf "✅ 使用 resolver: %s\n" "$APP_RESOLVER"
                    return 0
                fi
            done
        fi
        [ "$choice" -eq "$i" ] || { printf "❌ 超出范围。\n"; continue; }

        # 新增分支：共用 add_dns_resolver（通配模式已带根域名）
        add_dns_resolver "$wr" || return 1
        # 刷新池供可能的再次选择
        list_traefik_resolvers 2>/dev/null || true
        return 0
    done
}

# 选择应用访问域名：根域名池组合（通配）或精确域名直填
# 结果: APP_HOST / CERT_MAIN / CERT_SANS（通配=*.root+root；精确=空+空，
#       由 Traefik 对 router rule 中的域名自动签发单域名证书）
choose_app_domain() {
    local pool=() d mode label again
    # shellcheck disable=SC2206
    [ -n "$ROOT_DOMAINS" ] && pool=($ROOT_DOMAINS)

    printf "==========================================\n"
    printf "🌐 请配置应用访问域名\n"
    printf "==========================================\n"
    printf "  1) 使用根域名组合二级域名（通配证书 *.根域名，多应用共享）\n"
    printf "  2) 直接输入应用完整域名（单域名证书，Traefik 自动签发）\n"

    while true; do
        printf "请选择方式 (1/2) [1]: "
        read -r mode || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        case "${mode:-1}" in
            1)
                # 根域名选择/新增
                local root=""
                if [ ${#pool[@]} -eq 0 ]; then
                    printf "根域名池为空，请先输入根域名:\n"
                    root=$(prompt_new_root_domain) || return 1
                    pool+=("$root")
                else
                    local idx=1 choice
                    while true; do
                        printf "已有根域名:\n"
                        for d in "${pool[@]}"; do printf "  %d) %s\n" "$idx" "$d"; idx=$((idx+1)); done
                        printf "  %d) 新增根域名\n" "$idx"
                        printf "请选择 (1-%d) [1]: " "$idx"
                        read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
                        [ -n "$choice" ] || choice=1
                        case "$choice" in
                            *[!0-9]*) printf "❌ 无效输入，请输入数字序号。\n"; continue ;;
                        esac
                        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#pool[@]}" ]; then
                            root="${pool[$((choice - 1))]}"; break
                        fi
                        [ "$choice" -eq "$idx" ] || { printf "❌ 超出范围。\n"; continue; }
                        root=$(prompt_new_root_domain) || return 1
                        pool+=("$root")
                        break
                    done
                fi
                while true; do
                    printf "请输入二级域名（完整访问域名为 <二级域名>.%s）[%s]: " "$root" "$SERVICE_NAME"
                    read -r label || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
                    # 空输入放行走 ${label:-服务名} 默认；仅拒绝含非法字符
                    case "$label" in
                        *[\"\'\ \`\$\*]*)
                            printf "❌ 二级域名不能包含空格、引号、反引号、\$ 与 *（用默认请直接回车）。\n"
                            continue ;;
                    esac
                    APP_HOST="${label:-$SERVICE_NAME}.${root}"
                    printf "请确认访问域名: https://%s (y/n) [y]: " "$APP_HOST"
                    read -r confirm || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
                    case "${confirm:-y}" in
                        y|Y) break ;;
                        n|N) continue ;;
                        *) printf "❌ 无效输入 '%s'，请输入 y 或 n。\n" "$confirm" ;;
                    esac
                done
                CERT_MAIN="*.${root}"
                CERT_SANS="$root"
                SELECTED_ROOT_DOMAIN="$root"
                save_global_root_domains "${pool[@]}" || return 1
                return 0
                ;;
            2)
                local exact
                printf "请输入应用完整域名（如 files.example.cn，将自动签发单域名证书）: "
                read -r exact || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
                validate_root_domain "$exact" || continue
                APP_HOST="$exact"
                CERT_MAIN=""
                CERT_SANS=""
                SELECTED_ROOT_DOMAIN=""
                return 0
                ;;
            *) printf "❌ 无效输入 '%s'，请输入 1 或 2。\n" "$mode" ;;
        esac
    done
}

# 新增根域名输入（校验+回显），域名输出到 stdout，提示输出到 stderr
prompt_new_root_domain() {
    local d
    while true; do
        printf "请输入根域名（如 example.com，其 DNS 需托管在即将选择的提供商下）: " >&2
        read -r d || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        validate_root_domain "$d" || continue
        printf '%s' "$d"
        return 0
    done
}

# 应用证书信息总入口：确认 traefik 已安装 → 先定域名形态（通配/精确）
# → 从 DNS resolver 池选择或引导新增（池为空直接进入新增）
# 结果: APP_HOST / CERT_MAIN / CERT_SANS / APP_RESOLVER / RESOLVER_ADDED
setup_app_certificate() {
    if [ -z "$TRAEFIK_HOME" ] || [ ! -f "$TRAEFIK_HOME/traefik.toml" ]; then
        printf "❌ 尚未安装 traefik（%s 中无 TRAEFIK_HOME 或未找到其配置）。\n" "$INSTALLER_CONF"
        printf "   请先执行: bash run.sh install traefik\n"
        return 1
    fi
    list_traefik_resolvers || { printf "ℹ️  traefik resolver 池为空，本次将引导新增 DNS resolver。\n"; RESOLVER_POOL=(); }

    choose_app_domain || return 1
    # 通配模式按根域名过滤 resolver 并以其为新增默认；精确模式传空列出全部
    choose_or_add_resolver "$SELECTED_ROOT_DOMAIN" || return 1
    return 0
}

# 3.6 选择 DNS 服务商（泛域名 DNS-01 验证用；与凭据收集分离，
#     便于「提供商已有 resolver」时只选提供商、不再重复索要凭据）
# 结果: DNS_PROVIDER
choose_dns_provider() {
    printf "==========================================\n"
    printf "☁️  请选择 DNS 服务商\n"
    printf "==========================================\n"
    printf "  1) 阿里云 AliDNS     (alidns)\n"
    printf "  2) 腾讯云 DNSPod     (tencentcloud)\n"
    printf "  3) Cloudflare        (cloudflare)\n"
    printf "请输入序号 (1/2/3) [1]: "
    read -r dns_choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }

    DNS_PROVIDER=""
    case "${dns_choice:-1}" in
        1) DNS_PROVIDER="alidns" ;;
        2) DNS_PROVIDER="tencentcloud" ;;
        3) DNS_PROVIDER="cloudflare" ;;
        *) printf "❌ 无效输入 '%s'，仅支持 1/2/3。\n" "$dns_choice"; return 1 ;;
    esac
    return 0
}

# 3.7 按已选 DNS_PROVIDER 收集 API 凭据
# 结果: DNS_ENV_NAMES[]（变量名）、DNS_ENV_VALUES[]（变量值），均经合法性校验
collect_dns_credentials() {
    DNS_ENV_NAMES=()
    DNS_ENV_VALUES=()
    local key_id key_secret api_token
    case "$DNS_PROVIDER" in
        alidns)
            printf "\n请输入阿里云 AccessKey ID: "
            read -r key_id || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            printf "请输入阿里云 AccessKey Secret (输入时不可见): "
            stty -echo 2>/dev/null
            read -r key_secret || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            stty echo 2>/dev/null
            printf "\n"
            DNS_ENV_NAMES=("ALICLOUD_ACCESS_KEY" "ALICLOUD_SECRET_KEY")
            DNS_ENV_VALUES=("$key_id" "$key_secret")
            ;;
        tencentcloud)
            printf "\n请输入腾讯云 SecretId: "
            read -r key_id || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            printf "请输入腾讯云 SecretKey (输入时不可见): "
            stty -echo 2>/dev/null
            read -r key_secret || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            stty echo 2>/dev/null
            printf "\n"
            DNS_ENV_NAMES=("TENCENTCLOUD_SECRET_ID" "TENCENTCLOUD_SECRET_KEY")
            DNS_ENV_VALUES=("$key_id" "$key_secret")
            ;;
        cloudflare)
            printf "\n请输入 Cloudflare API Token (需 Zone:DNS 编辑权限，输入时不可见): "
            stty -echo 2>/dev/null
            read -r api_token || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            stty echo 2>/dev/null
            printf "\n"
            DNS_ENV_NAMES=("CF_DNS_API_TOKEN")
            DNS_ENV_VALUES=("$api_token")
            ;;
        *)
            printf "❌ 内部错误: 未知 DNS 提供商 '%s'。\n" "$DNS_PROVIDER"
            return 1
            ;;
    esac

    # 凭据只经 .env 传给容器，内容出现空格或引号会破坏 .env 解析
    local value
    for value in "${DNS_ENV_VALUES[@]}"; do
        case "$value" in
            ''|*[\"\'\ \`\$]*)
                printf "❌ API 凭据不能为空，且不能包含空格、引号、反引号与 \$。\n"
                return 1
                ;;
        esac
    done
    return 0
}

# 4. 提权执行：先尝试 sudo（不在 sudoers 时 sudo 自身会提示输入当前用户凭证，
#    认证失败/无 sudo 时进入回退）→ su 交互式选择管理员账户（默认 root，
#    root 锁定时可输入其他管理员账户）→ 均不可用则明确报错。
#    方式在首次调用时探测并缓存到 PKG_ELEV，避免多条命令重复认证
pkg_exec() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return $?
    fi

    if [ -z "$PKG_ELEV" ]; then
        if command -v sudo >/dev/null 2>&1 && sudo -v; then
            PKG_ELEV="sudo"
        elif command -v su >/dev/null 2>&1; then
            printf "🔑 sudo 不可用（未安装、不在 sudoers 或认证失败），改用 su 提权\n"
            # 交互式指定系统管理员账户（回车默认 root；root 锁定时可输入其他管理员账户）
            # 在探测阶段读一次并缓存，避免 apt update+install 链重复询问
            printf "请输入系统管理员账户名（用于安装软件包提权，非应用账号） [root]: "
            read -r PKG_SU_ADMIN || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            PKG_SU_ADMIN=${PKG_SU_ADMIN:-root}
            PKG_ELEV="su"
        else
            PKG_ELEV="none"
        fi
    fi

    case "$PKG_ELEV" in
        sudo) sudo "$@" ;;
        su)   su "$PKG_SU_ADMIN" -c "$*" ;;
        *)
            printf "❌ 本机没有可用的提权途径（sudo 与 su 均不可用），请以 root 身份手动执行: %s\n" "$*"
            return 1
            ;;
    esac
}

# 5. 通用软件包安装原语（依赖 load_common 检测出的 PKG_MANAGER，经 pkg_exec 提权）
#    用法: pkg_install <包名>
pkg_install() {
    if [ -z "$PKG_MANAGER" ]; then
        printf "❌ 未识别的包管理器，无法自动安装 '%s'。\n" "$1"
        return 1
    fi

    case "$PKG_MANAGER" in
        apt)    pkg_exec apt-get update && pkg_exec apt-get install -y "$1" ;;
        dnf)    pkg_exec dnf install -y "$1" ;;
        yum)    pkg_exec yum install -y "$1" ;;
        apk)    pkg_exec apk add --no-cache "$1" ;;
        zypper) pkg_exec zypper --non-interactive install "$1" ;;
        pacman) pkg_exec pacman -Sy --noconfirm "$1" ;;
    esac
}

# 6. 确保 htpasswd 可用：缺失时按发行版映射包名后调用 pkg_install，
#    安装后复检；返回非 0 表示仍不可用，调用方须中止
ensure_htpasswd() {
    command -v htpasswd >/dev/null 2>&1 && return 0

    local pkg
    case "$PKG_MANAGER" in
        apt|apk|zypper) pkg="apache2-utils" ;;  # Debian/Ubuntu、Alpine、openSUSE
        dnf|yum)        pkg="httpd-tools" ;;    # Fedora/RHEL/Rocky/Alma、旧 CentOS
        pacman)         pkg="apache2" ;;        # Arch
        *)              pkg="" ;;
    esac
    if [ -z "$pkg" ]; then
        printf "❌ 未识别的包管理器，无法自动安装 htpasswd，请手动安装。\n"
        return 1
    fi

    printf "⚠️  未检测到 htpasswd，正在通过 %s 安装 %s...\n" "$PKG_MANAGER" "$pkg"
    pkg_install "$pkg" && command -v htpasswd >/dev/null 2>&1
}
