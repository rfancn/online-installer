# ============================================================
# hipoint 静态服务 —— 由 app/hipoint/install.sh 生成
# 源文件: __SOURCE__
# 软链至: /etc/nginx/conf.d/hipoint-<服务名>.conf（nginx 主配置 include conf.d/*.conf）
# 翻译自原 nginx 静态站点：SPA 回退 + 禁用缓存 + 敏感文件加固
# 绑 0.0.0.0 是为让容器化 Traefik 经 host.docker.internal 回源；
# 公网访问统一由 Traefik 443 出口，本端口请用主机防火墙/安全组限制、勿直接暴露。
# ============================================================
server {
    listen __NGINX_PORT__;
    server_name __SERVER_NAME__;

    access_log /var/log/nginx/__LOG_PREFIX__-access.log;
    error_log  /var/log/nginx/__LOG_PREFIX__-error.log;

    # 静态站点：按根路径处理（PC 管理端的路径第一段已由 Traefik 剥离；
    # 微信回调站点由 Traefik 原路径转发，不做剥离）
    location / {
        add_header Cache-Control "no-store, no-cache, must-revalidate";
        root __ROOT_DIR__;
        index index.html index.htm;
        try_files $uri $uri/ /index.html;
    }

    # 禁止访问隐藏文件（以 . 开头）
    location ~ /\. {
        deny all;
        return 404;
    }

    # 禁止访问敏感/备份/压缩文件（含 .bak）
    location ~* \.(env|git|svn|htaccess|htpasswd|bak|log|sql|zip|tar\.gz)$ {
        deny all;
        return 403;
    }

    # 禁止目录遍历（显式加固）
    location ~ \.\./ {
        deny all;
        return 403;
    }
}
