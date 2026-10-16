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
bash run.sh configure traefik     # 配置维护：traefik 新增 DNS resolver（app/traefik/configure.sh）
```

服务根目录在**首次运行时交互指定**（默认 `$HOME/service`），记录在项目根目录的
`.installer.conf` 中；之后运行自动复用、不再询问。

- 更换服务根目录：编辑或删除 `.installer.conf` 后重新运行。

## 域名与证书机制

ACME 统一走 **DNS-01**，resolver 池只包含 DNS resolver。两层职责分离：

- **resolver 池（静态）**：traefik 安装时收集 ACME 邮箱与 CA 环境，并**可选**
  立即配置 DNS resolver（也可跳过，之后补配）。resolver 以
  **`根域名@提供商`** 命名（如 `example.com@aliyun`），每个"根域名+提供商"
  一个，独立证书存储 `letsencrypt/acme-<resolver>.json`（官方禁止共用）。
  Dashboard 配置时会**绑定一个 resolver** 签发其域名证书（可选择跳过=自签兜底）。
  新增 resolver 途径：

  ```bash
  bash run.sh configure traefik   # 追加 DNS resolver，完成后重启 traefik
  ```

  应用安装时若目标根域名尚无对应 resolver，会经菜单调用同一新增流程。

- **域名声明（动态，随应用走）**：业务应用（airpress、filebrowser 等）安装时
  选择两种域名形态之一，写入应用自己的 compose labels，启动即自动触发签发
  （file provider 热加载，**无需重启 traefik**）：
  1. **通配模式**：从根域名池选择/新增根域名 + 二级域名（默认服务名），
     声明 `*.根域名`，通配证书多应用共享；根域名池持久化在 `.installer.conf`
     （`ROOT_DOMAINS="a.com b.com"`）；resolver 菜单只显示该根域名下的
     `根域名@提供商` 项；
  2. **精确域名模式**：直接输入完整域名（任意 TLD），列出全部 resolver 供选择
     （须自行确认所选提供商托管该域名的 DNS），DNS-01 签发单域名证书。

- 应用内新增 resolver 会修改 traefik 静态配置，应用安装结束时提示重启 traefik；
- 尚未安装 traefik 时应用安装会报错并要求先 `bash run.sh install traefik`；
- Dashboard 域名由第一个可用 resolver 自动签发精确证书，池为空期间临时自签。
