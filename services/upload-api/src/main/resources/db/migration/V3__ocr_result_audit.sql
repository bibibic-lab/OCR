-- V3__ocr_result_audit.sql
-- OCR 결과 수정 기능을 위한 감사(audit) 컬럼 추가
-- 관련 기능: Phase 1-v2 기본기능 #1 — OCR 결과 수정 (2026-04-22)

ALTER TABLE ocr_result
    ADD COLUMN IF NOT EXISTS updated_at    TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS updated_by    TEXT,
    ADD COLUMN IF NOT EXISTS update_count  INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN ocr_result.updated_at   IS '마지막 items 수정 시각 (NULL = 수정 이력 없음)';
COMMENT ON COLUMN ocr_result.updated_by   IS '마지막 수정한 JWT subject';
COMMENT ON COLUMN ocr_result.update_count IS '누적 수정 횟수';

CREATE INDEX IF NOT EXISTS idx_ocr_result_updated_at ON ocr_result(updated_at);
