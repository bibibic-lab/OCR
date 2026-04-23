# OCR Worker (PaddleOCR PP-OCRv5) — Phase 1 accuracy comparison image.
#
# 전략: python:3.11-slim + pip install paddlepaddle==3.0.0 + paddleocr==3.5.0
#
# 버전 선정 근거:
#   - paddlepaddle 2.6.2 + paddleocr 2.x: "double free or corruption" SIGABRT (libgomp conflict)
#   - paddlepaddle 3.0.0 + paddleocr 3.5.0: 정상 동작 확인 (2026-04-22 검증)
#   - paddleocr 3.5.0 은 PP-OCRv5 서버 모델 사용 (PP-OCRv4 대비 동급 이상 정확도)
#
# CPU 요건: AVX/AVX2 필수. Intel Mac OrbStack kind cluster에서 확인됨.
#
# 모델 pre-download (~600MB, det/rec/cls/orientation):
#   processing ns default-deny egress → 런타임 외부 다운로드 불가.
#   PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True 로 오프라인 모드 동작.

FROM --platform=linux/amd64 python:3.11-slim

# 시스템 의존성
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgomp1 \
      libglib2.0-0 \
      libsm6 \
      libxrender1 \
      libxext6 \
      libgl1 \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# requirements 설치
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

COPY server.py .

# PP-OCRv5 한국어 모델 빌드 타임 pre-download
# paddlex 모델 캐시: /root/.paddlex/official_models/
# connectivity check 비활성화하여 순수 다운로드만 수행
ENV PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
RUN python -Xfaulthandler -c \
    "from paddleocr import PaddleOCR; \
     ocr = PaddleOCR(use_textline_orientation=True, lang='korean'); \
     print('PaddleOCR PP-OCRv5 model pre-download OK')"

# 비루트 사용자 (UID 1000)
RUN useradd --uid 1000 --create-home --shell /bin/bash ocr \
    && mkdir -p /home/ocr/.paddlex \
    && cp -r /root/.paddlex/* /home/ocr/.paddlex/ 2>/dev/null || true \
    && chown -R 1000:1000 /home/ocr/.paddlex
USER 1000:1000

EXPOSE 8000
CMD ["python", "-Xfaulthandler", "-m", "uvicorn", "server:app", \
     "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
