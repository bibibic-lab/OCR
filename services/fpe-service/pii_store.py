"""
pii_store.py — pg-pii FPE 토큰 감사 레지스트리
================================================
pg-pii 데이터베이스의 fpe_token 테이블에 토큰 생성/조회 이력을 기록합니다.

테이블 역할:
  - 토큰 생성 시각, 타입, KEK 버전 기록 (감사 추적)
  - detokenize 호출 횟수 및 최근 시각 추적
  - token_hash (SHA-256) 기반 중복 토큰 탐지

NOTE:
  FF3-1은 결정론적이므로 동일 (key, tweak, plaintext) → 동일 token.
  token_hash는 UNIQUE 제약이며, 중복 tokenize 시 기존 레코드 upsert.

환경변수:
  PII_DB_DSN : PostgreSQL DSN (기본 개발값 제공)
"""
from __future__ import annotations

import hashlib
import logging
import os
import uuid
from contextlib import contextmanager
from typing import Optional, Tuple

import psycopg2
import psycopg2.extras

logger = logging.getLogger(__name__)

PII_DB_DSN = os.environ.get(
    "PII_DB_DSN",
    "postgresql://fpe_user:fpe_pass@pg-pii.security.svc.cluster.local:5432/pii"
)


@contextmanager
def _get_conn():
    """psycopg2 커넥션 컨텍스트 매니저 (단순 연결, Phase 2에서 pooling 도입)"""
    conn = psycopg2.connect(PII_DB_DSN)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _token_hash(field_type: str, token: str) -> str:
    """(type, token) 복합 SHA-256 해시 → fpe_token 테이블 lookup 키"""
    raw = f"{field_type}:{token}".encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def register_token(
    field_type: str,
    token: str,
    kek_version: str,
) -> str:
    """
    토큰 감사 레지스트리에 등록.
    이미 존재하는 토큰이면 기존 ID 반환 (upsert).

    Returns:
        token_id (UUID 문자열)
    """
    th = _token_hash(field_type, token)
    with _get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO fpe_token (id, token_hash, type, kek_version)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (token_hash) DO UPDATE
                    SET kek_version = EXCLUDED.kek_version
                RETURNING id
                """,
                (str(uuid.uuid4()), th, field_type, kek_version),
            )
            row = cur.fetchone()
            token_id = str(row[0])
    logger.debug("토큰 등록: type=%s, token_id=%s", field_type, token_id)
    return token_id


def record_detokenize(field_type: str, token: str) -> bool:
    """
    detokenize 호출 기록 업데이트.
    Returns: True if record exists, False otherwise
    """
    th = _token_hash(field_type, token)
    with _get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE fpe_token
                SET detokenize_count = detokenize_count + 1,
                    last_detokenized_at = NOW()
                WHERE token_hash = %s
                RETURNING id
                """,
                (th,),
            )
            row = cur.fetchone()
            exists = row is not None
    if not exists:
        logger.warning("detokenize 기록 대상 토큰 없음: type=%s", field_type)
    return exists


def token_stats(field_type: str, token: str) -> Optional[dict]:
    """토큰 통계 조회 (존재하지 않으면 None)"""
    th = _token_hash(field_type, token)
    with _get_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT id, type, kek_version, created_at, detokenize_count, last_detokenized_at "
                "FROM fpe_token WHERE token_hash = %s",
                (th,),
            )
            row = cur.fetchone()
    return dict(row) if row else None
