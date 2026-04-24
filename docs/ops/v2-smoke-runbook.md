# v2 E2E Smoke Runbook

- 작성일: 2026-04-22
- 작성자: Claude Code (Sonnet 4.6)
- 버전: 1.0.0
- 관련 스크립트: `tests/smoke/v2_full_e2e_smoke.sh`
- 관련 정책: POLICY-NI-01, POLICY-EXT-01

---

## 개요

Phase 1 v2 Scope 전체 파이프라인을 단일 스크립트로 자동 검증한다.

**검증 대상 흐름**:
업로드(POST /documents) → OCR 폴링(GET) → RRN 토큰화 확인 → 수정(PUT /items) → 목록·검색(GET /documents) → 통계(GET /stats) → 외부연계 POLICY 3지점 → 감사 로그(OpenSearch, optional)

---

## 사전 조건

| 조건 | 확인 방법 |
|------|-----------|
| kind cluster `ocr-dev` 실행 중 | `kubectl cluster-info` |
| upload-api Ready (dmz ns) | `kubectl -n dmz rollout status deployment/upload-api` |
| integration-hub Ready (processing ns) | `kubectl -n processing rollout status deployment/integration-hub` |
| Keycloak Ready (admin ns) | `kubectl -n admin get pod keycloak-0` |
| fpe-service Ready (security ns) | `kubectl -n security rollout status deployment/fpe-service` |
| ocr-worker-paddle Ready (processing ns) | `kubectl -n processing rollout status deployment/ocr-worker-paddle` |
| `kubectl`, `jq`, `curl`, `nc` 설치 | `command -v kubectl jq curl nc` |
| 샘플 이미지 존재 | `ls tests/images/sample-id-korean.png` |

---

## 실행 방법

```bash
# 프로젝트 루트에서 실행
bash tests/smoke/v2_full_e2e_smoke.sh
```

종료 코드:
- `0` = 전체 통과 (Step 10 OpenSearch optional warn 포함)
- `1` = Step 1~9 중 하나 이상 실패
- `2` = 환경 오류 (kubectl/jq/curl 미설치, 샘플 이미지 없음)

리포트 파일은 `tests/smoke/v2-smoke-report-<unix-timestamp>.md`에 자동 저장된다.

---

## Step 별 검증 기준 및 실패 대응

### Step 1: port-forward 시작

**검증**: upload-api(18080), integration-hub(18090), opensearch(19200) 포트 연결 가능

**실패 시**:
```bash
kubectl -n dmz get svc upload-api
kubectl -n processing get svc integration-hub
kubectl -n observability get svc opensearch-cluster-master
# port-forward가 이미 사용 중인 경우
lsof -i :18080 -i :18090
```

---

### Step 2: Keycloak access_token 획득

**검증**: token 길이 > 500 chars, iss = `keycloak.admin.svc.cluster.local`

**핵심 패턴**: upload-api pod를 통해 cluster-internal Keycloak에 curl — iss 불일치 방지

**실패 시**:
```bash
# keycloak-dev-creds Secret 확인
kubectl -n admin get secret keycloak-dev-creds -o jsonpath='{.data.backoffice-client-secret}' | base64 -d
kubectl -n admin get secret keycloak-dev-creds -o jsonpath='{.data.dev-admin-password}' | base64 -d

# Keycloak pod 상태
kubectl -n admin get pod keycloak-0
kubectl -n admin logs keycloak-0 --tail=50
```

**이슈: JWT iss 불일치**  
port-forward를 통해 외부에서 토큰 발급 시 iss에 포트번호가 포함되어 upload-api JWT 검증 실패.  
반드시 upload-api pod 내부에서 `kubectl exec`로 발급해야 한다.

---

### Step 3: 문서 업로드 (POST /documents)

**검증**: HTTP 201 + id가 UUID 형식

**실패 시**:
```bash
kubectl -n dmz logs -l app.kubernetes.io/name=upload-api --tail=100
# fpe-service 연결 확인
kubectl -n security get pod -l app.kubernetes.io/name=fpe-service
```

---

### Step 4: OCR 완료 폴링 (GET /documents/{id})

**검증**: status == `OCR_DONE`, items.length >= 5, engine 포함 "PaddleOCR"

**폴링 타임아웃**: 120초

**실패 시**:
```bash
# ocr-worker-paddle 로그
kubectl -n processing logs -l app.kubernetes.io/name=ocr-worker-paddle --tail=100

# 문서 상태 직접 확인
kubectl -n dmz port-forward svc/upload-api 18080:80 &
curl -s http://localhost:18080/documents/{doc_id} -H "Authorization: Bearer {token}" | jq .
```

**items < 5 이슈**: 샘플 이미지(`sample-id-korean.png`)의 OCR 결과에 따라 달라질 수 있음.  
이미지를 실제 주민등록증 형태로 교체하면 5줄 이상 확보된다.

---

### Step 5: RRN 토큰화 확인

**검증**: `sensitiveFieldsTokenized == true`, items[].text에 원본 RRN 패턴(`900101-1234567`) 없음

**실패 시**:
```bash
# fpe-service 로그
kubectl -n security logs -l app.kubernetes.io/name=fpe-service --tail=100

# upload-api TokenizationService 로그
kubectl -n dmz logs -l app.kubernetes.io/name=upload-api --tail=100 | grep -i "tokeniz"
```

---

### Step 6: 수정 (PUT /documents/{id}/items)

**검증**: HTTP 200 + `updateCount == 1` + `updatedAt` 있음 + 재조회 시 텍스트 반영

**실패 시**:
```bash
kubectl -n dmz logs -l app.kubernetes.io/name=upload-api --tail=100 | grep -i "edit\|update\|PUT"
```

---

### Step 7: 목록/검색 (GET /documents)

**검증**: `totalElements >= 1`, doc_id 포함, `?status=OCR_DONE` 필터, `?q=sample` 검색

**실패 시**:
```bash
# DB 연결 상태
kubectl -n dmz logs -l app.kubernetes.io/name=upload-api --tail=100 | grep -i "db\|sql\|jdbc"
```

---

### Step 8: 통계 (GET /documents/stats)

**검증**: `owner.total >= 1`, `owner.byStatus.OCR_DONE >= 1`, `notImplemented.length >= 5`

**notImplemented < 5 실패 시** (POLICY-NI-01 위반):
```bash
# application.yml 설정 확인
kubectl -n dmz get configmap upload-api-config -o yaml | grep -A 30 "not-implemented"
# 또는 services/upload-api/src/main/resources/application.yml
```

---

### Step 9: 외부연계 3기관 POLICY 검증

**검증**: `/verify/id-card`, `/timestamp`, `/ocsp` 모두:
- HTTP 200
- 응답 헤더: `X-Not-Implemented: true`
- 응답 바디: `"notImplemented": true`

**POLICY-NI-01 + POLICY-EXT-01 근거**:
- 헤더 마커: 외부 연계 API 응답 2지점
- 바디 마커: API 응답 body 필드

**실패 시**:
```bash
# integration-hub 로그
kubectl -n processing logs -l app.kubernetes.io/name=integration-hub --tail=100

# 직접 테스트
kubectl -n processing port-forward svc/integration-hub 18090:8080 &
curl -si -X POST http://localhost:18090/verify/id-card \
  -H "Content-Type: application/json" \
  -d '{"name":"홍길동","rrn":"9001011234567","issue_date":"20200315"}' | head -20
```

---

### Step 10: 감사 로그 확인 (OpenSearch) — Optional

**검증**: dmz namespace 로그 hits > 0 (비블로킹, WARN으로 처리)

**비블로킹 이유**: fluent-bit 로그 적재에 최대 수십 초 ~ 수 분 지연 발생 가능

**수동 확인**:
```bash
kubectl -n observability port-forward svc/opensearch-cluster-master 19200:9200 &
# 비밀번호는 kubectl -n observability get secret opensearch-admin-creds -o jsonpath='{.data.password}' | base64 -d

TODAY=$(date -u +"%Y-%m-%d")
curl -s "http://localhost:19200/logs-*/_search" \
  -H "Content-Type: application/json" \
  -d "{
    \"query\": {
      \"bool\": {
        \"must\": [
          { \"match\": { \"kubernetes.namespace_name\": \"dmz\" } },
          { \"range\": { \"@timestamp\": { \"gte\": \"${TODAY}T00:00:00Z\" } } }
        ]
      }
    },
    \"size\": 5
  }" | jq '.hits.total'
```

---

## 리포트 파일 구조

리포트는 `tests/smoke/v2-smoke-report-<unix-timestamp>.md`에 저장된다.

```
# v2 E2E Smoke Report
- 실행 시각, 총 소요, 결과

## Step 결과
| # | 단계 | 결과 | 시간 | 비고 |

## 핵심 지표
- doc_id, OCR engine, items count, RRN 토큰화, updateCount, ...

## 정책 준수 체크리스트
- POLICY-NI-01, POLICY-EXT-01

## 실패 대응 (step별)
## CI 연계 (Phase 2 예정)
```

---

## CI 연계 (Phase 2)

현재는 수동 실행. Phase 2에서 GitHub Actions workflow에 통합 예정:

```yaml
# .github/workflows/e2e-smoke.yml (Phase 2 계획)
name: v2 E2E Smoke
on:
  push:
    branches: [main]
  pull_request:

jobs:
  smoke:
    runs-on: self-hosted  # kind cluster 접근 가능 runner
    steps:
      - uses: actions/checkout@v4
      - name: v2 Full E2E Smoke
        run: bash tests/smoke/v2_full_e2e_smoke.sh
      - name: Upload Report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: v2-smoke-report
          path: tests/smoke/v2-smoke-report-*.md
```

**전환 트리거**: self-hosted runner + kind cluster 환경 구성 완료 시

---

## 관련 문서

- `docs/ops/integration-hub.md` — integration-hub 운영 가이드
- `docs/ops/integration-real-impl-guide.md` — 실 연계 전환 가이드 (POLICY-EXT-01)
- `docs/ops/logs.md` — OpenSearch / fluent-bit 로그 수집 가이드
- `docs/ops/paddleocr.md` — OCR worker 운영 가이드
- `tests/smoke/upload_api_e2e_smoke.sh` — B1-T5 기존 smoke (빌드·배포 포함)
- `tests/smoke/integration_hub_smoke.sh` — integration-hub 개별 smoke

---

## 이월 사항

| 항목 | 사유 | 재검토 조건 |
|------|------|-------------|
| CI workflow 통합 | self-hosted runner 미구성 | Phase 2 인프라 확보 시 |
| 감사 로그 Step 10 블로킹 전환 | fluent-bit 적재 지연 | OpenSearch 실시간 적재 SLA 확보 시 |
| 브라우저 E2E (Playwright) | 별도 `tests/e2e-ui/` 에서 관리 | Phase 2 UI 회귀 테스트 시 |
