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
