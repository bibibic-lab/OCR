"""
OCR Worker (PaddleOCR PP-OCRv5) — Phase 1 accuracy comparison worker.

엔진: PaddleOCR 3.5.0 / PP-OCRv5 CPU mode (한국어).
빌드 타임에 모델 pre-download (processing ns default-deny egress 대응).

paddleocr 3.x API 변경사항:
- PaddleOCR(use_textline_orientation=True, lang='korean') — use_gpu/use_angle_cls 제거
- ocr.predict(path) 반환: list of dict {rec_texts, rec_scores, rec_polys, ...}

HTTP multipart 업로드 → text / confidence / bbox JSON 반환.
API shape은 ocr-worker (EasyOCR) 와 동일.
"""
from __future__ import annotations

import logging
import os
import tempfile
from typing import Any

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from paddleocr import PaddleOCR

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("ocr-worker-paddle")

# paddleocr 3.x: 모델 source check 비활성화 (빌드 타임 pre-download 후 offline 동작)
os.environ.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")

log.info("loading PaddleOCR PP-OCRv5 (korean, CPU)...")
_OCR = PaddleOCR(
    use_textline_orientation=True,
    lang="korean",
    # device 미지정 → CPU 자동 사용 (GPU 없음)
)
log.info("PaddleOCR ready")

app = FastAPI(title="ocr-worker-paddle", version="0.1.0-paddleocr-v5")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, str]:
    return {"status": "ready", "engine": "PaddleOCR PP-OCRv5", "langs": "ko,en"}


@app.post("/ocr")
async def ocr_endpoint(file: UploadFile = File(...)) -> JSONResponse:
    suffix = os.path.splitext(file.filename or "upload")[1].lower() or ".png"
    if suffix not in {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp"}:
        raise HTTPException(415, f"unsupported file type: {suffix}")

    data = await file.read()
    if not data:
        raise HTTPException(400, "empty upload")

    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tf:
        tf.write(data)
        tmp_path = tf.name

    try:
        log.info("ocr invoke filename=%s bytes=%d", file.filename, len(data))
        result = _OCR.predict(tmp_path)
        # paddleocr 3.x 결과: list of dict per page
        # result[0] keys: rec_texts, rec_scores, rec_polys (4점 좌표 numpy)
        items: list[dict[str, Any]] = []
        if result:
            r = result[0]
            texts = r.get("rec_texts", [])
            scores = r.get("rec_scores", [])
            polys = r.get("rec_polys", [])
            for text, conf, poly in zip(texts, scores, polys):
                items.append({
                    "text": text,
                    "confidence": round(float(conf), 4),
                    "bbox": [[int(p[0]), int(p[1])] for p in poly],  # 4점 좌표 (int)
                })
        return JSONResponse({
            "filename": file.filename,
            "engine": "PaddleOCR PP-OCRv5",
            "langs": ["ko", "en"],
            "count": len(items),
            "items": items,
        })
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
