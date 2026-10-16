#!/bin/bash

# ================= app/traefik/configure.sh =================
# traefik 运维脚本：向 ACME resolver 池新增一个 DNS resolver
# （命名 <根域名>@<提供商>，如 sysummit.com@aliyun；业务应用安装时可复用同一流程）。
# 入口：bash run.sh configure traefik

# 使用标准的 $0 获取当前脚本的真实绝对路径
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_PATH" || exit 1
COMMON_SCRIPT="${SCRIPT_PATH}/../../script/common.sh"

[ -f "$COMMON_SCRIPT" ] || { printf "❌ 致命错误: 找不到公共库 %s\n" "$COMMON_SCRIPT"; exit 1; }
. "$COMMON_SCRIPT"
load_common || exit 1

# 凭据输入会关闭回显，退出/中断时恢复并保证 Ctrl+C 能终止
trap 'stty echo 2>/dev/null' EXIT
trap 'stty echo 2>/dev/null; exit 130' INT
trap 'stty echo 2>/dev/null; exit 143' TERM

if [ -z "$TRAEFIK_HOME" ] || [ ! -f "$TRAEFIK_HOME/traefik.toml" ]; then
    printf "❌ 尚未安装 traefik（%s 中无 TRAEFIK_HOME 或未找到其配置）。\n" "$INSTALLER_CONF"
    printf "   请先执行: bash run.sh install traefik\n"
    exit 1
fi

printf "==========================================\n"
printf "🔧 Traefik: %s\n" "$TRAEFIK_HOME"
if list_traefik_resolvers; then
    printf "🔐 当前 resolver 池:\n"
    for entry in "${RESOLVER_POOL[@]}"; do
        printf "   - %s（provider: %s）\n" "${entry%%|*}" "${entry##*|}"
    done
else
    printf "🔐 resolver 池为空\n"
fi
printf "==========================================\n"

add_dns_resolver || exit 1

if [ "${RESOLVER_ADDED:-0}" = 1 ]; then
    printf -- "----------------------------------------\n"
    printf "✅ resolver %s 已写入 %s/traefik.toml\n" "$APP_RESOLVER" "$TRAEFIK_HOME"
    printf "⚠️  静态配置变更需重启生效：cd %s && docker compose restart\n" "$TRAEFIK_HOME"
fi
exit 0
