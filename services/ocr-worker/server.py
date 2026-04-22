"""
OCR Worker — Stage B-0 walking-skeleton.

엔진: EasyOCR (한국어 + 영어). PaddleOCR은 OrbStack/Rosetta 환경에서 SEGV 발생
하여 dev는 EasyOCR로 대체. 프로덕션 linux-native 환경에서는 spec의 PaddleOCR
PP-OCRv4 로 복원 예정 (Phase 1).

HTTP multipart 업로드 → text / confidence / bbox JSON 반환.
Stage B-1 이후 SeaweedFS 저장·PG 메타·Keycloak OIDC 연동.
"""
from __future__ import annotations

import logging
import os
import tempfile
from typing import Any

import easyocr
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import JSONResponse

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("ocr-worker")

log.info("loading EasyOCR reader (ko + en, CPU)...")
_READER = easyocr.Reader(["ko", "en"], gpu=False, verbose=False)
log.info("EasyOCR reader ready")

app = FastAPI(title="ocr-worker", version="0.2.0-easyocr")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, str]:
    return {"status": "ready", "engine": "EasyOCR", "langs": "ko,en"}


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
        result = _READER.readtext(tmp_path, detail=1, paragraph=False)
        # EasyOCR 결과: list of (bbox, text, conf)
        items: list[dict[str, Any]] = []
        for entry in result:
            bbox, text, conf = entry
            items.append({
                "text": text,
                "confidence": round(float(conf), 4),
                "bbox": [[int(p[0]), int(p[1])] for p in bbox],  # 4점 좌표 (int)
            })
        return JSONResponse({
            "filename": file.filename,
            "engine": "EasyOCR 1.7.1",
            "langs": ["ko", "en"],
            "count": len(items),
            "items": items,
        })
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
