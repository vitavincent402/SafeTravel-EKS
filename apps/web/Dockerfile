# 임시 화면 (WEB 담당이 실제 화면으로 교체). 비root(uid 101), 8080 포트
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY default.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080
