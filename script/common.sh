#!/bin/sh
# ================= script/common.sh =================

SERVICE_BASE="/root/service"
# 定义全局共享网络名称
TRAEFIK_NETWORK="web"

# 1. 加载公共库的快捷函数
load_common() {
    # 使用标准的 $0 获取脚本路径
    SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

    # 自动获取上级目录名作为默认安装名
    INSTALL_NAME=$(basename "$(cd "$SCRIPT_DIR" && pwd)")

    # 在加载公共库时，自动调用网络初始化函数
    init_docker_network || return 1
}


# 1. 初始化 Docker 全局网络的函数
init_docker_network() {
    # 使用 docker network inspect 检查网络是否存在
    if ! docker network inspect "$TRAEFIK_NETWORK" >/dev/null 2>&1; then
        printf "⚠️  未检测到 Docker 网络 '%s'，正在自动创建...\n" "$TRAEFIK_NETWORK"
        docker network create "$TRAEFIK_NETWORK" >/dev/null 2>&1

        # 检查创建命令是否执行成功
        if [ $? -eq 0 ]; then
            printf "✅ 网络 '%s' 创建成功！\n" "$TRAEFIK_NETWORK"
        else
            printf "❌ 网络 '%s' 创建失败，请检查 Docker 服务状态！\n" "$TRAEFIK_NETWORK"
            return 1
        fi
    else
        printf "✅ 检测到 Docker 网络 '%s' 已存在。\n" "$TRAEFIK_NETWORK"
    fi
    return 0
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
