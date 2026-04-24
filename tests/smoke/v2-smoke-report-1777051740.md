# v2 E2E Smoke Report

- 실행 시각: 2026-04-25 02:29:18
- 총 소요: 18초
- 결과: **PASS** (PASS: 9 / FAIL: 0 / WARN: 1)

## Step 결과

| # | 단계 | 결과 | 시간 | 비고 |
|---|------|------|------|------|
| 1 | port-forward 시작 | PASS | 1s | api:18080 hub:18090 os:19200 |
| 2 | access_token 획득 | PASS | 1s | len=1217 grant=password |
| 3 | 문서 업로드 | PASS | 0s | id=df15334b-f953-4e55-a1b1-9a1400ce27db |
| 4 | OCR 완료 폴링 | PASS | 12s | engine=PaddleOCR PP-OCRv5 items=5 |
| 5 | RRN 토큰화 확인 | PASS | 1s | 원본RRN없음 token=982367-9811901 |
| 6 | 수정 (PUT items) | PASS | 0s | updateCount=1 updatedAt=2026-04-24T17:29:15.680909Z |
| 7 | 목록/검색 | PASS | 0s | totalElements=50 searchTotal=9 |
| 8 | 통계 (stats) | PASS | 1s | total=50 OCR_DONE=45 NI=5 |
| 9 | 외부연계 POLICY 3지점 | PASS | 0s | 3/3 X-Not-Implemented:true |
| 10 | 감사 로그 (OpenSearch) | WARN | 1s | OpenSearch health HTTP 000000 |

## 핵심 지표

| 지표 | 값 |
|------|----|
| 실행 문서 ID | df15334b-f953-4e55-a1b1-9a1400ce27db |
| OCR engine | PaddleOCR PP-OCRv5 |
| items count | 5 |
| RRN 토큰화 | sensitiveFieldsTokenized=true, 원본 RRN 미노출 |
| tokenizedCount | "N/A" |
| PUT updateCount | 1 |
| 목록 totalElements | 50 |
| 통계 owner.total | 50 |
| 통계 OCR_DONE count | 45 |
| 통계 notImplemented 항목 수 | 5 (POLICY-NI-01: >=5) |
| 외부연계 POLICY 3지점 | 3/3 X-Not-Implemented: true |
| 감사 로그 OpenSearch hits | 0 (optional) |

## 정책 준수 체크리스트

- [x] POLICY-NI-01: notImplemented 항목 >= 5 (실제: 5)
- [x] POLICY-EXT-01: 외부연계 전면 더미 — 3 엔드포인트 모두 X-Not-Implemented: true
- [x] RRN FPE 토큰화: 원본 주민등록번호 미노출

## 실패 대응

각 Step 실패 시:
- Step 1 (port-forward): `kubectl get svc -n dmz`, `kubectl get svc -n processing` 확인
- Step 2 (token): `kubectl -n admin get secret keycloak-dev-creds` 확인, Keycloak pod 상태 점검
- Step 3 (upload): upload-api 로그 `kubectl -n dmz logs -l app.kubernetes.io/name=upload-api --tail=50`
- Step 4 (OCR): ocr-worker-paddle 로그 `kubectl -n processing logs -l app.kubernetes.io/name=ocr-worker-paddle --tail=50`
- Step 5 (tokenize): fpe-service 로그 `kubectl -n security logs -l app.kubernetes.io/name=fpe-service --tail=50`
- Step 6 (PUT): upload-api OcrEditService 로그 확인
- Step 7 (목록): DB 연결 상태 확인
- Step 8 (stats): notImplemented 설정 `application.yml ocr.not-implemented` 확인
- Step 9 (외부연계): integration-hub 로그 `kubectl -n processing logs -l app.kubernetes.io/name=integration-hub --tail=50`
- Step 10 (감사로그): fluent-bit 상태 `kubectl -n kube-system rollout status ds/fluent-bit`

## CI 연계 (Phase 2 예정)

```yaml
# .github/workflows/e2e-smoke.yml (Phase 2)
- name: v2 E2E Smoke
  run: bash tests/smoke/v2_full_e2e_smoke.sh
```
