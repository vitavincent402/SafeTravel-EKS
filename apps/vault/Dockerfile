# 임시 서버 (DB 담당이 실제 vault 서비스로 교체). 비root(uid 10001), 8080 포트
FROM python:3.12-slim
WORKDIR /app
COPY main.py .
USER 10001
EXPOSE 8080
CMD ["python", "-u", "main.py"]
