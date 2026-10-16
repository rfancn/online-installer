#!/bin/bash

# 1. 引入公共库并初始化（load_common 内部完成：定位项目根、读取/指定服务根目录、创建 Docker 网络）
# 使用标准的 $0 获取当前脚本的真实绝对路径
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
# 统一入口 install.sh 可能从任意目录调起；切到脚本所在目录，
# 使 resource/ 等相对路径在任何 cwd 下都有效
cd "$SCRIPT_PATH" || exit 1
COMMON_SCRIPT="${SCRIPT_PATH}/../../script/common.sh"

[ -f "$COMMON_SCRIPT" ] || { printf "❌ 致命错误: 找不到公共库 %s\n" "$COMMON_SCRIPT"; exit 1; }
. "$COMMON_SCRIPT"
load_common || exit 1

# 读取密码时会关闭终端回显，退出或中断时确保恢复，避免终端留在"盲打"状态
# 注意：trap 接管信号后默认的中止动作不再执行，handler 必须自行 exit，
# 否则 Ctrl+C 只会恢复 echo，脚本继续跑、无法中断（INT 惯例退出码 130，TERM 为 143）
trap 'stty echo 2>/dev/null' EXIT
trap 'stty echo 2>/dev/null; exit 130' INT
trap 'stty echo 2>/dev/null; exit 143' TERM


# 2. 执行初始化（直接生成 $INSTALL_DIR 和 $SERVICE_NAME）
init_service || exit 1

echo "🚀 开始将服务安装到: $SERVICE_DIR"


# ============ 3. 收集根域名（用于签发泛域名证书，保存到全局供各应用复用） ============
printf "==========================================\n"
printf "🌐 请配置根域名\n"
printf "==========================================\n"
printf "（将签发 *.域名 泛域名证书，证书同时覆盖域名本身）\n"
while true; do
    # 全局配置已有根域名（重装/追加场景）时作为默认值
    saved_hint=""
    [ -n "$ROOT_DOMAIN" ] && saved_hint="（已配置: ${ROOT_DOMAIN}，回车沿用）"
    printf "请输入根域名 %s（如 example.com）: " "$saved_hint"
    read -r input_domain
    [ -n "$input_domain" ] && ROOT_DOMAIN="$input_domain"
    case "$ROOT_DOMAIN" in
        ''|*[\"\'\ \`\$\*]*)
            printf "❌ 域名不能为空，且不能包含空格、引号、反引号、\$ 与 *。\n"
            continue
            ;;
    esac
    break
done
WILDCARD_DOMAIN="*.${ROOT_DOMAIN}"
# 持久化到 .installer.conf：业务应用安装时据此推导访问域名，不再询问根域名
save_global_root_domain || printf "⚠️  根域名保存失败，后续应用安装将无法自动推导域名。\n"


# ============ 4. 收集证书通知邮箱 ============
printf "==========================================\n"
printf "📧 请配置证书通知邮箱\n"
printf "==========================================\n"
printf "（Let's Encrypt 用它发送证书到期与异常提醒）\n"
while true; do
    printf "请输入邮箱: "
    read -r ACME_EMAIL
    case "$ACME_EMAIL" in
        '')     printf "❌ 邮箱不能为空。\n"; continue ;;
        *[\"\'\ \`\$]*) printf "❌ 邮箱不能包含空格、引号、反引号与 \$。\n"; continue ;;
        *@*)    break ;;
        *)      printf "❌ 邮箱格式不正确（缺少 @）。\n"; continue ;;
    esac
done


# ============ 5. 选择 Let's Encrypt 环境 ============
printf "==========================================\n"
printf "🧪 请选择 Let's Encrypt 环境\n"
printf "==========================================\n"
printf "  1) 生产  (正式证书，浏览器信任，有速率限制)\n"
printf "  2) 测试  (staging，不受速率限制，浏览器不信任)\n"
printf "请输入序号 (1/2) [1]: "
read -r CA_CHOICE
case "$CA_CHOICE" in
    2)
        ACME_CA_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
        printf "⚠️  已选择测试环境：证书不被浏览器信任，仅用于验证流程。\n"
        ;;
    *)
        ACME_CA_SERVER="https://acme-v02.api.letsencrypt.org/directory"
        ;;
esac


# ============ 6. 选择 DNS 服务商并收集 API 凭据 ============
# 泛域名证书只能用 DNS-01 验证，lego 通过环境变量读取各厂商凭据
printf "==========================================\n"
printf "☁️  请选择 DNS 服务商\n"
printf "==========================================\n"
printf "  1) 阿里云 AliDNS     (alidns)\n"
printf "  2) 腾讯云 DNSPod     (tencentcloud)\n"
printf "  3) Cloudflare        (cloudflare)\n"
printf "请输入序号 (1/2/3) [1]: "
read -r DNS_CHOICE

case "${DNS_CHOICE:-1}" in
    1)
        DNS_PROVIDER="alidns"
        printf "\n请输入阿里云 AccessKey ID: "
        read -r DNS_KEY_ID
        printf "请输入阿里云 AccessKey Secret (输入时不可见): "
        stty -echo
        read -r DNS_KEY_SECRET
        stty echo
        printf "\n"
        DNS_ENV_NAMES=("ALICLOUD_ACCESS_KEY" "ALICLOUD_SECRET_KEY")
        DNS_ENV_VALUES=("$DNS_KEY_ID" "$DNS_KEY_SECRET")
        ;;
    2)
        DNS_PROVIDER="tencentcloud"
        printf "\n请输入腾讯云 SecretId: "
        read -r DNS_KEY_ID
        printf "请输入腾讯云 SecretKey (输入时不可见): "
        stty -echo
        read -r DNS_KEY_SECRET
        stty echo
        printf "\n"
        DNS_ENV_NAMES=("TENCENTCLOUD_SECRET_ID" "TENCENTCLOUD_SECRET_KEY")
        DNS_ENV_VALUES=("$DNS_KEY_ID" "$DNS_KEY_SECRET")
        ;;
    3)
        DNS_PROVIDER="cloudflare"
        printf "\n请输入 Cloudflare API Token (需 Zone:DNS 编辑权限，输入时不可见): "
        stty -echo
        read -r DNS_API_TOKEN
        stty echo
        printf "\n"
        DNS_ENV_NAMES=("CF_DNS_API_TOKEN")
        DNS_ENV_VALUES=("$DNS_API_TOKEN")
        ;;
    *)
        printf "❌ 无效输入 '%s'，仅支持 1/2/3。\n" "$DNS_CHOICE"
        exit 1
        ;;
esac

# 凭据只经 .env 传给容器，内容出现空格或引号会破坏 .env 解析
for value in "${DNS_ENV_VALUES[@]}"; do
    case "$value" in
        ''|*[\"\'\ \`\$]*)
            printf "❌ API 凭据不能为空，且不能包含空格、引号、反引号与 \$。\n"
            exit 1
            ;;
    esac
done

# ============ 7. 安装配置文件到服务目录 ============
CONFIG_DIR="${SERVICE_DIR}/config"
mkdir -p "${CONFIG_DIR}"

# 静态主配置（含 Let's Encrypt 证书解析器）
STATIC_CONFIG_FILE="$SERVICE_DIR/traefik.toml"
cp resource/traefik.toml "$STATIC_CONFIG_FILE"

# 动态配置（dashboard 路由及其泛域名证书声明）
cp resource/config/* "${CONFIG_DIR}/"

# 安装 docker-compose.yml
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
cp resource/docker-compose.yml "$COMPOSE_FILE"


# ============ 8. 生成 .env（DNS 凭据，容器启动时注入） ============
ENV_FILE="$SERVICE_DIR/.env"
{
    printf "# Traefik 容器环境变量：DNS 服务商 API 凭据\n"
    printf "# lego 通过环境变量读取，用于 Let's Encrypt DNS-01 验证\n"
    printf "ACME_DNS_PROVIDER=%s\n" "$DNS_PROVIDER"
    for i in "${!DNS_ENV_NAMES[@]}"; do
        printf "%s=%s\n" "${DNS_ENV_NAMES[$i]}" "${DNS_ENV_VALUES[$i]}"
    done
} > "$ENV_FILE"
# 凭据为明文，只有宿主机上的 docker compose 需要读它
chmod 600 "$ENV_FILE"


# ============ 9. 准备 ACME 证书存储 ============
# Traefik 拒绝加载权限过宽的 acme.json，必须先建好并收紧权限
LETSENCRYPT_DIR="$SERVICE_DIR/letsencrypt"
mkdir -p "${LETSENCRYPT_DIR}"
touch "${LETSENCRYPT_DIR}/acme.json"
chmod 600 "${LETSENCRYPT_DIR}/acme.json"


# ============ 10. 配置 Dashboard 域名与访问凭证 ============
printf "==========================================\n"
printf "🔐 请配置 Traefik Dashboard\n"
printf "==========================================\n"
printf "请输入 Dashboard 访问域名 [traefik.%s]: " "$ROOT_DOMAIN"
read -r DASHBOARD_DOMAIN
DASHBOARD_DOMAIN=${DASHBOARD_DOMAIN:-traefik.${ROOT_DOMAIN}}

# 确保 htpasswd 可用（缺失时经包管理器自动安装，覆盖主流发行版）；
# 安装失败必须中止，否则空哈希会静默写进 dashboard 认证配置
ensure_htpasswd || {
    printf "❌ htpasswd 不可用且自动安装失败，请手动安装后重试\n"
    printf "   （Debian/Ubuntu: apache2-utils | RHEL/CentOS/Fedora: httpd-tools | Alpine/openSUSE: apache2-utils | Arch: apache2）\n"
    exit 1
}

# 注意：这里的用户名/密码是 Traefik Dashboard 网页的登录凭证，
# 与安装提权用的系统管理员账户无关
printf "请输入 Dashboard 登录用户名（仅用于登录 Traefik Dashboard 网页，非系统管理员）: "
read -r DASHBOARD_USER

printf "请输入 Dashboard 登录密码 (输入时不可见): "
stty -echo  # 隐藏密码输入
read -r DASHBOARD_PASS
stty echo   # 恢复显示
printf "\n"  # 换行，保持输出美观

# 生成密码哈希：-nB 表示在标准输出显示并使用 bcrypt 加密（Traefik 推荐）
HASH=$(htpasswd -nbB "$DASHBOARD_USER" "$DASHBOARD_PASS" | cut -d ":" -f 2)


# ============ 11. 替换配置占位符 ============
# 静态配置：ACME 邮箱、CA 地址、DNS 服务商
sed -i "s|__ACME_EMAIL__|$(sed_escape "$ACME_EMAIL")|g" "$STATIC_CONFIG_FILE"
sed -i "s|__ACME_CA_SERVER__|$(sed_escape "$ACME_CA_SERVER")|g" "$STATIC_CONFIG_FILE"
sed -i "s|__ACME_DNS_PROVIDER__|$(sed_escape "$DNS_PROVIDER")|g" "$STATIC_CONFIG_FILE"

DASHBOARD_CONFIG_FILE="${CONFIG_DIR}/dashboard.toml"
sed -i "s|__DASH_BOARD_DOMAIN__|$(sed_escape "$DASHBOARD_DOMAIN")|g" "$DASHBOARD_CONFIG_FILE"
sed -i "s|__DASH_BOARD_CREDENTIAL__|$(sed_escape "${DASHBOARD_USER}:${HASH}")|g" "$DASHBOARD_CONFIG_FILE"
sed -i "s|__ACME_MAIN_DOMAIN__|$(sed_escape "$WILDCARD_DOMAIN")|g" "$DASHBOARD_CONFIG_FILE"
sed -i "s|__ACME_SANS_DOMAIN__|$(sed_escape "$ROOT_DOMAIN")|g" "$DASHBOARD_CONFIG_FILE"

printf "✅ Traefik Dashboard 认证配置已写入！\n"


# ============ 12. 放行防火墙并收尾（自动适配 ufw / firewalld） ============
open_firewall_ports 80/tcp 443/tcp

printf -- "----------------------------------------\n"
printf "签名域名:   %s（含 %s）\n" "$ROOT_DOMAIN" "$WILDCARD_DOMAIN"
printf "ACME 环境:  %s\n" "$ACME_CA_SERVER"
printf "DNS 服务商: %s\n" "$DNS_PROVIDER"
printf "Dashboard:  https://%s/dashboard/\n" "$DASHBOARD_DOMAIN"
printf -- "----------------------------------------\n"
printf "下一步：cd %s && docker compose up -d\n" "$SERVICE_DIR"
printf "⚠️  请确认 %s 与 %s 的 DNS 记录已指向本机。\n" "$WILDCARD_DOMAIN" "$DASHBOARD_DOMAIN"

echo "✅ $INSTALL_NAME 安装完成！"

