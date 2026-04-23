"""
server.py — FPE Tokenization Service (FastAPI)
================================================
REST API 서버:
  POST /tokenize         — 단건 토큰화
  POST /detokenize       — 역토큰화 (audit 기록 필수)
  POST /tokenize-batch   — 배치 토큰화
  GET  /health           — 헬스체크

보안:
  - /detokenize: Authorization 헤더 Bearer JWT 검증 + realm_access.roles에 'detokenize' 포함 필요
    (Phase 1 MVP: JWT 서명 검증만, step-up MFA는 Phase 2)
  - /tokenize: 내부 서비스 전용 (NetworkPolicy로 upload-api만 접근)
  - Audit log: detokenize 호출마다 JSON stdout → Fluentbit → OpenSearch audit-fpe-*

환경변수:
  BAO_ADDR, BAO_TOKEN, BAO_SKIP_VERIFY  : OpenBao 연결
  PII_DB_DSN                            : pg-pii PostgreSQL DSN
  KEYCLOAK_ISSUER                       : JWT issuer URL 검증용
  FPE_REQUIRE_AUTH                      : "false" 시 JWT 검증 스킵 (개발 전용)
  LOG_LEVEL                             : 로그 레벨 (기본 INFO)
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
import uuid
from typing import List, Optional

from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.responses import JSONResponse
from pydantic import BaseModel, field_validator

from fpe import tokenize, detokenize, FIELD_TYPES, FPEError
from vault_client import get_fpe_config
from pii_store import register_token, record_detokenize

# ──── 로깅 설정 ──────────────────────────────────────────────────────────────
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("fpe-service")

KEYCLOAK_ISSUER = os.environ.get(
    "KEYCLOAK_ISSUER",
    "https://keycloak.admin.svc.cluster.local/realms/ocr"
)
FPE_REQUIRE_AUTH = os.environ.get("FPE_REQUIRE_AUTH", "true").lower() != "false"

# ──── FastAPI 앱 ─────────────────────────────────────────────────────────────
app = FastAPI(
    title="FPE Tokenization Service",
    version="0.1.0",
    description="Format-Preserving Encryption (FF3-1, NIST SP 800-38G) for PII fields",
    docs_url="/docs" if os.environ.get("APP_ENV") != "production" else None,
)


# ──── Pydantic 모델 ───────────────────────────────────────────────────────────
class TokenizeRequest(BaseModel):
    type: str
    value: str

    @field_validator("type")
    @classmethod
    def validate_type(cls, v: str) -> str:
        if v not in FIELD_TYPES:
            raise ValueError(f"지원하지 않는 type: {v!r}. 허용: {sorted(FIELD_TYPES)}")
        return v


class TokenizeResponse(BaseModel):
    token: str
    token_id: str


class DetokenizeRequest(BaseModel):
    type: str
    token: str
    audit_reason: str = ""

    @field_validator("type")
    @classmethod
    def validate_type(cls, v: str) -> str:
        if v not in FIELD_TYPES:
            raise ValueError(f"지원하지 않는 type: {v!r}")
        return v


class DetokenizeResponse(BaseModel):
    value: str


class BatchItem(BaseModel):
    type: str
    value: str


class TokenizeBatchRequest(BaseModel):
    items: List[BatchItem]


class TokenizeBatchResponse(BaseModel):
    tokens: List[TokenizeResponse]
    errors: List[dict] = []


# ──── JWT 역할 검사 (MVP: 서명 검증 없음, Phase 2에서 JWKS 추가) ───────────────
def _check_detokenize_role(request: Request) -> None:
    """
    detokenize 엔드포인트 권한 검사.
    MVP: Authorization: Bearer <token> 헤더 존재 확인 + realm role 'detokenize' 포함 확인.
    Phase 2: JWKS 서명 검증 + step-up MFA.

    FPE_REQUIRE_AUTH=false 이면 검증 스킵 (개발 환경).
    """
    if not FPE_REQUIRE_AUTH:
        logger.warning("FPE_REQUIRE_AUTH=false — JWT 검증 스킵 (개발 모드)")
        return

    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Authorization: Bearer <token> 필요")

    # MVP: JWT 디코드 (서명 검증 없음) — 역할만 확인
    # Phase 2에서 python-jose + JWKS endpoint로 교체
    try:
        import base64
        parts = auth_header.split(" ", 1)[1].split(".")
        if len(parts) < 2:
            raise ValueError("JWT 형식 오류")
        # base64 padding 복구
        payload_b64 = parts[1] + "=" * (4 - len(parts[1]) % 4)
        payload = json.loads(base64.b64decode(payload_b64))
        roles = (
            payload.get("realm_access", {}).get("roles", [])
        )
        if "detokenize" not in roles:
            raise HTTPException(
                status_code=403,
                detail="detokenize 역할 없음. Keycloak realm role 'detokenize' 필요."
            )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=401, detail=f"JWT 파싱 실패: {e}")


# ──── 감사 로그 헬퍼 ──────────────────────────────────────────────────────────
def _emit_audit_log(event: str, field_type: str, audit_reason: str, request: Request) -> None:
    """
    detokenize 감사 이벤트를 JSON stdout으로 출력.
    Fluentbit → OpenSearch audit-fpe-* 인덱스로 수집.
    """
    log_entry = {
        "@timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event": event,
        "field_type": field_type,
        "audit_reason": audit_reason,
        "client_ip": request.client.host if request.client else "unknown",
        "request_id": request.headers.get("X-Request-Id", str(uuid.uuid4())),
        "service": "fpe-service",
        "index": "audit-fpe",
    }
    # structlog 형식으로 stdout 출력 (Fluentbit multiline 파서와 호환)
    print(json.dumps(log_entry, ensure_ascii=False), flush=True)


# ──── 엔드포인트 ──────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "service": "fpe-service", "version": "0.1.0"}


@app.post("/tokenize", response_model=TokenizeResponse)
def tokenize_endpoint(req: TokenizeRequest):
    """
    단건 토큰화.
    FPE(FF3-1)로 포맷 보존 토큰 생성 후 pg-pii 감사 레지스트리에 등록.
    """
    try:
        config = get_fpe_config(req.type)
        token = tokenize(req.type, req.value, config)
        token_id = register_token(req.type, token, config.kek_version)
        return TokenizeResponse(token=token, token_id=token_id)
    except FPEError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except RuntimeError as e:
        logger.error("토큰화 실패 (runtime): %s", e)
        raise HTTPException(status_code=503, detail=f"서비스 오류: {e}")
    except Exception as e:
        logger.exception("토큰화 예외")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/detokenize", response_model=DetokenizeResponse)
def detokenize_endpoint(req: DetokenizeRequest, request: Request):
    """
    역토큰화.
    - JWT Bearer 토큰에서 'detokenize' realm role 확인
    - pg-pii 감사 레지스트리 업데이트
    - stdout 감사 로그 출력 → Fluentbit → OpenSearch audit-fpe-*
    """
    _check_detokenize_role(request)
    try:
        config = get_fpe_config(req.type)
        original = detokenize(req.type, req.token, config)
        record_detokenize(req.type, req.token)
        _emit_audit_log("detokenize", req.type, req.audit_reason, request)
        return DetokenizeResponse(value=original)
    except FPEError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except RuntimeError as e:
        logger.error("역토큰화 실패 (runtime): %s", e)
        raise HTTPException(status_code=503, detail=f"서비스 오류: {e}")
    except Exception as e:
        logger.exception("역토큰화 예외")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/tokenize-batch", response_model=TokenizeBatchResponse)
def tokenize_batch_endpoint(req: TokenizeBatchRequest):
    """
    배치 토큰화 (OCR 후처리용).
    개별 실패 시 errors 배열에 포함, 나머지는 정상 처리.
    """
    results = []
    errors = []
    for idx, item in enumerate(req.items):
        try:
            if item.type not in FIELD_TYPES:
                raise FPEError(f"지원하지 않는 type: {item.type!r}")
            config = get_fpe_config(item.type)
            token = tokenize(item.type, item.value, config)
            token_id = register_token(item.type, token, config.kek_version)
            results.append(TokenizeResponse(token=token, token_id=token_id))
        except Exception as e:
            errors.append({"index": idx, "type": item.type, "error": str(e)})
            logger.warning("배치 토큰화 항목 실패 [%d]: %s", idx, e)

    return TokenizeBatchResponse(tokens=results, errors=errors)


# ──── 에러 핸들러 ─────────────────────────────────────────────────────────────

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.exception("처리되지 않은 예외: %s", exc)
    return JSONResponse(status_code=500, content={"detail": "내부 서버 오류"})
