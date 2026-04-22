-- V1__init.sql : upload-api 초기 스키마
-- Flyway 적용 대상. upload-api 컨테이너 기동 시 자동 실행됨.
-- Target DB: dmz (pg-main 클러스터 내 별도 database)

CREATE TABLE IF NOT EXISTS document (
  id              UUID PRIMARY KEY,
  owner_sub       TEXT NOT NULL,
  filename        TEXT NOT NULL,
  content_type    TEXT NOT NULL,
  byte_size       BIGINT NOT NULL,
  sha256_hex      TEXT NOT NULL,
  s3_bucket       TEXT NOT NULL,
  s3_key          TEXT NOT NULL,
  status          TEXT NOT NULL CHECK (status IN ('UPLOADED','OCR_RUNNING','OCR_DONE','OCR_FAILED')),
  uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ocr_finished_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS ocr_result (
  document_id     UUID PRIMARY KEY REFERENCES document(id) ON DELETE CASCADE,
  engine          TEXT NOT NULL,
  langs           TEXT NOT NULL,
  items_json      JSONB NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_document_owner ON document(owner_sub, uploaded_at DESC);
