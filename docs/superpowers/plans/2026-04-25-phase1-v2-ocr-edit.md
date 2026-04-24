# Phase 1-v2 #1: OCR 결과 수정 기능 구현 계획 및 결과

- **작성일**: 2026-04-25
- **상태**: DONE
- **커밋**: `fb3b946`
- **담당**: Claude Code (Implementer)

## 배경

`project_scope_v2_basic_flow.md` 6개 기본 기능 중 저장/조회는 구현 완료, **수정(편집)** 만 미구현 상태였음.

## 구현 범위

### 포함

| 항목 | 파일 | 내용 |
|------|------|------|
| Flyway V3 | `V3__ocr_result_audit.sql` | `ocr_result` 테이블에 `updated_at`, `updated_by`, `update_count` 컬럼 + 인덱스 추가 |
| OcrEditService | `OcrEditService.kt` (신규) | 소유권 검증 → 상태 검증 → RRN 재토큰화 → DB UPDATE |
| PUT 엔드포인트 | `DocumentController.kt` | `PUT /documents/{id}/items` — 정상/403/404/400 |
| Repository | `Repositories.kt` | `OcrResultRepository.update()` 메소드 + `findByDocumentId` 확장 (`updated_at`, `update_count` 노출) |
| 응답 DTO | `DocumentController.kt` | `DocumentDoneResponse`에 `updatedAt`, `updateCount` 추가 |
| admin-ui API | `lib/api.ts` | `updateDocumentItems()` 함수 + `DocumentResult` 확장 |
| admin-ui UI | `editable-items.tsx` (신규) | 편집/저장/취소/loading/에러 배너 클라이언트 컴포넌트 |
| admin-ui 페이지 | `page.tsx` | OCR_DONE 시 BboxViewer(read-only) + EditableItems(편집) 병렬 렌더 |
| 단위 테스트 | `DocumentControllerTest.kt` | PUT 정상/403/404/400 케이스 4개 추가 |
| Flaky 픽스 | `OcrFlowTest.kt` | MockWebServer shutdown IOException → `runCatching` 처리 |

### 제외 (스펙 명시)

- 편집 이력 diff 조회 UI (Phase 2)
- admin Role 타인 문서 편집
- bulk edit · CSV import
- version history 테이블

## POLICY 준수

- **POLICY-NI-01**: 이번 작업은 실 구현이므로 Not Implemented 표시 없음.
- **RRN 재토큰화**: `TokenizationService.tokenizeSensitiveFields()` 재사용. 편집된 items에 RRN이 포함되면 자동 토큰화.

## 테스트 결과

### 단위/통합 테스트

- `DocumentControllerTest`: 9/9 pass (기존 5 + 신규 4)
- `OcrFlowTest`: 4/4 pass (executionError flaky 수정)
- `TokenizationServiceTest`, `SecurityConfigTest`: 회귀 없음
- 총 25 tests / 0 fail (rerun-tasks 기준 최종 확인)

### 빌드

- `./gradlew bootJar` — BUILD SUCCESSFUL
- `npm run build` — ✓ Compiled successfully
- `docker build upload-api:v0.3.0` — 성공
- `docker build admin-ui:v0.2.0` — 성공

### k8s 배포

- `upload-api:v0.3.0` → kind load → `deployment.yaml` 이미지 태그 업데이트 → `kubectl apply` → pod Ready
- `admin-ui:v0.2.0` → kind load → `deployment.yaml` 이미지 태그 업데이트 → `kubectl apply` → pod Ready
- Flyway V3 마이그레이션 자동 적용 확인 (`Successfully applied 1 migration to schema "public", now at version v3`)

### DB 컬럼 확인

```
Table "public.ocr_result"
updated_at   | timestamp with time zone | nullable
updated_by   | text                     | nullable  
update_count | integer                  | not null  DEFAULT 0

Indexes:
  "idx_ocr_result_updated_at" btree (updated_at)
```

직접 UPDATE 시뮬레이션 결과:
```sql
document_id | update_count | updated_at                    | updated_by
------------+--------------+-------------------------------+----
6f16c5c...  | 1            | 2026-04-24 15:08:33.382915+00 | dc4be6c9-...
```

## API 명세

### PUT /documents/{id}/items

**요청**:
```json
{"items": [{"text": "수정된 텍스트", "confidence": 0.95, "bbox": [[0,0],[100,0],[100,20],[0,20]]}]}
```

**성공 응답 (200)**:
```json
{
  "id": "<uuid>",
  "status": "OCR_DONE",
  "engine": "EasyOCR 1.7.1",
  "langs": ["ko","en"],
  "items": [...],
  "ocrFinishedAt": "...",
  "updatedAt": "2026-04-24T15:08:33Z",
  "updateCount": 1
}
```

**오류 응답**:
- `404` — 문서 없음
- `403` — 본인 소유 아님
- `400` — OCR_DONE 아닌 상태 (`{"message": "OCR_DONE 상태의 문서만 편집할 수 있습니다. 현재 상태: UPLOADED"}`)

## Phase 2 이월 항목

- 편집 이력 diff 저장 + 조회 UI
- admin Role이 타인 문서 편집 가능하게
- 항목별 부분 수정 (현재: 전체 배열 교체)
- 감사 로그 전용 뷰어
