# OCR Worker — Stage B-0 minimal CPU image.
# 엔진: EasyOCR(PyTorch). PaddleOCR은 OrbStack/Rosetta 환경 SEGV로 dev 포기, 프로덕션 복원.
FROM --platform=linux/amd64 python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      libgomp1 libglib2.0-0 libsm6 libxrender1 libxext6 libgl1 \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt

COPY server.py .

# EasyOCR 모델 빌드 타임 pre-download (~100MB, ko+en).
# processing ns default-deny egress로 런타임 외부 다운로드 불가.
RUN python -c "import easyocr; easyocr.Reader(['ko','en'], gpu=False, verbose=False)"

RUN useradd --uid 1000 --create-home --shell /bin/bash ocr \
 && mkdir -p /home/ocr/.EasyOCR \
 && cp -r /root/.EasyOCR/* /home/ocr/.EasyOCR/ 2>/dev/null || true \
 && chown -R 1000:1000 /home/ocr/.EasyOCR
USER 1000:1000

EXPOSE 8000
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
