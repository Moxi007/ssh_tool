#!/bin/bash

# 安装nginx
sudo apt update && sudo apt install nginx -y

# 创建目录
sudo mkdir -p /data/nginx

# 获取用户输入
read -p "请输入Emby服务器地址和端口（默认127.0.0.1:8880）：" emby_server
emby_server=${emby_server:-127.0.0.1:8880}

read -p "请输入域名（如emby.example.com）：" domain_name

# 生成nginx配置文件
sudo tee /etc/nginx/conf.d/db.conf > /dev/null <<EOF
proxy_cache_path /data/nginx levels=1:2 keys_zone=emby:200m max_size=10g inactive=365d use_temp_path=off;

upstream emby {
    server $emby_server;
    keepalive 1024;
}

server {
    listen 80;
    listen [::]:80;
    server_name $domain_name;

    # 全局客户端请求设置
    client_body_buffer_size 512k;
    client_max_body_size 20M;

    # 安全性和响应头
    add_header 'Referrer-Policy' 'origin-when-cross-origin';
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    keepalive_timeout 120s;
    keepalive_requests 10000;

    # 全局代理参数
    proxy_hide_header X-Powered-By;
    proxy_buffer_size 32k;
    proxy_buffers 4 64k;
    proxy_busy_buffers_size 128k;
    proxy_temp_file_write_size 128k;
    proxy_connect_timeout 1h;
    proxy_send_timeout 1h;
    proxy_read_timeout 1h;

    # 全局代理头
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Protocol \$scheme;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header REMOTE-HOST \$remote_addr;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "";
    proxy_set_header Accept-Encoding "";
    proxy_http_version 1.1;

    # 禁止直接通过IP访问
    if (\$host ~* "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\$") {
        return 401;
    }
    
    if (\$host ~* "^\[([0-9a-fA-F:]+)\]$") {
        return 401;
    }

    # 路径规则
    location /swagger {
        return 404;
    }

    location = / {
        return 302 web/index.html;
    }

    location / {
        proxy_pass http://emby;
        proxy_cache off;
    }

    location /web/ {
        proxy_pass http://emby;
    }

    location = /embywebsocket {
        proxy_pass http://emby;
        proxy_set_header Connection "upgrade";
        proxy_cache off;
    }

    location /emby/videos/ {
        proxy_pass http://emby;
        proxy_cache off;
        proxy_buffering off;
    }

    location ~ ^/emby/Items/.*/Images/ {
        proxy_pass http://emby;
        proxy_cache emby;
        proxy_cache_key \$request_uri;
        proxy_cache_revalidate on;
        proxy_cache_lock on;
    }
}
EOF

# 测试配置并重启nginx
sudo nginx -t && sudo systemctl restart nginx

echo "Nginx反向代理配置完成！"
echo "访问地址：http://$domain_name"