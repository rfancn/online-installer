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
bash run.sh configure traefik     # 配置维护：证书来源（签发渠道/静态证书/CA 环境）
```

服务根目录在**首次运行时交互指定**（默认 `$HOME/service`），记录在项目根目录的
`.installer.conf` 中；之后运行自动复用、不再询问。

- 更换服务根目录：编辑或删除 `.installer.conf` 后重新运行。

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

  `configure` 菜单支持：新增证书签发渠道、新增静态证书、在 Let's Encrypt
  生产/测试（staging）环境之间切换。切换环境会改写全部渠道的 `caServer`，
  并备份清空对应证书存储，重启后按新环境重新签发。

  应用安装时若目标根域名尚无对应证书签发渠道，会经菜单调用同一新增流程。

- **静态证书（与 ACME 并存）**：`bash run.sh configure traefik` 菜单选"新增静态
  证书"，提供 fullchain/privkey 绝对路径——安装器用 openssl 校验证书格式、
  密钥配对并解析 SAN/有效期，落盘 `certs/<id>/` 并在 traefik.toml 追加
  `[[tls.certificates]]`（按 SNI 匹配，id=证书首个域名，同 id 重加即覆盖续期）。
  注意：与证书签发渠道同属**静态配置，变更后需重启 traefik**；静态证书不会自动续签，
  到期前重跑该流程替换即可。应用安装时证书方式选"静态证书"，则
  Traefik 的 `certResolver`/通配声明置空（labels 空值被忽略），握手命中预置证书。

- **域名声明（动态，随应用走）**：业务应用（airpress、filebrowser 等）安装时
  直接输入应用完整域名，写入应用自己的 compose labels，启动即自动触发签发
  （file provider 热加载，**无需重启 traefik**）：
  - 脚本按域名匹配根域名池中的最长后缀确定所属根域名
    （`ROOT_DOMAINS="a.com b.com"`，持久化在 `.installer.conf`）；未命中时
    询问确认，默认取最后两段；
  - 按根域名匹配证书签发渠道（如 `example.com@aliyun`）；找不到匹配渠道时
    询问是否新增；
  - 证书按应用实际域名签发（单域名证书），不再声明泛域名。

- 应用内新增证书签发渠道会修改 traefik 静态配置，应用安装结束时提示重启 traefik；
- 尚未安装 traefik 时应用安装会报错并要求先 `bash run.sh install traefik`；
- Dashboard 在 ACME 模式下由所选证书签发渠道签发精确证书（可跳过：自签兜底），
  静态证书模式按 SNI 匹配；访问域名默认从根域名池推导。
