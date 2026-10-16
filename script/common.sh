#!/bin/sh
# ================= script/common.sh =================

# 定义全局共享网络名称
TRAEFIK_NETWORK="web"

# 本库位于 <项目根>/script/ 下，据此定位配置文件（被 source 时用 BASH_SOURCE 取自身路径）
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"
INSTALLER_CONF="${PROJECT_ROOT}/.installer.conf"

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
        read -r input_base
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
        read -r confirm
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
            read -r custom_name
            
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
            # 交互式指定管理员账户（回车默认 root；root 锁定时可输入其他管理员账户）
            # 在探测阶段读一次并缓存，避免 apt update+install 链重复询问
            printf "请输入管理员账户名 [root]: "
            read -r PKG_SU_ADMIN
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
