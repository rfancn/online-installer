#!/bin/sh
# ================= run.sh —— 项目统一入口 =================
# 职责仅为：动作/参数解析、服务发现、exec 转发到 app/<服务名>/<动作>.sh
#   install   → app/<名>/install.sh    安装服务
#   configure → app/<名>/configure.sh  配置维护（如 traefik 新增 DNS resolver）
# 缺服务名时以编号选项交互选择；公共库加载等仍由各服务脚本完成。
# 本入口保持 POSIX sh 兼容（可直接 sh run.sh），子脚本仍以 bash 执行。

APP_ROOT="$(cd "$(dirname "$0")" && pwd)/app"

usage() {
    printf "用法: sh run.sh <动作> [服务名] [额外参数...]\n\n"
    printf "  install   [服务名]   安装 app/<服务名>（缺服务名则选项选择）\n"
    printf "  configure [服务名]   配置维护 app/<服务名>/configure.sh（缺则选项选择）\n"
    printf "  list                 列出可用服务及其支持的动作\n"
    printf "  (无参数)             选项选择动作与服务\n"
    printf "  -h, --help           显示本帮助\n"
}

# 服务是否支持某动作
supports() { [ -f "$APP_ROOT/$1/$2.sh" ]; }

list_services() {
    found=0
    for dir in "$APP_ROOT"/*/; do
        name=$(basename "$dir")
        acts=""
        supports "$name" install   && acts="install"
        supports "$name" configure && acts="$acts configure"
        [ -n "$acts" ] || continue
        printf "  %-14s %s\n" "$name" "($acts)"
        found=1
    done
    [ "$found" -eq 1 ] || printf "  (未找到可用服务: %s/)\n" "$APP_ROOT"
}

run_action() {
    act="$1"
    name="$2"
    shift 2
    script="${APP_ROOT}/${name}/${act}.sh"
    if [ ! -f "$script" ]; then
        printf "❌ 服务 '%s' 不支持 %s（未找到 app/%s/%s.sh）。\n" "$name" "$act" "$name" "$act"
        printf "   支持 %s 的服务: " "$act"
        found=0
        for dir in "$APP_ROOT"/*/; do
            n=$(basename "$dir")
            supports "$n" "$act" || continue
            printf "%s " "$n"
            found=1
        done
        [ "$found" -eq 1 ] || printf "（无）"
        printf "\n"
        exit 1
    fi
    # exec：入口进程被子脚本替换，退出码与 Ctrl+C 信号直达
    exec bash "$script" "$@"
}

# 编号交互选择支持该动作的服务
choose_service() {
    action="$1"
    # 服务名来自目录名，不含空白，用空格分隔的字符串代替 bash 数组
    names=""
    count=0
    for dir in "$APP_ROOT"/*/; do
        n=$(basename "$dir")
        if supports "$n" "$action"; then
            names="$names $n"
            count=$((count + 1))
        fi
    done
    if [ "$count" -eq 0 ]; then
        printf "❌ 没有服务支持 %s。\n" "$action"
        exit 1
    fi
    names=${names# }

    printf "==========================================\n"
    printf "📦 %s —— 可选服务:\n" "$action"
    printf "==========================================\n"
    i=0
    for n in $names; do
        printf "  %d) %s\n" "$((i + 1))" "$n"
        i=$((i + 1))
    done

    while true; do
        printf "请选择服务序号 (1-%d): " "$count"
        read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        case "$choice" in
            ''|*[!0-9]*) printf "❌ 无效输入 '%s'，请输入数字序号。\n" "$choice"; continue ;;
        esac
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            i=0
            for n in $names; do
                i=$((i + 1))
                if [ "$i" -eq "$choice" ]; then
                    run_action "$action" "$n"
                fi
            done
        fi
        printf "❌ 序号 '%s' 超出范围 (1-%d)，请重新输入。\n" "$choice" "$count"
    done
}

# 无参数：先选动作再选服务
choose_action() {
    printf "==========================================\n"
    printf "🛠  online-installer —— 请选择操作:\n"
    printf "==========================================\n"
    printf "  1) 安装服务\n"
    printf "  2) 配置维护\n"
    printf "  3) 列出可用服务\n"
    while true; do
        printf "请输入序号 (1/2/3) [1]: "
        read -r choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        case "${choice:-1}" in
            1) choose_service install ;;
            2) choose_service configure ;;
            3) list_services; exit 0 ;;
            *) printf "❌ 无效输入 '%s'。\n" "$choice" ;;
        esac
    done
}

case "${1:-}" in
    -h|--help) usage ;;
    list)      list_services ;;
    '')        choose_action ;;
    install|configure)
        action="$1"; shift
        if [ $# -ge 1 ]; then
            run_action "$action" "$@"
        else
            choose_service "$action"
        fi
        ;;
    *)
        printf "❌ 未知命令 '%s'。\n" "$1"
        usage
        exit 1
        ;;
esac