# Accuracy Harness — 사용법 및 결과 해석

> **Stage B-2 Task T2** — EasyOCR 정확도 측정 자동화 harness

---

## 개요

`tests/accuracy/` 하위 10장의 한글 샘플 이미지와 그에 대응하는 기대 답안(`*.answer.json`)을 기반으로 upload-api E2E 경로를 통해 OCR 결과의 필드 수준 정확도를 자동 측정합니다.

측정 결과는 stdout 테이블과 `reports/baseline-<commit>.json`으로 저장됩니다.

---

## 디렉터리 구조

```
tests/accuracy/
├── fixtures/               # 샘플 이미지 + 답안 JSON
│   ├── id-korean-01.png
│   ├── id-korean-01.answer.json
│   ├── ...                 # 총 10쌍 (10 PNG + 10 answer.json)
│   └── README.md           # 샘플 카테고리 목록
├── metrics.py              # 핵심 지표 계산 (normalize, levenshtein, find_best_match)
├── run_accuracy.py         # 메인 harness 스크립트
├── run.sh                  # bash 래퍼 (token 발급 + port-forward 포함)
├── reports/
│   ├── baseline.md         # 최초 실행 stdout 캡처
│   └── baseline-<commit>.json  # 구조화 결과
└── README.md               # 이 파일
```

---

## 사전 조건

| 항목 | 요구사항 |
|------|---------|
| kind cluster | `ocr-dev` 실행 중 |
| Pod | `dmz/upload-api`, `admin/keycloak`, `processing/ocr-worker` Running |
| 도구 | `kubectl`, `jq`, `curl`, `python3` (≥3.9) |
| Secret | `admin/keycloak-dev-creds` (backoffice-client-secret, dev-admin-password) |

---

## 실행 방법

### 1. 전체 실행 (권장)

```bash
# 실행 + stdout을 baseline.md로 캡처
bash tests/accuracy/run.sh 2>&1 | tee tests/accuracy/reports/baseline.md
```

### 2. 직접 Python 실행 (token 수동 발급 시)

```bash
# token 발급 (upload-api pod 경유, cluster-internal iss 필요)
TOKEN=$(kubectl -n dmz exec $(kubectl -n dmz get pod -l app.kubernetes.io/name=upload-api \
  -o jsonpath='{.items[0].metadata.name}') -- curl -sk \
  "https://keycloak.admin.svc.cluster.local/realms/ocr/protocol/openid-connect/token" \
  -d "client_id=ocr-backoffice" \
  -d "client_secret=$(kubectl -n admin get secret keycloak-dev-creds \
      -o jsonpath='{.data.backoffice-client-secret}' | base64 -d)" \
  -d "username=dev-admin" \
  -d "password=$(kubectl -n admin get secret keycloak-dev-creds \
      -o jsonpath='{.data.dev-admin-password}' | base64 -d)" \
  -d "grant_type=password" | jq -r '.access_token')

# port-forward
kubectl -n dmz port-forward svc/upload-api 18080:80 &

# 실행
python3 tests/accuracy/run_accuracy.py \
  --endpoint http://localhost:18080 \
  --token "$TOKEN" \
  --fixtures tests/accuracy/fixtures \
  --out tests/accuracy/reports \
  --commit $(git rev-parse --short HEAD)
```

---

## 측정 지표 설명

| 지표 | 정의 | 해석 기준 |
|------|------|---------|
| **exact_match_rate** | 정규화 후 edit_distance=0 필드 수 / 전체 필드 수 | 높을수록 좋음. 정형 필드 강한 기준 |
| **tolerance_match_rate** | max_edit_distance 허용 범위 내 필드 수 / 전체 필드 수 | 실용적 허용 기준 |
| **avg_edit_distance** | 필드별 Levenshtein 거리 평균 | 낮을수록 좋음. 0에 가까울수록 정확 |
| **char_accuracy** | `1 - (Σ edit_dist / Σ char_count)` | CLOVA/ABBYY 동일 공식. ≥99% = 상업용 수준 |
| **low_conf_rate** | OCR confidence < 0.5 항목 비율 | EasyOCR 자가 진단. 높으면 이미지 품질 문제 |

### Phase별 목표

| Phase | char_accuracy | exact_match_rate | 비고 |
|-------|--------------|-----------------|------|
| B-2 EasyOCR CPU 기준선 | 측정값 (baseline.md 참조) | 측정값 | 재학습 없음 |
| Phase 1 PaddleOCR GPU | ≥97% | ≥85% | Triton GPU 도입 |
| Phase 1 파인튜닝 | ≥99% | ≥95% | 1만장 도메인 데이터 |
| 상업용 동등 | ≥99.5% | ≥98% | 정형 문서 기준 |

---

## 결과 해석

### stdout 테이블

```
║ image                          │ category       │   exact │     tol │  avg_d │  char_acc │ items │ status    ║
║ id-korean-01                   │ id-card        │     4/5 │     5/5 │    0.4 │    98.2%  │    12 │ OK        ║
```

- **exact**: 정확히 일치한 필드 / 전체 필드 수
- **tol**: tolerance 허용 범위 내 필드 / 전체
- **avg_d**: 평균 편집 거리
- **char_acc**: 문자 단위 정확도

### JSON 리포트 (`reports/baseline-<commit>.json`)

```json
{
  "meta": { "commit": "abc1234", "engine": "EasyOCR", "langs": ["ko", "en"] },
  "summary": {
    "char_accuracy": 0.9234,
    "exact_match_rate": 0.7143,
    ...
  },
  "samples": [ { "image": "...", "fields": [...] } ]
}
```

---

## EasyOCR 전체 라인 반환 관련 주의사항

EasyOCR는 라벨을 포함한 전체 라인을 반환합니다. 예:

- PNG 텍스트: `"면허번호: 11-00-123456-79"`
- answer.json `text`: `"11-00-123456-79"` (라벨 제외 값만)

`metrics.py`의 `find_best_match()`는 substring-window 슬라이딩으로 이를 처리합니다. 기대값 길이와 동일한 창을 OCR 텍스트 위에 슬라이딩하여 최소 편집 거리 창을 찾습니다.

**단기 정밀도 한계 (known issues)**:

- 숫자 전용 짧은 필드 (예: `"10"`)는 ambiguity가 높아 false positive 가능
- 특수문자(`₩`, `×`)는 EasyOCR가 인식하지 못할 수 있음
- 한영 혼합 문서(`mixed-01`)는 char_accuracy가 상대적으로 낮을 수 있음

---

## 재실행 및 비교

```bash
# 새 커밋 후 재실행
bash tests/accuracy/run.sh

# 두 리포트 JSON 비교
python3 -c "
import json
a = json.load(open('tests/accuracy/reports/baseline-<commit1>.json'))
b = json.load(open('tests/accuracy/reports/baseline-<commit2>.json'))
print('char_accuracy 변화:', a['summary']['char_accuracy'], '->', b['summary']['char_accuracy'])
"
```

---

## 관련 파일

- 샘플 생성 스크립트: `tests/images/gen_sample.py`
- E2E smoke 스크립트: `tests/smoke/upload_api_e2e_smoke.sh`
- 정확도 목표 문서: `docs/accuracy-targets.md` (B2-T3에서 생성 예정)
