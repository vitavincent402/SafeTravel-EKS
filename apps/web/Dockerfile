# 임시 화면 (WEB 담당이 실제 화면으로 교체). 비root(uid 101), 8080 포트
# stable(1.30.6)은 2026-11-18 보안 수정(1.30.7)이 이미지에 아직 반영되지 않아 Trivy에서 막힘 → mainline(수정 1.31.9) 사용. stable에 반영되면 stable-alpine으로 되돌림
FROM nginxinc/nginx-unprivileged:mainline-alpine
USER root
# OS 패키지의 수정된 취약점을 반영 (Trivy가 HIGH·CRITICAL을 찾으면 배포가 중단됨)
RUN apk upgrade --no-cache
USER 101
COPY default.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080
