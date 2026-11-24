# api 서비스 (앱·데이터 담당). 비root(uid 10001), 8080 포트, 읽기 전용 파일 시스템에서 동작
FROM python:3.12-slim
# OS 패키지의 수정된 취약점을 반영 (Trivy가 HIGH·CRITICAL을 찾으면 배포가 중단됨)
RUN apt-get update && apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/*
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py schema.sql ./
USER 10001
EXPOSE 8080
CMD ["python", "-u", "main.py"]
