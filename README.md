# online-installer

基于 Docker 的在线服务一键安装脚本集合。

## 用法

在项目根目录执行统一入口 `run.sh`（动作 → 服务，均可用编号选项交互选择）：

```bash
bash run.sh                       # 不带参数：依次选择动作与服务
bash run.sh list                  # 列出可用服务及其支持的动作
bash run.sh install               # 安装：交互选择服务（app/<名>/install.sh）
bash run.sh install traefik       # 直接安装 app/traefik
bash run.sh install airpress      # 直接安装 app/airpress
bash run.sh install notify-bridge # 直接安装 app/notify-bridge
bash run.sh install zentao        # 直接安装 app/zentao
bash run.sh install wordpress     # 直接安装 app/wordpress
bash run.sh configure traefik     # 配置维护：证书来源（签发渠道/静态证书/CA 环境）
```

服务根目录在**首次运行时交互指定**（默认 `$HOME/service`），记录在项目根目录的
`.installer.conf` 中；之后运行自动复用、不再询问。

- 更换服务根目录：编辑或删除 `.installer.conf` 后重新运行。

## 部署方式

容器类应用（filebrowser、airpress、syncthing、notify-bridge、zentao、wordpress）安装时先选择部署方式：

- **反向代理（默认）**：应用加入共享 `web` 网络，经 Traefik 按安装时指定的
  完整域名访问，证书由 Traefik 按应用 labels 自动签发；
- **直接访问**：应用发布宿主机端口（安装时输入，回车使用默认值），通过
  `http://<本机IP>:<端口>` 访问；不依赖 Traefik，也无需预先安装它。

各应用直接访问的默认端口：filebrowser `8080`、airpress `8080`、
syncthing `8384`、notify-bridge `8080`、zentao `8080`、wordpress `8080`。

wordpress 使用官方 `wordpress:latest` 镜像，数据库二选一：随服务启动的
MySQL Community 容器（`mysql:8.0`），或连接已有外部 MySQL。

hipoint 本身是纯 Traefik 路由配置（不运行自己的容器），仅支持反向代理模式。

## 域名与证书机制

ACME 统一走 **DNS-01**，证书签发渠道池只包含 DNS-01 渠道。两层职责分离：

- **证书签发渠道池（静态）**：traefik 安装时收集 ACME 邮箱与 CA 环境（必填）。
  证书签发渠道在 Dashboard/应用配置证书时按需引导新增，或随时手动添加；
  以 **`根域名@提供商`** 命名（如 `example.com@aliyun`），应用按所属根域名
  共享同一渠道；每个"根域名+提供商"一个，独立证书存储
  `letsencrypt/acme-<渠道标识>.json`（官方禁止共用）。
  Dashboard 配置时先选证书方式：**ACME 自动签发**则绑定/跳过证书签发渠道，
  **静态证书**则按 SNI 匹配预置证书。
  新增证书签发渠道 / 切换 CA 环境途径：

  ```bash
  bash run.sh configure traefik   # 管理证书来源，完成后重启 traefik
  ```

  `configure` 菜单支持：新增证书签发渠道、切换 DNS 服务商主账号、新增静态证书、
  在 Let's Encrypt 生产/测试（staging）环境之间切换。切换环境会改写全部渠道的 `caServer`，
  并备份清空对应证书存储，重启后按新环境重新签发。

  应用安装时若目标根域名尚无对应证书签发渠道，会经菜单调用同一新增流程。

- **静态证书（与 ACME 并存）**：`bash run.sh configure traefik` 菜单选"新增静态
  证书"，提供 fullchain/privkey 绝对路径——安装器用 openssl 校验证书格式、
  密钥配对并解析 SAN/有效期，落盘 `certs/<id>/` 并在 traefik.toml 追加
  `[[tls.certificates]]`（按 SNI 匹配，id=证书首个域名，同 id 重加即覆盖续期）。
  注意：与证书签发渠道同属**静态配置，变更后需重启 traefik**；静态证书不会自动续签，
  到期前重跑该流程替换即可。应用安装时证书方式选"静态证书"，则
  Traefik 的 `certResolver`/通配声明置空；安装器会删除空的 `tls.domains`
  标签（空的 main 会让 Traefik 报 `no domain was given`，且不会回退到
  `Host()` 规则），握手按 SNI 命中预置证书。

- **域名声明（动态，随应用走）**：业务应用（airpress、filebrowser 等）安装时
  直接输入应用完整域名，写入应用自己的 compose labels，启动即自动触发签发
  （file provider 热加载，**无需重启 traefik**）：
  - 脚本按域名匹配根域名池中的最长后缀确定所属根域名
    （`ROOT_DOMAINS="a.com b.com"`，持久化在 `.installer.conf`）；未命中时
    询问确认，默认取最后两段；
  - 按根域名匹配证书签发渠道（如 `example.com@aliyun`）；找不到匹配渠道时
    询问是否新增；
  - 证书默认按应用实际域名签发（单域名证书）；以下两种情况改用泛域名：
    CNAME 委派渠道（见下）；非委派渠道下，安装器会读取
    `letsencrypt/acme-*.json` 判断该根域名是否已有泛域名证书——已有则提示
    是否复用（默认精确域名），没有则提示选择自动申请精确域名或泛域名
    （默认精确域名）。注意：Traefik 握手时会在全局 TLS store 中复用已覆盖该域名的
    证书，因此"精确域名"只影响本应用的证书域名声明，不会强制另签一张精确证书。

- 应用内新增证书签发渠道会修改 traefik 静态配置，应用安装结束时提示重启 traefik；
- 尚未安装 traefik 时应用安装会报错并要求先 `bash run.sh install traefik`；
- Dashboard 在 ACME 模式下由所选证书签发渠道签发精确证书（可跳过：自签兜底），
  静态证书模式按 SNI 匹配；访问域名默认从根域名池推导。

### 多账号：CNAME 委派

Traefik 的 DNS-01 凭据是进程级环境变量，同一个 Traefik 实例内，
同一 DNS 服务商只能配置一套账号凭据（官方说明：
[traefik#5472](https://github.com/traefik/traefik/issues/5472)）。
安装器采用官方推荐的 CNAME 委派方式支持多账号：

- 每个服务商默认以首次配置的账号为**主账号**（也可显式切换，见下）；
  凭据只写入一次 traefik 的 `.env`，同一账号下的多个根域名共用该凭据，
  resolver 仍按 `<根域名>@<服务商>` 命名（根域名与账号是 N:1 关系）。
- **显式指定主账号（不依赖添加顺序）**：
  - 新增渠道时在账号选择菜单选 `3)`，把当前根域名的账号设为新主账号；
  - 或执行 `bash run.sh configure traefik` → `4) 切换 DNS 服务商主账号`。
  切换会覆盖 `.env` 凭据、更新锚点并重算所有渠道的 CNAME 目标；
  需按提示更新 DNS，并用 `docker compose up -d --force-recreate` 重建容器。
- 新增其他账号下的根域名时，安装器会提示在**另一个账号**的 DNS 中添加 CNAME：
  `_acme-challenge.<根域名>` → `_acme-challenge.<根域名>.acme.<主账号锚点根域名>.`
- 委派渠道会为该根域名签发泛域名证书 `*.<根域名>` + `<根域名>`
  （DNS-01 支持通配符）。安装器会同时生成一个仅用于触发签发的动态路由，
  渠道配置完成后即自动申请证书，无需先安装应用。根级 CNAME 只需配置一次，
  覆盖根域名和一级子域名；应用域名必须是 `<根域名>` 或
  `<单级子域>.<根域名>`。更深层级需为该完整域名单独配置 CNAME，或改用静态证书。
- lego 会沿该 CNAME 到主账号区域创建/删除 TXT 验证记录，
  因此 Traefik 不需要保存第二套 AK/SK。
- 未委派的渠道仍按应用完整域名签发单域名证书，行为不变。
- 委派关系以注释形式记录在 `traefik.toml` 的 resolver 段前，
  `bash run.sh configure traefik` 的渠道列表会显示委派目标。
- 不要设置 `LEGO_DISABLE_CNAME_SUPPORT=true`，否则 lego 不会跟随 CNAME。

示例：`example.com`（主账号）与 `example.net`（另一账号）。
在 `example.net` 的 DNS 中添加
`_acme-challenge` CNAME `_acme-challenge.example.net.acme.example.com.`，
之后安装器为 `example.net` 创建的 `example.net@aliyun` 渠道
即可复用主账号凭据完成签发。

注意：阿里云控制台的“主机记录”填 `_acme-challenge`，不要填完整域名
`_acme-challenge.example.net`，否则会被追加成
`_acme-challenge.example.net.example.net`，导致 CNAME 查询不到。

**签发报错排查**

- `alicloud: zone <根域名> not found in AliDNS for domain _acme-challenge.<根域名>`：
  说明 lego 没有查到 CNAME，回退到直接访问该根域名区域。依次检查：
  1. `dig +short CNAME _acme-challenge.<根域名> @223.5.5.5` 是否返回委派目标；
  2. 阿里云“主机记录”是否误填了完整域名；
  3. `_acme-challenge` 下是否有旧 TXT/CNAME 记录冲突；
  4. traefik `.env` 是否设置了 `LEGO_DISABLE_CNAME_SUPPORT=true`。
- `read udp ...->1.1.1.1:53: i/o timeout`：容器到 1.1.1.1 不通。
  将 `traefik.toml` 各 resolver 的 `resolvers` 改为
  `["223.5.5.5:53", "223.6.6.6:53"]`，然后重启 traefik。

如果 `example.net` 先配置、`example.com` 后配置，不需要清空重来：
新增 `example.com` 时选择 `3) 将本根域名的账号设为主账号`，
或在 `bash run.sh configure traefik` 中选择
`4) 切换 DNS 服务商主账号`，安装器会自动重算两条渠道的 CNAME 目标。
