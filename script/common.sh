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

# 读取必填输入，结果写入指定变量
read_required() {
    local prompt="$1" var_name="$2" value
    while true; do
        printf "%s" "$prompt" >&2
        read -r value || { printf "\n❌ 输入已结束，已中止。\n" >&2; return 1; }
        [ -n "$value" ] && break
        printf "❌ 该项不能为空，请重新输入。\n" >&2
    done
    printf -v "$var_name" '%s' "$value"
}

# 读取带默认值的输入（回车使用默认值），结果写入指定变量
read_default() {
    local prompt="$1" default="$2" var_name="$3" value
    while true; do
        printf "%s [%s]: " "$prompt" "$default"
        read -r value || { printf "\n❌ 输入已结束，已中止。\n" >&2; return 1; }
        value="${value:-$default}"
        [ -n "$value" ] && break
        printf "❌ 该项不能为空，请重新输入。\n" >&2
    done
    printf -v "$var_name" '%s' "$value"
}

# 读取敏感输入（不回显），结果写入指定变量
read_secret() {
    local prompt="$1" var_name="$2" value
    while true; do
        printf "%s" "$prompt" >&2
        stty -echo
        read -r value || { stty echo; printf "\n❌ 输入已结束，已中止。\n" >&2; return 1; }
        stty echo
        printf "\n" >&2
        [ -n "$value" ] && break
        printf "❌ 该项不能为空，请重新输入。\n" >&2
    done
    printf -v "$var_name" '%s' "$value"
}

# 单选：当前来源/目标均只有一个选项，保留选择步骤便于后续扩展
choose_option() {
    local title="$1" option="$2" var_name="$3" choice
    while true; do
        printf "%s\n  1) %s\n" "$title" "$option" >&2
        printf "请输入序号 [1]: " >&2
        read -r choice || { printf "\n❌ 输入已结束，已中止。\n" >&2; return 1; }
        choice="${choice:-1}"
        [ "$choice" = "1" ] && break
        printf "❌ 无效选择 '%s'。\n" "$choice" >&2
    done
    printf -v "$var_name" '%s' "$option"
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

# 3.4 部署方式：默认反向代理（Traefik + 域名 + 证书），
#     也可直接发布宿主机端口、不依赖 Traefik（容器类应用使用）
# 结果: INSTALL_MODE=proxy|direct
choose_install_mode() {
    local choice
    printf "==========================================\n"
    printf "🔀 请选择部署方式\n"
    printf "==========================================\n"
    printf "  1) 反向代理（Traefik + 域名 + 证书）[默认]\n"
    printf "  2) 直接访问（发布宿主机端口，不使用 Traefik）\n"
    printf "请输入序号 (1/2) [1]: "
    read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    case "${choice:-1}" in
        1) INSTALL_MODE="proxy" ;;
        2) INSTALL_MODE="direct" ;;
        *) printf "❌ 无效输入 '%s'，请输入 1 或 2。\n" "$choice"; return 1 ;;
    esac
    return 0
}

# 交互读取直接访问模式的宿主机端口（回车使用默认值）
# 参数: $1=提示文案 $2=默认端口；结果: DIRECT_PORT
ask_host_port() {
    local label="$1" default="$2" p
    while true; do
        printf "请输入%s [%s]: " "$label" "$default"
        read -r p || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        p="${p:-$default}"
        case "$p" in
            ''|*[!0-9]*) printf "❌ 端口须为数字，请重新输入。\n"; continue ;;
        esac
        [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { printf "❌ 端口须在 1-65535。\n"; continue; }
        DIRECT_PORT="$p"
        return 0
    done
}

# 3.5 ACME 证书签发渠道池与域名的全局管理（纯 DNS-01）：
#     渠道命名 = <根域名>@<提供商别名>，如 example.com@aliyun；
#     应用按所属根域名共享同一渠道
#     多账号：Traefik 的 DNS 凭据是进程级环境变量，同一服务商只能有一套。
#     每个服务商首次配置的账号为主账号，凭据写入 traefik 的 .env；
#     其他账号的根域名通过 CNAME 委派复用主账号凭据：
#       _acme-challenge.<根域名> CNAME _acme-challenge.<根域名>.acme.<主账号锚点根域名>.
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

# 证书签发渠道名 = <根域名>@提供商别名
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
    # 同步内存值：同一次运行里连续新增渠道时不能丢已有根域名
    ROOT_DOMAINS="$*"
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

# 从 traefik.toml 读取 resolver 的 CNAME 委派目标（未委派则失败）
# 约定：委派注释紧邻其 resolver 段之前：
#   # cname-delegation: _acme-challenge.<根域名> CNAME <目标>.
resolver_cname_target() {
    local name="$1" static="${TRAEFIK_HOME:-}/traefik.toml" line target=""
    [ -f "$static" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            '# cname-delegation:'*' CNAME '*)
                target="${line##* CNAME }"
                ;;
            \[certificatesResolvers.*)
                if [ "$line" = "[certificatesResolvers.\"${name}\".acme]" ]; then
                    [ -n "$target" ] && { printf '%s' "$target"; return 0; }
                    return 1
                fi
                # 注释只对紧随其后的 resolver 段有效，跨段即失效
                target=""
                ;;
        esac
    done < "$static"
    return 1
}

# 系统中是否已签发指定根域名的泛域名证书
# 依据: 各渠道独立存储于 letsencrypt/acme-<resolver>.json，
#       证书域名在 JSON 中以 "*.根域名" 字面量出现
# 参数: $1=根域名
root_has_wildcard_cert() {
    local root="$1" file
    [ -n "${TRAEFIK_HOME:-}" ] && [ -n "$root" ] || return 1
    for file in "${TRAEFIK_HOME}"/letsencrypt/acme-*.json; do
        [ -f "$file" ] || continue
        grep -Fq "\"*.${root}\"" "$file" && return 0
    done
    return 1
}

# lego 提供商标识 → 该服务商需要的环境变量名（每行一个）
dns_provider_env_names() {
    case "$1" in
        alidns)         printf '%s\n' ALICLOUD_ACCESS_KEY ALICLOUD_SECRET_KEY ;;
        tencentcloud)   printf '%s\n' TENCENTCLOUD_SECRET_ID TENCENTCLOUD_SECRET_KEY ;;
        cloudflare)     printf '%s\n' CF_DNS_API_TOKEN ;;
        *)              return 1 ;;
    esac
}

# traefik 的 .env 中是否已有该服务商的完整凭据
# （同一服务商只保留主账号一套，后续根域名复用）
provider_credentials_exist() {
    local provider="$1" envf name val names
    envf="${TRAEFIK_HOME:-}/.env"
    [ -f "$envf" ] || return 1
    names=$(dns_provider_env_names "$provider") || return 1
    for name in $names; do
        # 取最后一条非空值，兼容旧版本可能写入的重复键
        val=$(grep "^${name}=" "$envf" 2>/dev/null | tail -n 1 | cut -d= -f2-)
        [ -n "$val" ] || return 1
    done
    return 0
}

# 清理旧版本遗留的同服务商重复凭据键：每个变量只保留最后一条
dedupe_env_provider() {
    local provider="$1" envf name last tmp
    envf="${TRAEFIK_HOME:-}/.env"
    [ -f "$envf" ] || return 0
    tmp="${envf}.tmp"
    cp "$envf" "$tmp" || return 1
    for name in $(dns_provider_env_names "$provider"); do
        last=$(grep "^${name}=" "$tmp" | tail -n 1)
        [ -n "$last" ] || continue
        sed -i "/^${name}=/d" "$tmp"
        printf '%s\n' "$last" >> "$tmp"
    done
    mv "$tmp" "$envf" || return 1
    chmod 600 "$envf" 2>/dev/null
}

# 记录每个服务商的主账号锚点根域名（CNAME 委派目标所在区域）
# 文件格式: <provider>|<根域名>
save_primary_root() {
    local provider="$1" root="$2" conf tmp
    [ -n "${TRAEFIK_HOME:-}" ] || return 1
    conf="${TRAEFIK_HOME}/acme-providers.conf"
    tmp="${conf}.tmp"
    {
        [ -f "$conf" ] && awk -F'|' -v p="$provider" '$1 != p' "$conf"
        printf '%s|%s\n' "$provider" "$root"
    } > "$tmp" || { printf "❌ 无法写入 %s\n" "$conf"; return 1; }
    mv "$tmp" "$conf" || return 1
    chmod 600 "$conf" 2>/dev/null
}

# 读取主账号锚点根域名：优先元数据文件，其次从现有 resolver 池推导
get_primary_root() {
    local provider="$1" conf rd entry
    [ -n "${TRAEFIK_HOME:-}" ] || return 1
    conf="${TRAEFIK_HOME}/acme-providers.conf"
    if [ -f "$conf" ]; then
        rd=$(awk -F'|' -v p="$provider" '$1 == p { print $2; exit }' "$conf")
        [ -n "$rd" ] && { printf '%s' "$rd"; return 0; }
    fi
    for entry in "${RESOLVER_POOL[@]}"; do
        [ "${entry##*|}" = "$provider" ] || continue
        printf '%s' "${entry%%|*}" | sed 's/@.*//'
        return 0
    done
    return 1
}

# 查询 _acme-challenge.<根域名> 的 CNAME 是否指向目标
# 返回: 0=匹配 1=未查到/不匹配 2=系统没有可用的 DNS 查询工具
verify_cname() {
    local rd="$1" want="$2" name got
    name="_acme-challenge.${rd}"
    if command -v dig >/dev/null 2>&1; then
        got=$(dig +short CNAME "$name" 2>/dev/null)
    elif command -v host >/dev/null 2>&1; then
        got=$(host -t CNAME "$name" 2>/dev/null | awk '/is an alias for/ { print $NF; exit }')
    elif command -v nslookup >/dev/null 2>&1; then
        got=$(nslookup -type=CNAME "$name" 2>/dev/null | awk '/canonical name/ { print $NF; exit }')
    else
        return 2
    fi
    got=$(printf '%s\n' "$got" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
    want=$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
    [ -n "$got" ] && printf '%s\n' "$got" | grep -Fqx "$want"
}

# CNAME 委派：把 <根域名> 的 _acme-challenge 指向主账号区域内的目标名，
# 使 Traefik 仅凭主账号凭据即可完成 DNS-01 验证（Traefik 官方推荐的多账号方案）。
# 参数: $1=委派根域名 $2=主账号锚点根域名 $3=服务商标识
# 结果: CNAME_TARGET（含末尾点）
setup_cname_delegation() {
    local rd="$1" primary="$2" provider="$3" target answer i rc
    target="_acme-challenge.${rd}.acme.${primary}."
    # DNS 名称上限 253 字符（不含末尾点）
    if [ ${#target} -gt 254 ]; then
        printf "❌ 委派目标 %s 超过 DNS 名称长度上限，请缩短根域名或锚点根域名。\n" "$target"
        CNAME_TARGET=""
        return 1
    fi
    CNAME_TARGET="$target"

    printf "\n==========================================\n"
    printf "🔗 需要配置 CNAME 委派（多账号）\n"
    printf "==========================================\n"
    printf "请到管理 %s DNS 的区域（另一个 %s 账号）添加：\n\n" "$rd" "$(resolver_alias "$provider")"
    printf "  记录类型: CNAME\n"
    printf "  主机记录: _acme-challenge（区域 %s 内的相对名）\n" "$rd"
    printf "  完整域名: _acme-challenge.%s\n" "$rd"
    printf "  记录值:   %s\n" "$target"
    printf "  提示: “主机记录”不要重复填写区域名，否则会变成\n"
    printf "        _acme-challenge.%s.%s，导致 CNAME 查不到。\n\n" "$rd" "$rd"
    printf "该渠道将为根域名 %s 签发泛域名证书（*.%s + %s），\n" "$rd" "$rd" "$rd"
    printf "CNAME 只需在根级配置一次，覆盖一级子域名（如 app.%s）。\n\n" "$rd"
    printf "原理：Traefik 只持有主账号（锚点 %s）的凭据；\n" "$primary"
    printf "      lego 会沿该 CNAME 到主账号区域创建/删除 TXT 验证记录。\n"
    printf "      若该名字已有旧 TXT/CNAME 记录，请先删除。\n"
    printf "==========================================\n"

    if grep -qi '^LEGO_DISABLE_CNAME_SUPPORT=' "${TRAEFIK_HOME}/.env" 2>/dev/null; then
        # lego 用 strconv.ParseBool，1/t/true 都视为开启
        case "$(grep -i '^LEGO_DISABLE_CNAME_SUPPORT=' "${TRAEFIK_HOME}/.env" | tail -n 1 | cut -d= -f2- | tr '[:upper:]' '[:lower:]')" in
            1|t|true)
                printf "⚠️  .env 中设置了 LEGO_DISABLE_CNAME_SUPPORT，CNAME 将不会被跟随。\n"
                printf "    请删除该配置后重启 traefik。\n"
                ;;
        esac
    fi

    printf "添加完成后按回车验证 CNAME（直接回车继续）: "
    read -r answer || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }

    for i in 1 2 3; do
        verify_cname "$rd" "$target"; rc=$?
        case "$rc" in
            0) printf "✅ CNAME 验证通过。\n"; return 0 ;;
            2) printf "ℹ️  未找到 dig/host/nslookup，跳过自动验证；请自行确认 CNAME 已生效。\n"; return 0 ;;
        esac
        [ "$i" -lt 3 ] && { printf "⏳ 暂未查到 CNAME，5 秒后重试（%d/3）...\n" "$i"; sleep 5; }
    done

    printf "⚠️  暂未验证到 CNAME（可能仍在传播或填写有误）。\n"
    printf "    请先确认: dig +short CNAME _acme-challenge.%s @223.5.5.5\n" "$rd"
    printf "    期望结果: %s\n" "$target"
    printf "    CNAME 生效前签发必然失败。是否仍继续创建渠道？(y/n) [n]: "
    read -r answer || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    case "${answer:-n}" in
        y|Y) return 0 ;;
        *)   CNAME_TARGET=""; printf "已取消，未创建渠道。\n"; return 1 ;;
    esac
}

# 设置/移除某个 resolver 的 CNAME 委派注释
# 参数: $1=resolver 名（如 sysummit.com@aliyun） $2=委派目标（空=移除）
set_resolver_cname_comment() {
    local name="$1" target="$2" static="${TRAEFIK_HOME}/traefik.toml"
    local section_line comment_line l line root
    [ -f "$static" ] || return 1
    section_line=$(grep -nxF "[certificatesResolvers.\"${name}\".acme]" "$static" | head -n 1 | cut -d: -f1)
    [ -n "$section_line" ] || return 1

    # 在 section 之前（允许空行）查找现有委派注释
    comment_line=""
    l=$((section_line - 1))
    while [ "$l" -ge 1 ]; do
        line=$(sed -n "${l}p" "$static")
        case "$line" in
            '# cname-delegation:'*) comment_line="$l"; break ;;
            '') l=$((l - 1)); continue ;;
            *) break ;;
        esac
    done

    if [ -n "$comment_line" ]; then
        sed -i "${comment_line}d" "$static" || return 1
        [ "$comment_line" -lt "$section_line" ] && section_line=$((section_line - 1))
    fi

    if [ -n "$target" ]; then
        root="${name%@*}"
        sed -i "${section_line}i\\# cname-delegation: _acme-challenge.${root} CNAME ${target}" "$static" || return 1
    fi
    return 0
}

# resolver 名 → 可用于 Traefik 路由/服务名的安全标识
# 追加短哈希，避免 a.com@x 与 a-com@x 之类的清洗结果冲突
cert_router_id() {
    local base hash
    base=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-' | sed 's/^-*//; s/-*$//')
    hash=$(printf '%s' "$1" | sha256sum | cut -c1-8)
    printf 'acme-%s-%s' "$base" "$hash"
}

# 为委派渠道生成“仅触发签发”的动态路由：
# rule 使用保留域名 .invalid，不承载业务流量；tls.domains 声明泛域名，
# Traefik 加载配置后即按需签发，无需等应用安装。
# 参数: $1=resolver 名 $2=根域名
write_cert_only_router() {
    local name="$1" root="$2" id dir file tmp
    [ -n "${TRAEFIK_HOME:-}" ] || return 1
    dir="${TRAEFIK_HOME}/config"
    mkdir -p "$dir" || return 1
    id=$(cert_router_id "$name")
    file="${dir}/acme-${name}.toml"
    tmp="${file}.tmp"
    cat > "$tmp" <<EOF
# 由安装器生成：仅用于触发泛域名证书签发，不承载业务流量
# resolver: ${name}
[http.routers.${id}]
  rule = "Host(\`${id}.invalid\`)"
  entryPoints = ["websecure"]
  service = "${id}-svc"
  [http.routers.${id}.tls]
    certResolver = "${name}"
    [[http.routers.${id}.tls.domains]]
      main = "*.${root}"
      sans = ["${root}"]
[http.services.${id}-svc.loadBalancer]
  [[http.services.${id}-svc.loadBalancer.servers]]
    url = "http://127.0.0.1:1"
EOF
    mv "$tmp" "$file" || return 1
    chmod 644 "$file" 2>/dev/null
}

# 移除委派渠道的“仅触发签发”动态路由（切换为主账号时使用）
remove_cert_only_router() {
    local name="$1" file
    [ -n "${TRAEFIK_HOME:-}" ] || return 0
    file="${TRAEFIK_HOME}/config/acme-${name}.toml"
    rm -f "$file"
}

# 同步 Dashboard 动态路由的证书域名声明
# 参数: $1=resolver 名 $2=根域名 $3=1 委派（使用泛域名）/0 主账号（移除泛域名）
# 仅当 dashboard.toml 的 certResolver 指向该 resolver 时生效
sync_dashboard_cert_domains() {
    local name="$1" root="$2" delegated="$3" file tmp host
    [ -n "${TRAEFIK_HOME:-}" ] || return 0
    file="${TRAEFIK_HOME}/config/dashboard.toml"
    [ -f "$file" ] || return 0
    grep -qF "certResolver = \"${name}\"" "$file" || return 0

    # 删除已有的泛域名声明块（安装器生成格式：1 行段头 + 2 行属性）
    tmp="${file}.tmp"
    awk '
        /^\[\[http\.routers\.dashboard\.tls\.domains\]\]/ { skip = 2; next }
        skip > 0 { skip--; next }
        { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$file" || return 1

    [ "$delegated" = 1 ] || return 0

    # 泛域名只覆盖一级子域名，Dashboard 域名层级不匹配时明确告警
    host=$(sed -n 's/.*Host(`\([^`]*\)`.*/\1/p' "$file" | head -n 1)
    if [ -n "$host" ] && ! app_domain_covered_by_wildcard "$host" "$root"; then
        printf "⚠️  Dashboard 域名 %s 不在泛域名 *.%s 覆盖范围内，证书可能无法签发。\n" "$host" "$root"
    fi
    cat >> "$file" <<EOF

[[http.routers.dashboard.tls.domains]]
  main = "*.${root}"
  sans = ["${root}"]
EOF
}

# 用当前的 DNS_ENV_NAMES/VALUES 覆盖某服务商在 .env 中的凭据
# （切换主账号时使用；同一服务商始终只保留一套）
set_provider_credentials() {
    local provider="$1" envf="${TRAEFIK_HOME}/.env" i
    [ ${#DNS_ENV_NAMES[@]} -gt 0 ] || return 1
    [ -f "$envf" ] || return 1
    for i in "${!DNS_ENV_NAMES[@]}"; do
        sed -i "/^${DNS_ENV_NAMES[$i]}=/d" "$envf" || return 1
    done
    {
        printf '\n# %s DNS 凭据（主账号，供该服务商下所有根域名共用）\n' "$provider"
        for i in "${!DNS_ENV_NAMES[@]}"; do
            printf '%s=%s\n' "${DNS_ENV_NAMES[$i]}" "${DNS_ENV_VALUES[$i]}"
        done
    } >> "$envf" || return 1
    chmod 600 "$envf" 2>/dev/null
}

# 显式切换某服务商的主账号（不依赖渠道添加顺序）
# 参数: $1=provider $2=新锚点根域名；依赖 DNS_ENV_NAMES/VALUES（新账号凭据）
# 副作用: 覆盖 .env 凭据、更新锚点、重算该服务商所有渠道的 CNAME 注释
# 结果: PRIMARY_SWITCHED=1
switch_primary_account() {
    local provider="$1" new_anchor="$2" old_anchor entry name root target envf
    [ -n "${TRAEFIK_HOME:-}" ] || return 1
    [ -n "$new_anchor" ] || return 1
    old_anchor=$(get_primary_root "$provider" 2>/dev/null || true)

    set_provider_credentials "$provider" || return 1
    save_primary_root "$provider" "$new_anchor" || return 1
    # 凭据已落盘，避免 create_resolver 在新增渠道时再次写入
    DNS_ENV_NAMES=()
    DNS_ENV_VALUES=()

    list_traefik_resolvers 2>/dev/null || true
    # 新锚点不再需要“仅触发签发”路由（可能不在当前池中，直接按名字删除）
    remove_cert_only_router "$(resolver_name "$new_anchor" "$provider")"
    printf "\n==========================================\n"
    printf "🔁 %s 主账号已切换为: %s\n" "$(resolver_alias "$provider")" "$new_anchor"
    printf "==========================================\n"
    for entry in "${RESOLVER_POOL[@]}"; do
        [ "${entry##*|}" = "$provider" ] || continue
        name="${entry%%|*}"
        root="${name%@*}"
        if [ "$root" = "$new_anchor" ]; then
            if resolver_cname_target "$name" >/dev/null 2>&1; then
                printf "可删除旧的 CNAME: _acme-challenge.%s\n" "$root"
            fi
            remove_cert_only_router "$name" || return 1
            set_resolver_cname_comment "$name" "" || return 1
            sync_dashboard_cert_domains "$name" "$root" 0 || return 1
        else
            target="_acme-challenge.${root}.acme.${new_anchor}."
            write_cert_only_router "$name" "$root" || return 1
            set_resolver_cname_comment "$name" "$target" || return 1
            sync_dashboard_cert_domains "$name" "$root" 1 || return 1
            printf "请配置 CNAME: _acme-challenge.%s -> %s\n" "$root" "$target"
            # 旧应用可能仍声明精确域名证书；泛域名证书签发后虽可服务，
            # 但其续期仍会失败，提示重跑安装改用泛域名
            if [ -n "${SERVICE_BASE:-}" ]; then
                for envf in "$SERVICE_BASE"/*/.env; do
                    [ -f "$envf" ] || continue
                    grep -qF "_RESOLVER=${name}" "$envf" 2>/dev/null || continue
                    grep -qE '^[A-Z0-9_]+_CERT_MAIN=\*\.' "$envf" 2>/dev/null && continue
                    printf "⚠️  应用 %s 仍按精确域名申请证书，建议重跑其 install.sh 改用泛域名。\n" "$(dirname "$envf")"
                done
            fi
        fi
    done
    if [ -n "$old_anchor" ] && [ "$old_anchor" != "$new_anchor" ]; then
        printf "ℹ️  原主账号锚点 %s 已改为委派渠道。\n" "$old_anchor"
    fi
    printf "⚠️  凭据已变更，需重建容器生效: cd %s && docker compose up -d --force-recreate\n" "$TRAEFIK_HOME"
    printf "⚠️  请先完成上述 CNAME 调整，否则委派渠道续期会失败。\n"
    PRIMARY_SWITCHED=1
    return 0
}

# 收集/沿用 ACME 邮箱与 CA 环境（traefik.toml 已有则沿用，
# .installer.conf 已存则复用，都没有才交互询问；供 traefik 安装与应用新增 resolver 共用）
# 参数: $1 = confirm_reuse 时，检测到已有配置会显示并询问是否沿用（安装 traefik 使用）
collect_acme_meta() {
    local confirm_reuse="${1:-}" existing_email="" existing_ca=""
    if [ -n "$TRAEFIK_HOME" ] && [ -f "$TRAEFIK_HOME/traefik.toml" ]; then
        existing_email=$(grep -m1 'email = ' "$TRAEFIK_HOME/traefik.toml" | sed 's/.*= *"\(.*\)".*/\1/')
        existing_ca=$(grep -m1 'caServer = ' "$TRAEFIK_HOME/traefik.toml" | sed 's/.*= *"\(.*\)".*/\1/')
    fi
    if [ -z "$existing_email" ] || [ -z "$existing_ca" ]; then
        existing_email="$ACME_EMAIL"
        existing_ca="$ACME_CA_SERVER"
    fi
    if [ -n "$existing_email" ] && [ -n "$existing_ca" ]; then
        ACME_EMAIL="$existing_email"
        ACME_CA_SERVER="$existing_ca"
        [ "$confirm_reuse" = confirm_reuse ] || return 0

        # 安装 traefik 时让用户明确看到沿用的值，并允许重新填写
        local ca_label="生产"
        case "$ACME_CA_SERVER" in
            *staging*) ca_label="测试（staging）" ;;
        esac
        printf "ℹ️  检测到已有 Let's Encrypt 基础信息：\n"
        printf "    邮箱: %s\n" "$ACME_EMAIL"
        printf "    CA:   %s\n" "$ca_label"
        while true; do
            printf "是否沿用？(y/n) [y]: "
            read -r reuse || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            case "${reuse:-y}" in
                y|Y) return 0 ;;
                n|N) ACME_EMAIL=""; ACME_CA_SERVER=""; break ;;
                *) printf "❌ 无效输入 '%s'，请输入 y 或 n。\n" "$reuse" ;;
            esac
        done
    fi

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
# 参数: $1 = 根域名（如 example.com）；
#       依赖 DNS_PROVIDER、DNS_ENV_NAMES/VALUES、ACME_EMAIL/ACME_CA_SERVER、TRAEFIK_HOME
create_resolver() {
    local rd="$1" name
    name=$(resolver_name "$rd" "$DNS_PROVIDER")
    local static="${TRAEFIK_HOME}/traefik.toml"
    local envf="${TRAEFIK_HOME}/.env"
    local ldir="${TRAEFIK_HOME}/letsencrypt"

    # 同名证书签发渠道（同根域名+同提供商）已存在则拒绝（防重复定义）
    if grep -qF "[certificatesResolvers.\"${name}\".acme]" "$static" 2>/dev/null; then
        printf "❌ 证书签发渠道 %s 已存在，请直接选用。\n" "$name"
        return 1
    fi

    mkdir -p "$ldir"
    {
        # 委派注释供 resolver 列表展示，也便于人工排查 CNAME 配置
        if [ -n "${CNAME_TARGET:-}" ]; then
            printf '\n# cname-delegation: _acme-challenge.%s CNAME %s\n' "$rd" "$CNAME_TARGET"
        fi
        cat <<EOF

[certificatesResolvers."${name}".acme]
  email = "${ACME_EMAIL}"
  storage = "/letsencrypt/acme-${name}.json"       # 证书存储（每 resolver 独立文件，禁止共用）
  caServer = "${ACME_CA_SERVER}"                    # 生产或 staging 的 ACME 目录地址
  keyType = "EC256"                                 # EC256 比默认 RSA4096 更小、握手更快

  # 证书签发采用 DNS-01 验证，凭据经 .env 注入（见各厂商环境变量）
  [certificatesResolvers."${name}".acme.dnsChallenge]
    provider = "${DNS_PROVIDER}"
    delayBeforeCheck = 30                           # 等 DNS 记录传播，传播慢可适当调大
    # 递归 DNS 用于 CNAME 跟随与 TXT 传播检查；1.1.1.1 在部分网络下 UDP 超时，
    # 默认使用国内可达的阿里云 DNS
    resolvers = ["223.5.5.5:53", "223.6.6.6:53"]
EOF
    } >> "$static"

    touch "${ldir}/acme-${name}.json"
    chmod 600 "${ldir}/acme-${name}.json"

    # 委派渠道：立即生成仅触发泛域名签发的动态路由（不依赖应用安装）
    if [ -n "${CNAME_TARGET:-}" ]; then
        write_cert_only_router "$name" "$rd" || return 1
    fi

    # 同一服务商只保留主账号一套凭据：复用时不写入；首次写入前清理同名旧键
    if [ ${#DNS_ENV_NAMES[@]} -gt 0 ]; then
        local i
        for i in "${!DNS_ENV_NAMES[@]}"; do
            sed -i "/^${DNS_ENV_NAMES[$i]}=/d" "$envf" 2>/dev/null || true
        done
        {
            printf '\n# %s DNS 凭据（主账号，供该服务商下所有根域名共用）\n' "$DNS_PROVIDER"
            for i in "${!DNS_ENV_NAMES[@]}"; do
                printf '%s=%s\n' "${DNS_ENV_NAMES[$i]}" "${DNS_ENV_VALUES[$i]}"
            done
        } >> "$envf"
        chmod 600 "$envf" 2>/dev/null
    fi

    APP_RESOLVER="$name"
    return 0
}

# 新增证书签发渠道交互流程（traefik configure 与应用内引导共用）
# 参数: $1 = 可选根域名（应用已确定根域名时传入；为空则询问）
# 结果: APP_RESOLVER；实际写入时 RESOLVER_ADDED=1，命中既有则 0
add_dns_resolver() {
    local rd="${1:-}" name entry new_primary=""
    if [ -z "$rd" ]; then
        printf "请输入该证书签发渠道关联的根域名（如 example.com）: "
        read -r rd || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        validate_root_domain "$rd" || return 1
    fi
    choose_dns_provider || return 1
    name=$(resolver_name "$rd" "$DNS_PROVIDER")

    list_traefik_resolvers 2>/dev/null || true
    for entry in "${RESOLVER_POOL[@]}"; do
        if [ "${entry%%|*}" = "$name" ]; then
            printf "ℹ️  证书签发渠道 %s 已存在，直接复用（无需重启）。\n" "$name"
            APP_RESOLVER="$name"
            RESOLVER_ADDED=0
            return 0
        fi
    done

    CNAME_TARGET=""
    if provider_credentials_exist "$DNS_PROVIDER"; then
        # 该服务商已有主账号凭据：复用，不再向 .env 追加第二套
        # 顺带清理旧版本可能留下的重复键（保留最后一条）
        dedupe_env_provider "$DNS_PROVIDER" || true
        local primary_root answer
        primary_root=$(get_primary_root "$DNS_PROVIDER" 2>/dev/null || true)
        if [ -z "$primary_root" ]; then
            # 旧版本升级或手工配置时没有锚点信息，补问一次
            printf "请输入主账号下用于 CNAME 委派的根域名（如 example.com）: "
            read -r primary_root || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            validate_root_domain "$primary_root" || return 1
            save_primary_root "$DNS_PROVIDER" "$primary_root" || return 1
        fi
        printf "ℹ️  该 DNS 服务商已有凭据（主账号锚点: %s）。\n" "$primary_root"
        printf "    根域名 %s 的 DNS 属于：\n" "$rd"
        printf "      1) 同一账号（直接复用主账号凭据）[默认]\n"
        printf "      2) 不同账号（CNAME 委派到主账号 %s）\n" "$primary_root"
        printf "      3) 不同账号，并将本根域名的账号设为主账号（切换主账号）\n"
        printf "    请选择 (1/2/3) [1]: "
        read -r answer || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        case "${answer:-1}" in
            1)
                DNS_ENV_NAMES=()
                DNS_ENV_VALUES=()
                ;;
            2)
                setup_cname_delegation "$rd" "$primary_root" "$DNS_PROVIDER" || return 1
                DNS_ENV_NAMES=()
                DNS_ENV_VALUES=()
                ;;
            3)
                collect_dns_credentials || return 1
                switch_primary_account "$DNS_PROVIDER" "$rd" || return 1
                # 锚点已由 switch_primary_account 登记，凭据也已落盘
                new_primary=""
                ;;
            *)
                printf "❌ 无效输入 '%s'，请输入 1、2 或 3。\n" "$answer"
                return 1
                ;;
        esac
    else
        collect_dns_credentials || return 1
        # 该服务商的第一套凭据即主账号
        new_primary="$rd"
    fi
    collect_acme_meta || return 1
    create_resolver "$rd" || return 1
    # 创建成功后再登记锚点根域名，避免失败时留下脏数据；
    # 登记失败不撤销已创建的渠道（get_primary_root 还能从 resolver 池推导）
    if [ -n "$new_primary" ]; then
        save_primary_root "$DNS_PROVIDER" "$new_primary" \
            || printf "⚠️  主账号锚点登记失败，后续委派时可能需手动指定锚点根域名。\n"
    fi
    RESOLVER_ADDED=1
    # 根域名登记进全局池：供 Dashboard 默认域名推导与应用安装时选择复用
    local rd_pool seen=""
    for rd_pool in $ROOT_DOMAINS; do [ "$rd_pool" = "$rd" ] && seen=1; done
    [ -n "$seen" ] || save_global_root_domains $ROOT_DOMAINS "$rd" || return 1
    printf "✅ 已新增证书签发渠道 %s（根域名 %s，DNS 服务商: %s）\n" "$APP_RESOLVER" "$rd" "$DNS_PROVIDER"
    return 0
}

# 3.5b 静态证书：预签发的 leaf 证书（CA 签/自签均可）挂载进 traefik，
#      经 [[tls.certificates]] 按 SNI 匹配，与 ACME resolver 并存。
#      属于静态配置：增/换证书需重启 traefik；续期=重跑同一流程替换文件。

# 解析 traefik.toml 中的静态证书清单: STATIC_CERTS=("id|domains|notAfter" ...)
# 标记行格式: # static-cert: <id> domains=<a,b> notAfter=<date>
list_static_certs() {
    STATIC_CERTS=()
    local static="${TRAEFIK_HOME:-}/traefik.toml" line
    [ -f "$static" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            "# static-cert: "*)
                local id dom nd
                id=$(printf '%s' "$line" | awk '{print $3}')
                dom=$(printf '%s' "$line" | sed -n 's/.*domains=\([^ ]*\).*/\1/p')
                nd=$(printf '%s' "$line" | sed -n 's/.*notAfter=\(.*\)/\1/p')
                STATIC_CERTS+=("${id}|${dom}|${nd}")
                ;;
        esac
    done < "$static"
    [ ${#STATIC_CERTS[@]} -gt 0 ]
}

# 新增一张静态证书：路径采集 → openssl 校验（格式/密钥配对/SAN/有效期）
# → 落盘 certs/<id>/ → 替换或追加 [[tls.certificates]] 段
# 结果: STATIC_ADDED=1（调用方提示重启 traefik）
add_static_cert_flow() {
    # 校验环节依赖 openssl（主流发行版默认自带，缺则经包管理安装）
    command -v openssl >/dev/null 2>&1 || pkg_install openssl
    if ! command -v openssl >/dev/null 2>&1; then
        printf "❌ 需要 openssl 校验证书，当前不可用，请先安装后重试。\n"
        return 1
    fi
    [ -n "$TRAEFIK_HOME" ] && [ -f "$TRAEFIK_HOME/traefik.toml" ] || {
        printf "❌ 尚未安装 traefik，无法添加静态证书。\n"; return 1; }

    local cert_path key_path
    printf "请输入证书文件路径（fullchain，绝对路径）: "
    read -r cert_path || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    printf "请输入私钥文件路径（privkey，绝对路径）: "
    read -r key_path || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }

    if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
        printf "❌ 文件不存在，请检查路径。\n"; return 1
    fi
    if ! openssl x509 -in "$cert_path" -noout 2>/dev/null; then
        printf "❌ %s 不是有效的 X.509 证书。\n" "$cert_path"; return 1
    fi

    # 解析 SAN（退化到 subject CN）与有效期
    local domains cn
    domains=$(openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null \
              | grep -o 'DNS:[^,]*' | sed 's/DNS://; s/^ *//; s/ *$//' | paste -sd, -)
    if [ -z "$domains" ]; then
        cn=$(openssl x509 -in "$cert_path" -noout -subject | sed -E 's/.*CN *= *//')
        domains="$cn"
    fi
    local not_after
    not_after=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)

    # 密钥配对校验（x509 与 pkey 公钥摘要一致，兼容 RSA/EC）
    local cp1 cp2
    cp1=$(openssl x509 -in "$cert_path" -noout -pubkey | sha256sum | cut -d' ' -f1)
    cp2=$(openssl pkey -in "$key_path" -pubout 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [ -z "$cp2" ] || [ "$cp1" != "$cp2" ]; then
        printf "❌ 证书与私钥不匹配，已中止。\n"; return 1
    fi

    local id="${domains%%,*}"
    printf "==========================================\n"
    printf "📜 静态证书预览:\n"
    printf "   标识(id): %s\n" "$id"
    printf "   SAN 域名: %s\n" "$domains"
    printf "   到期时间: %s\n" "$not_after"
    printf "==========================================\n"
    local overw=""
    grep -qF "# static-cert: $id " "$TRAEFIK_HOME/traefik.toml" 2>/dev/null && overw="（同 id 将覆盖旧证书）"
    printf "将写入 %s/certs/%s/ 并追加 tls.certificates 段%s (y/n) [y]: " "$TRAEFIK_HOME" "$id" "$overw"
    read -r confirm || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    case "${confirm:-y}" in
        y|Y) : ;;
        *) printf "已取消。\n"; return 0 ;;
    esac

    mkdir -p "${TRAEFIK_HOME}/certs/${id}" || { printf "❌ 无法创建证书目录。\n"; return 1; }
    cp "$cert_path" "${TRAEFIK_HOME}/certs/${id}/fullchain.pem" || return 1
    cp "$key_path"  "${TRAEFIK_HOME}/certs/${id}/privkey.pem"  || return 1
    chmod 600 "${TRAEFIK_HOME}/certs/${id}/privkey.pem"

    # 同 id 旧段（标记行+3 行块）删除后重写，杜绝重复条目
    local static="${TRAEFIK_HOME}/traefik.toml" tmp="${static}.tmp"
    awk -v id="$id" '
        $0 ~ "^# static-cert: "id" " { skip = 3; next }
        skip > 0 { skip--; next }
        { print }
    ' "$static" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$static" || return 1
    printf '\n# static-cert: %s domains=%s notAfter=%s\n[[tls.certificates]]\n  certFile = "/etc/traefik/certs/%s/fullchain.pem"\n  keyFile = "/etc/traefik/certs/%s/privkey.pem"\n' \
        "$id" "$domains" "$not_after" "$id" "$id" >> "$static" || return 1

    STATIC_ADDED=1
    printf "✅ 静态证书已登记（id: %s）。⚠️ [[tls.certificates]] 属静态配置，需重启 traefik 生效。\n" "$id"
    return 0
}

# 切换 Let's Encrypt CA 环境（生产 ↔ 测试）：
# 同步更新 traefik.toml 中全部 resolver 的 caServer 与全局默认；
# 旧环境证书存储备份后清空，重启 traefik 后按新环境重新注册与签发。
# 结果: CA_CHANGED=1（实际发生切换时）
switch_acme_ca() {
    local static="${TRAEFIK_HOME}/traefik.toml"
    local current new_ca choice label cur_label count=0 entry stem file backup
    # 以 traefik.toml 中实际配置为准，全局配置仅作兜底，避免两者不同步时误判
    current=$(grep -m1 'caServer = ' "$static" 2>/dev/null | sed 's/.*= *"\(.*\)".*/\1/')
    [ -n "$current" ] || current="$ACME_CA_SERVER"

    case "$current" in
        *staging*)                                      cur_label="测试（staging）" ;;
        https://acme-v02.api.letsencrypt.org/directory) cur_label="生产" ;;
        '')                                             cur_label="未配置" ;;
        *)                                              cur_label="$current" ;;
    esac

    printf "==========================================\n"
    printf "🔄 切换 Let's Encrypt 环境（当前: %s）\n" "$cur_label"
    printf "==========================================\n"
    printf "  1) 生产  (正式证书，浏览器信任，有速率限制)\n"
    printf "  2) 测试  (staging，不受速率限制，浏览器不信任)\n"
    if [ "$cur_label" = "生产" ]; then
        printf "请选择 (1/2) [1]: "
    else
        printf "请选择 (1/2) [2]: "
    fi
    read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    if [ -z "$choice" ]; then
        [ "$cur_label" = "生产" ] && choice=1 || choice=2
    fi
    case "$choice" in
        1) new_ca="https://acme-v02.api.letsencrypt.org/directory";         label="生产" ;;
        2) new_ca="https://acme-staging-v02.api.letsencrypt.org/directory"; label="测试（staging）" ;;
        *) printf "❌ 无效输入 '%s'。\n" "$choice"; return 1 ;;
    esac
    # 只有全部渠道都已是目标地址才跳过；部分不同步时仍需统一（幂等）
    local total target
    total=$(grep -c 'caServer = ' "$static" 2>/dev/null || true)
    target=$(grep -c "caServer = \"${new_ca}\"" "$static" 2>/dev/null || true)
    if [ "$total" -gt 0 ] && [ "$total" = "$target" ]; then
        set_installer_key ACME_CA_SERVER "$new_ca" || return 1
        ACME_CA_SERVER="$new_ca"
        printf "ℹ️  全部证书签发渠道已是%s环境，无需切换。\n" "$label"
        return 0
    fi

    # 只替换引号内的地址，保留行尾注释
    sed -i "s|^\([[:space:]]*caServer = \)\"[^\"]*\"|\1\"${new_ca}\"|" "$static" || return 1
    set_installer_key ACME_CA_SERVER "$new_ca" || return 1
    ACME_CA_SERVER="$new_ca"

    # 旧环境存储的账号/证书不再适用：备份后清空，让 traefik 重新注册并签发
    list_traefik_resolvers 2>/dev/null || true
    for entry in "${RESOLVER_POOL[@]}"; do
        stem="${entry%%|*}"
        file="${TRAEFIK_HOME}/letsencrypt/acme-${stem}.json"
        if [ -f "$file" ]; then
            backup="${file}.bak.$(date +%s)"
            mv "$file" "$backup" || { printf "❌ 备份 %s 失败。\n" "$file"; return 1; }
            count=$((count + 1))
        fi
    done

    CA_CHANGED=1
    printf "✅ 已切换为%s环境，并备份清空 %d 个证书签发渠道的证书存储。\n" "$label" "$count"
    printf "⚠️  需重启 traefik 生效；重启后将按新环境重新签发证书。\n"
    return 0
}

# 交互式切换 DNS 服务商主账号（不依赖渠道添加顺序）
# 结果: PRIMARY_SWITCHED=1
switch_primary_account_flow() {
    local provider="" entry choice i root
    local providers=() roots=()
    list_traefik_resolvers || { printf "❌ 尚未配置任何证书签发渠道。\n"; return 1; }

    for entry in "${RESOLVER_POOL[@]}"; do
        provider="${entry##*|}"
        # 跳过无法识别、无凭据模板的 provider
        dns_provider_env_names "$provider" >/dev/null 2>&1 || continue
        case " ${providers[*]} " in
            *" $provider "*) : ;;
            *) providers+=("$provider") ;;
        esac
    done
    if [ ${#providers[@]} -eq 0 ]; then
        printf "❌ 没有可切换的服务商。\n"
        return 1
    fi

    printf "==========================================\n"
    printf "🔁 切换 DNS 服务商主账号\n"
    printf "==========================================\n"
    i=1
    for provider in "${providers[@]}"; do
        printf "  %d) %s（当前锚点: %s）\n" "$i" "$(resolver_alias "$provider")" \
            "$(get_primary_root "$provider" 2>/dev/null || printf '未记录')"
        i=$((i + 1))
    done
    printf "请选择服务商 (1-%d): " "${#providers[@]}"
    read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    case "$choice" in
        ''|*[!0-9]*) printf "❌ 无效输入。\n"; return 1 ;;
    esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "${#providers[@]}" ] \
        || { printf "❌ 超出范围。\n"; return 1; }
    provider="${providers[$((choice - 1))]}"

    for entry in "${RESOLVER_POOL[@]}"; do
        [ "${entry##*|}" = "$provider" ] || continue
        roots+=("$(printf '%s' "${entry%%|*}" | sed 's/@.*//')")
    done
    printf "请选择新的主账号锚点根域名:\n"
    i=1
    for root in "${roots[@]}"; do
        printf "  %d) %s\n" "$i" "$root"
        i=$((i + 1))
    done
    printf "请输入序号 (1-%d): " "${#roots[@]}"
    read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    case "$choice" in
        ''|*[!0-9]*) printf "❌ 无效输入。\n"; return 1 ;;
    esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "${#roots[@]}" ] \
        || { printf "❌ 超出范围。\n"; return 1; }
    root="${roots[$((choice - 1))]}"

    printf "⚠️  切换后，除 %s 外的渠道都需要把 CNAME 指向 %s 区域。\n" "$root" "$root"
    printf "    继续？(y/n) [n]: "
    read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    case "${choice:-n}" in
        y|Y) : ;;
        *) printf "已取消。\n"; return 0 ;;
    esac

    printf "请输入新主账号（%s）的 API 凭据:\n" "$(resolver_alias "$provider")"
    DNS_PROVIDER="$provider"
    collect_dns_credentials || return 1
    switch_primary_account "$provider" "$root" || return 1
    return 0
}

# traefik 证书管理菜单（configure.sh 使用）：
# DNS resolver 新增/复用成功后直接结束；静态证书可继续添加，n 结束；
# 变更标记经 RESOLVER_ADDED/STATIC_ADDED/CA_CHANGED/PRIMARY_SWITCHED 返回
configure_traefik_menu() {
    local choice
    while true; do
        printf "🧰 选择要进行的证书操作:\n"
        printf "  1) ACME 自动签发（DNS-01，需 DNS 提供商凭据）\n"
        printf "  2) 静态证书（预签发的证书文件，按 SNI 匹配）\n"
        printf "  3) 切换 Let's Encrypt 环境（生产/测试）\n"
        printf "  4) 切换 DNS 服务商主账号（多账号 CNAME 委派）\n"
        printf "  n) 完成\n"
        printf "请输入 (1/2/3/4/n) [n]: "
        read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        case "$choice" in
            # 新增或复用 resolver 成功后直接退出，不再重复询问是否继续添加
            1) add_dns_resolver && return 0 ;;
            2) add_static_cert_flow ;;
            # 切换环境/主账号属于完整操作，完成后同样结束菜单
            3) switch_acme_ca && return 0 ;;
            4) switch_primary_account_flow && return 0 ;;
            n|N|"") return 0 ;;
            *) printf "❌ 无效输入 '%s'。\n" "$choice" ;;
        esac
    done
}

# 选择证书 resolver：列出既有池 + 末尾「新增 resolver」
# 参数: $1 = 根域名（只列出 <根域名>@* 的渠道，并以其为新增默认）；
#       为空 = 列出全部（Dashboard 等）
# 结果: APP_RESOLVER；实际新增成功时 RESOLVER_ADDED=1（调用方据此提示重启 traefik）
choose_or_add_resolver() {
    local rd="${1:-}" allow_skip="${2:-}"
    printf "==========================================\n"
    if [ -n "$rd" ]; then
        printf "🔐 请为根域名 %s 选择证书签发渠道\n" "$rd"
        printf "   证书签发渠道由 根域名@DNS服务商 标识\n"
        printf "   对应标识: %s@<DNS服务商>\n" "$rd"
    else
        printf "🔐 请选择证书签发渠道\n"
        printf "   证书签发渠道由 根域名@DNS服务商 标识\n"
        printf "   示例: example.com@aliyun\n"
    fi
    printf "==========================================\n"
    local i choice entry shown=0
    # 进入菜单前刷新池：add_dns_resolver 创建新段后池可能是写入前的旧状态
    list_traefik_resolvers 2>/dev/null || RESOLVER_POOL=()
    while true; do
        i=1
        shown=0
        for entry in "${RESOLVER_POOL[@]}"; do
            # 指定域名时只显示 <该域名>@* 的 resolver；
            # 用 case + 引号前缀匹配，避免 rd 中的 * 被当成模式通配符
            if [ -n "$rd" ]; then
                case "${entry%%|*}" in
                    "${rd}@"*) : ;;
                    *) continue ;;
                esac
            fi
            printf "  %d) %s（provider: %s）\n" "$i" "${entry%%|*}" "${entry##*|}"
            i=$((i + 1))
            shown=$((shown + 1))
        done
        # 指定根域名且没有任何匹配渠道：直接询问是否新增
        if [ -n "$rd" ] && [ "$shown" -eq 0 ]; then
            printf "⚠️  未找到根域名 %s 对应的证书签发渠道。\n" "$rd"
            printf "是否新增证书签发渠道 %s@<DNS服务商>？(y/n) [y]: " "$rd"
            read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            case "${choice:-y}" in
                y|Y)
                    add_dns_resolver "$rd" || return 1
                    list_traefik_resolvers 2>/dev/null || true
                    return 0
                    ;;
                n|N)
                    printf "❌ 未绑定证书签发渠道，无法自动签发证书。\n"
                    return 1
                    ;;
                *)
                    printf "❌ 无效输入 '%s'，请输入 y 或 n。\n" "$choice"
                    continue
                    ;;
            esac
        fi
        if [ -n "$rd" ]; then
            printf "  %d) 新增证书签发渠道 %s@<DNS服务商>\n" "$i" "$rd"
        else
            printf "  %d) 新增证书签发渠道（输入根域名与 DNS 服务商）\n" "$i"
        fi
        local skip_idx=$((i + 1))
        if [ -n "$allow_skip" ]; then
            printf "  %d) 跳过（不绑定证书签发渠道，暂用自签证书兜底）\n" "$skip_idx"
            printf "请输入序号 (1-%d) [1]: " "$skip_idx"
        else
            printf "请输入序号 (1-%d) [1]: " "$i"
        fi
        read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        [ -n "$choice" ] || choice=1
        case "$choice" in
            *[!0-9]*) printf "❌ 无效输入，请输入数字序号。\n"; continue ;;
        esac
        if [ -n "$allow_skip" ] && [ "$choice" -eq "$skip_idx" ]; then
            APP_RESOLVER=""
            RESOLVER_ADDED=0
            printf "⏭️  已跳过证书签发渠道绑定。\n"
            return 0
        fi
        if [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
            # 定位第 choice 个「已显示」条目（与过滤逻辑一致地重新数一遍）
            local n=0
            for entry in "${RESOLVER_POOL[@]}"; do
                # 与显示过滤一致；引号前缀匹配，避免 rd 中的 * 被当成通配符
                if [ -n "$rd" ]; then
                    case "${entry%%|*}" in
                        "${rd}@"*) : ;;
                        *) continue ;;
                    esac
                fi
                n=$((n + 1))
                if [ "$n" -eq "$choice" ]; then
                    APP_RESOLVER="${entry%%|*}"
                    RESOLVER_ADDED=0
                    printf "✅ 使用证书签发渠道: %s\n" "$APP_RESOLVER"
                    return 0
                fi
            done
        fi
        [ "$choice" -eq "$i" ] || { printf "❌ 超出范围。\n"; continue; }

        # 新增分支：共用 add_dns_resolver（已带根域名）
        add_dns_resolver "$rd" || return 1
        # 刷新池供可能的再次选择
        list_traefik_resolvers 2>/dev/null || true
        return 0
    done
}

# 从完整域名匹配根域名池中的最长后缀；无匹配则输出空
match_root_domain() {
    local host="$1" rd best=""
    for rd in $ROOT_DOMAINS; do
        case "$host" in
            "$rd"|*".$rd") [ ${#rd} -gt ${#best} ] && best="$rd" ;;
        esac
    done
    printf '%s' "$best"
}

# 判断完整域名是否被 <根域名> 的泛域名证书覆盖：
# 根域名本身，或恰好一级子域名（*.root）返回 0；更深层级返回 1
app_domain_covered_by_wildcard() {
    local host="$1" root="$2" prefix
    [ -n "$host" ] && [ -n "$root" ] || return 1
    case "$host" in
        "$root") return 0 ;;
        *".$root")
            prefix="${host%".$root"}"
            case "$prefix" in
                ''|*.*) return 1 ;;
                *)      return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

# 选择应用访问域名：直接输入完整域名，按所属根域名匹配证书签发渠道
# 结果: APP_HOST / CERT_MAIN="" / CERT_SANS=""（由 Traefik 按 router 域名自动签发）
#       SELECTED_ROOT_DOMAIN / APP_RESOLVER_DOMAIN（用于派生与渠道匹配）
choose_app_domain() {
    local exact root guess d seen
    APP_RESOLVER_DOMAIN=""
    SELECTED_ROOT_DOMAIN=""
    CERT_MAIN=""
    CERT_SANS=""

    printf "==========================================\n"
    printf "🌐 请配置应用访问域名\n"
    printf "==========================================\n"

    while true; do
        printf "请输入应用完整域名（如 app.example.com）: "
        read -r exact || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        validate_root_domain "$exact" || continue

        # 根域名：优先匹配根域名池中的最长后缀，未命中则询问确认
        root=$(match_root_domain "$exact")
        if [ -z "$root" ]; then
            guess=$(printf '%s' "$exact" | awk -F. '{ if (NF >= 2) print $(NF-1)"."$NF; else print $0 }')
            printf "请输入该域名所属根域名（用于匹配证书签发渠道）[%s]: " "$guess"
            read -r root || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
            root="${root:-$guess}"
            validate_root_domain "$root" || continue
        fi

        APP_HOST="$exact"
        SELECTED_ROOT_DOMAIN="$root"
        APP_RESOLVER_DOMAIN="$root"

        # 推导出的根域名登记进池，供后续应用直接匹配
        seen=""
        for d in $ROOT_DOMAINS; do [ "$d" = "$root" ] && seen=1; done
        if [ -z "$seen" ]; then
            save_global_root_domains $ROOT_DOMAINS "$root" || return 1
        fi

        printf "✅ 访问域名: https://%s（根域名: %s）\n" "$APP_HOST" "$root"
        return 0
    done
}

# 应用证书信息总入口：确认 traefik 已安装 → 输入完整域名 → 按根域名匹配
# 证书签发渠道（无匹配时询问是否新增）
# 结果: APP_HOST / CERT_MAIN / CERT_SANS / APP_RESOLVER_DOMAIN /
#       APP_RESOLVER / RESOLVER_ADDED
#       （非委派渠道下，该根域名已有泛域名证书时提示是否复用，结果写入 CERT_MAIN/SANS）
setup_app_certificate() {
    if [ -z "$TRAEFIK_HOME" ] || [ ! -f "$TRAEFIK_HOME/traefik.toml" ]; then
        printf "❌ 尚未安装 traefik（%s 中无 TRAEFIK_HOME 或未找到其配置）。\n" "$INSTALLER_CONF"
        printf "   请先执行: bash run.sh install traefik\n"
        return 1
    fi
    RESOLVER_ADDED=0
    choose_cert_source || return 1

    list_traefik_resolvers || { printf "ℹ️  尚无证书签发渠道，本次将引导新增。\n"; RESOLVER_POOL=(); }
    choose_app_domain || return 1

    if [ "$CERT_MODE" = static ]; then
        # 静态路线：不绑签发渠道、不下发域名声明；空的 tls.domains 标签由
        # strip_empty_cert_domain_labels 删除（否则 ACME 会报 no domain was given），
        # TLS 握手按 SNI 命中 [[tls.certificates]] 预置证书
        APP_RESOLVER=""
        CERT_MAIN=""
        CERT_SANS=""
        printf "✅ 使用静态证书：请确认 traefik 预置证书的 SAN 覆盖 %s，否则将回退自签默认证书。\n" "$APP_HOST"
        return 0
    fi
    # 按根域名过滤证书签发渠道
    choose_or_add_resolver "$APP_RESOLVER_DOMAIN" || return 1

    # CNAME 委派渠道：根级 CNAME 只覆盖 _acme-challenge.<根域名>，
    # 因此改签泛域名证书（*.root + root），一次委派覆盖所有一级子域名
    if [ -n "$APP_RESOLVER" ] && resolver_cname_target "$APP_RESOLVER" >/dev/null 2>&1; then
        if ! app_domain_covered_by_wildcard "$APP_HOST" "$SELECTED_ROOT_DOMAIN"; then
            printf "❌ 委派渠道 %s 按根域名签发泛域名证书（*.%s），\n" "$APP_RESOLVER" "$SELECTED_ROOT_DOMAIN"
            printf "   无法覆盖 %s（超过一级子域名）。\n" "$APP_HOST"
            printf "   请改用一级子域名（如 app.%s），或为该完整域名单独配置 CNAME 后使用静态证书。\n" "$SELECTED_ROOT_DOMAIN"
            return 1
        fi
        CERT_MAIN="*.${SELECTED_ROOT_DOMAIN}"
        CERT_SANS="${SELECTED_ROOT_DOMAIN}"
        printf "✅ 委派渠道将签发泛域名证书: %s（SAN: %s）\n" "$CERT_MAIN" "$CERT_SANS"
    else
        # 非委派渠道：由用户选择精确域名证书或泛域名证书
        choose_cert_domain_mode "$APP_HOST" "$SELECTED_ROOT_DOMAIN" || return 1
    fi
    return 0
}

# 精确域名/静态证书模式下删除空的 tls.domains 标签。
# Traefik 只要存在 tls.domains 条目就会使用它，不会回退到 router 的 Host()
# 规则；main 为空时 ACME 会报 "no domain was given"。
# 参数: $1=compose 文件；依据全局 CERT_MAIN / CERT_SANS 决定是否删除
strip_empty_cert_domain_labels() {
    local compose_file="$1"
    [ -f "$compose_file" ] || return 0
    [ -n "${CERT_MAIN:-}" ] || sed -i '/\.tls\.domains\[0\]\.main=/d' "$compose_file"
    [ -n "${CERT_SANS:-}" ] || sed -i '/\.tls\.domains\[0\]\.sans=/d' "$compose_file"
    return 0
}

# 选择证书域名模式（精确域名 / 泛域名）
# 已有该根域名的泛域名证书时，提示是否复用；否则提示精确/泛域名二选一。
# 参数: $1=用于覆盖校验的域名 $2=根域名 $3=精确模式提示文案（可选）
# 结果: CERT_MAIN / CERT_SANS（空=精确域名；*.根域名 + 根域名=泛域名）
choose_cert_domain_mode() {
    local host="$1" root="$2" exact_label="${3:-$1}" choice
    CERT_MAIN=""
    CERT_SANS=""

    # 泛域名只覆盖根域名及其一级子域；不覆盖时不提供无效选项
    if ! app_domain_covered_by_wildcard "$host" "$root"; then
        printf "ℹ️  %s 超过 *.%s 的覆盖范围，将使用精确域名证书。\n" "$host" "$root"
        return 0
    fi

    if root_has_wildcard_cert "$root"; then
        printf "==========================================\n"
        printf "🗂️  检测到根域名 %s 已有泛域名证书\n" "$root"
        printf "==========================================\n"
        printf "  1) 使用泛域名证书    (*.%s)\n" "$root"
        printf "  2) 使用精确域名证书  (%s)\n" "$exact_label"
        printf "请选择 (1/2) [2]: "
        read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        case "${choice:-2}" in
            1) : ;;
            2) printf "✅ 将使用精确域名证书: %s\n" "$exact_label"; return 0 ;;
            *) printf "❌ 无效输入 '%s'，请输入 1 或 2。\n" "$choice"; return 1 ;;
        esac
    else
        printf "==========================================\n"
        printf "📜 请选择证书申请方式\n"
        printf "==========================================\n"
        printf "  1) 自动申请精确域名证书 (%s)\n" "$exact_label"
        printf "  2) 自动申请泛域名证书   (*.%s)\n" "$root"
        printf "请选择 (1/2) [1]: "
        read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        case "${choice:-1}" in
            1) printf "✅ 将申请精确域名证书: %s\n" "$exact_label"; return 0 ;;
            2) : ;;
            *) printf "❌ 无效输入 '%s'，请输入 1 或 2。\n" "$choice"; return 1 ;;
        esac
    fi

    CERT_MAIN="*.${root}"
    CERT_SANS="${root}"
    printf "✅ 将使用泛域名证书: %s（SAN: %s）\n" "$CERT_MAIN" "$CERT_SANS"
    return 0
}

# 证书方式选择：ACME 自动签发（resolver）或 静态证书（SNI 匹配已预置证书）
# 参数: $1 = 可选对象名（如 "Traefik Dashboard"），默认"应用"
# 结果: CERT_MODE=auto|static
choose_cert_source() {
    local target="${1:-应用}" choice e
    printf "==========================================\n"
    printf "📜 请选择%s的证书方式\n" "$target"
    printf "==========================================\n"
    printf "  1) 自动签发（ACME DNS-01，从证书签发渠道选择/新增）\n"
    printf "  2) 静态证书（使用 traefik 已预置证书，按 SNI 匹配）\n"
    if list_static_certs; then
        printf "   现有静态证书:\n"
        for e in "${STATIC_CERTS[@]}"; do
            printf "     - %s（domains: %s，到期 %s）\n" "${e%%|*}" "$(printf '%s' "$e" | cut -d'|' -f2)" "$(printf '%s' "$e" | cut -d'|' -f3)"
        done
    fi
    printf "请输入序号 (1/2) [1]: "
    read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
    case "${choice:-1}" in
        1) CERT_MODE="auto" ;;
        2) CERT_MODE="static" ;;
        *) printf "❌ 无效输入 '%s'。\n" "$choice"; return 1 ;;
    esac
    return 0
}

# 3.6 选择 DNS 服务商（DNS-01 验证用；与凭据收集分离，
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
