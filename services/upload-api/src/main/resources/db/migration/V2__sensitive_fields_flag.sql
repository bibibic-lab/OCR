-- V2__sensitive_fields_flag.sql
-- ocr_result 테이블에 민감 필드 토큰화 추적 컬럼 추가
-- Flyway 자동 적용. upload-api 기동 시 실행됨.
-- 관련 기능: Phase 1 Low #4 FPE 토큰화 통합 (2026-04-22)

ALTER TABLE ocr_result
    ADD COLUMN IF NOT EXISTS sensitive_fields_tokenized BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS tokenized_count            INT     NOT NULL DEFAULT 0;

COMMENT ON COLUMN ocr_result.sensitive_fields_tokenized IS 'fpe-service /tokenize-batch 호출 완료 여부';
COMMENT ON COLUMN ocr_result.tokenized_count             IS '토큰화된 고유 민감값(RRN 등) 개수';
