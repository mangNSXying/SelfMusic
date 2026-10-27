FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    ONLINE_MUSIC_STATE_DIR=/data \
    ONLINE_MUSIC_PORT=18090

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py config.py verify.py ./
RUN useradd --create-home --uid 1000 sidecar \
    && mkdir -p /data \
    && chown -R sidecar:sidecar /app /data
USER sidecar

EXPOSE 18090
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:18090/healthz', timeout=3)" || exit 1

CMD ["python", "app.py"]
