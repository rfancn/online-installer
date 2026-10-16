# online-installer

基于 Docker 的在线服务一键安装脚本集合。

## 用法

在项目根目录执行统一入口 `install.sh`：

```bash
bash install.sh              # 不带参数：列出可用服务并交互选择
bash install.sh list         # 仅列出可用服务
bash install.sh traefik      # 安装 app/traefik
bash install.sh airpress     # 安装 app/airpress
```

服务根目录在**首次运行时交互指定**（默认 `$HOME/service`），记录在项目根目录的
`.installer.conf` 中；之后运行各服务安装脚本都会自动复用、不再询问。

- 更换服务根目录：编辑或删除 `.installer.conf` 后重新运行。

## 域名机制

**traefik** 安装时输入的根域名会保存到 `.installer.conf`（全局配置）。
其余应用（airpress、filebrowser 等）安装时**不再询问根域名**：
自动读取全局根域名，默认访问域名为 `服务名.根域名`，可修改二级域名并确认完整域名。
若尚未安装配置 traefik，应用安装会明确报错并要求先执行 `bash install.sh traefik`。
