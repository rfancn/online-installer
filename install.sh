#!/bin/bash
# ================= install.sh — 项目统一安装入口 =================
# 职责仅为：参数解析、服务发现、exec 转发到 app/<服务名>/install.sh
# 公共库加载、服务根目录解析、Docker 网络初始化等仍由各服务脚本完成

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="${SCRIPT_DIR}/app"

usage() {
    printf "用法: bash install.sh [<服务名>] [额外参数...]\n\n"
    printf "  <服务名>    安装 app/<服务名>/install.sh，额外参数原样透传\n"
    printf "  (无参数)    列出可用服务并交互选择\n"
    printf "  list        仅列出可用服务\n"
    printf "  -h, --help  显示本帮助\n"
}

# 服务自动发现：扫描 app/*/install.sh，无 install.sh 的子目录忽略
list_services() {
    local found=0 dir
    for dir in "$APP_ROOT"/*/; do
        [ -f "${dir}install.sh" ] || continue
        printf "  %s\n" "$(basename "$dir")"
        found=1
    done
    if [ "$found" -eq 0 ]; then
        printf "  (未找到可安装的服务: %s/ 下没有含 install.sh 的子目录)\n" "$APP_ROOT"
    fi
}

run_service() {
    local name="$1"
    shift
    local script="${APP_ROOT}/${name}/install.sh"
    if [ ! -f "$script" ]; then
        printf "❌ 未知服务 '%s'，可用服务:\n" "$name"
        list_services
        exit 1
    fi
    # exec：入口进程被子脚本替换，退出码与 Ctrl+C 信号直达子脚本（trap 行为不受影响）
    exec bash "$script" "$@"
}

# 无参数时交互选择：编号列表 + 输入校验（风格同 init_service）
choose_service() {
    local names=() dir n choice
    for dir in "$APP_ROOT"/*/; do
        [ -f "${dir}install.sh" ] || continue
        names+=("$(basename "$dir")")
    done
    if [ ${#names[@]} -eq 0 ]; then
        printf "❌ %s/ 下未找到可安装的服务。\n" "$APP_ROOT"
        exit 1
    fi

    printf "==========================================\n"
    printf "📦 可用服务:\n"
    printf "==========================================\n"
    for n in "${!names[@]}"; do
        printf "  %d) %s\n" "$((n + 1))" "${names[$n]}"
    done

    while true; do
        printf "请输入要安装的服务编号: "
        read -r choice
        case "$choice" in
            ''|*[!0-9]*)
                printf "❌ 无效输入 '%s'，请输入数字序号。\n" "$choice"
                continue
                ;;
        esac
        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ]; then
            run_service "${names[$((choice - 1))]}"
        fi
        printf "❌ 序号 '%s' 超出范围 (1-%d)，请重新输入。\n" "$choice" "${#names[@]}"
    done
}

case "${1:-}" in
    -h|--help) usage ;;
    list)      list_services ;;
    '')        choose_service ;;
    *)         run_service "$@" ;;
esac
