# Tiny, dependency-free demo image. The version is baked in at build time so
# every published tag renders a visibly different page during a rollout.
FROM python:3.12-slim

ARG VERSION=dev
ENV VERSION=${VERSION} \
    PORT=8080 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY app.py .

EXPOSE 8080
USER 65534:65534
ENTRYPOINT ["python", "/app/app.py"]
