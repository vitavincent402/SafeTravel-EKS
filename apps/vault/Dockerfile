# 임시 서버 (DB 담당이 실제 vault 서비스로 교체). 비root(uid 10001), 8080 포트
FROM python:3.12-slim
# OS 패키지의 수정된 취약점을 반영 (Trivy가 HIGH·CRITICAL을 찾으면 배포가 중단됨)
RUN apt-get update && apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY main.py .
USER 10001
EXPOSE 8080
CMD ["python", "-u", "main.py"]
