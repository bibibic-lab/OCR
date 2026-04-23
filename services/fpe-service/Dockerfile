# ── FPE Tokenization Service ──────────────────────────────────────────────────
# Python 3.11-slim + FF3-1 (NIST SP 800-38G) 기반 Format-Preserving Encryption
# Dev-grade: FF3-1 with random key/tweak per field-type from OpenBao KV
# Phase 2 upgrade: FF3-1 key rotation, FIPS-validated library
# ─────────────────────────────────────────────────────────────────────────────
FROM python:3.11-slim AS base

# 비루트 사용자 생성
RUN groupadd -r appuser && useradd -r -g appuser -u 1000 appuser

WORKDIR /app

# 시스템 의존성
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Python 의존성 레이어 (소스 변경 시 캐시 유지)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 소스 복사
COPY *.py ./

# 비루트 권한 설정
RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
