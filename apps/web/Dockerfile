# 임시 화면 (WEB 담당이 실제 화면으로 교체). 비root(uid 101), 8080 포트
# 1.27은 지원이 끝난 버전이라 최신 stable을 따라가는 태그를 씀
FROM nginxinc/nginx-unprivileged:stable-alpine
USER root
# OS 패키지의 수정된 취약점을 반영 (Trivy가 HIGH·CRITICAL을 찾으면 배포가 중단됨)
RUN apk upgrade --no-cache
USER 101
COPY default.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080
