#!/bin/bash

# ================= app/traefik/configure.sh =================
# traefik 运维脚本：管理证书来源
# （新增 DNS resolver、切换主账号、静态证书，或切换 Let's Encrypt 生产/测试环境）。
# 证书签发渠道命名 <根域名>@<DNS服务商>（如 example.com@aliyun）；
# 业务应用安装时可复用同一流程。
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
    printf "🔐 证书签发渠道（自动签发）:\n"
    for entry in "${RESOLVER_POOL[@]}"; do
        cname=$(resolver_cname_target "${entry%%|*}" 2>/dev/null || true)
        if [ -n "$cname" ]; then
            printf "   - %s（provider: %s，CNAME 委派 → %s）\n" "${entry%%|*}" "${entry##*|}" "$cname"
        else
            printf "   - %s（provider: %s）\n" "${entry%%|*}" "${entry##*|}"
        fi
    done
else
    printf "🔐 证书签发渠道为空\n"
fi
if list_static_certs; then
    printf "📜 静态证书池（SNI 匹配）:\n"
    for e in "${STATIC_CERTS[@]}"; do
        printf "   - %s（domains: %s，到期 %s）\n" "${e%%|*}" "$(printf '%s' "$e" | cut -d'|' -f2)" "$(printf '%s' "$e" | cut -d'|' -f3)"
    done
else
    printf "📜 静态证书池为空\n"
fi
printf "==========================================\n"

configure_traefik_menu || exit 1

if [ "${RESOLVER_ADDED:-0}" = 1 ] || [ "${STATIC_ADDED:-0}" = 1 ] || [ "${CA_CHANGED:-0}" = 1 ]; then
    printf -- "----------------------------------------\n"
    printf "✅ 证书配置已更新（证书签发渠道: %s / 静态证书: %s / CA 环境: %s）\n" \
        "$([ "${RESOLVER_ADDED:-0}" = 1 ] && printf '已增' || printf '无新增')" \
        "$([ "${STATIC_ADDED:-0}" = 1 ] && printf '已增' || printf '无新增')" \
        "$([ "${CA_CHANGED:-0}" = 1 ] && printf '已切换' || printf '无变更')"
    # 主账号切换会改写 .env，由下方提示重建容器（重建同样覆盖静态配置变更）
    if [ "${PRIMARY_SWITCHED:-0}" != 1 ]; then
        printf "⚠️  均为静态配置变更，需重启生效：cd %s && docker compose restart\n" "$TRAEFIK_HOME"
    fi
fi

if [ "${PRIMARY_SWITCHED:-0}" = 1 ]; then
    printf -- "----------------------------------------\n"
    printf "✅ 主账号已切换。凭据变更需重建容器才会生效：\n"
    printf "   cd %s && docker compose up -d --force-recreate\n" "$TRAEFIK_HOME"
    printf "⚠️  请先按上面的提示完成各渠道的 CNAME 调整。\n"
fi
exit 0
