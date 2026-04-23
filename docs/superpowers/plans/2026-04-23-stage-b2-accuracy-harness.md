# Stage B-2 Accuracy Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OCR 결과의 per-field 정확도를 반복 측정·비교 가능한 자동 harness 구축. 상업용 수준 도달 여부를 수치로 판단 가능한 기준선 확보.

**Architecture:** 10장 한글 샘플 이미지(정형 3종 + 반정형 2종) + 기대 답안 JSON + 측정 스크립트(Python). 각 이미지에 대해 upload-api POST → GET 폴링 → `items[].text` 배열을 답안과 비교해 field-level precision/recall/exact-match/Levenshtein 계산 → `reports/accuracy-<ts>.json` + stdout 요약 테이블. 기준선은 commit 해시 + tag로 스냅샷 보관.

**Tech Stack:** Python 3.11 · Pillow(샘플 생성) · 기본 stdlib (difflib, unicodedata) · `python-Levenshtein` 선택 · bash curl 래퍼 · Keycloak cluster-internal token (T5 패턴 재사용).

**YAGNI 경계:**
- GPU 재학습·파인튜닝 제외 (측정만)
- 멀티 라운드 통계 분석 제외 (단일 실행 + 리포트)
- Web UI 대시보드 제외 (CLI 표 + JSON)
- Bbox IoU 측정은 Nice-to-have (텍스트 정확도 우선)

---

### Task B2-T1: 샘플 이미지 10장 + 답안 JSON

**Files:**
- Modify: `tests/images/gen_sample.py` (다종 이미지 생성 확장)
- Create: `tests/accuracy/fixtures/` 디렉터리 (10 PNG + 10 `<name>.answer.json`)
- Create: `tests/accuracy/fixtures/README.md` (각 샘플 카테고리 / 의도)

**답안 JSON 포맷**:
```json
{
  "image": "id-korean-01.png",
  "category": "id-card",   // id-card | driver-license | biz-license | invoice | contract
  "expected_fields": [
    {"key": "doc_title",  "text": "주민등록증",              "required": true},
    {"key": "name",        "text": "홍길동",                   "required": true},
    {"key": "rrn",         "text": "900101-1234567",           "required": true, "pattern": "checksum"},
    {"key": "address",     "text": "서울특별시 강남구 테헤란로 123", "required": true},
    {"key": "issue_date",  "text": "2020년 03월 15일 발급",      "required": true}
  ],
  "tolerances": {
    "exact_match_required": ["doc_title", "rrn"],
    "whitespace_normalized": true,
    "max_edit_distance": {"name": 1, "address": 3}
  }
}
```

- [ ] **Step 1: 샘플 카테고리 10장 선정**

| # | 카테고리 | 파일명 | 특징 |
|---|---|---|---|
| 1 | 주민등록증 | id-korean-01.png | 기존 sample-id-korean.png 리네임 |
| 2 | 주민등록증 | id-korean-02.png | 다른 이름·주소·생년 |
| 3 | 운전면허증 | driver-license-01.png | 주민번호·면허번호·유효기간 |
| 4 | 사업자등록증 | biz-license-01.png | 법인명·등록번호·업종 |
| 5 | 사업자등록증 | biz-license-02.png | 개인사업자 포맷 |
| 6 | 영수증 | receipt-01.png | 상호·금액·날짜·VAT |
| 7 | 영수증 | receipt-02.png | 다품목·합계 |
| 8 | 계약서 조각 | contract-01.png | 당사자·금액·서명란 |
| 9 | 송장 | invoice-01.png | 품목·단가·수량·합계 |
| 10 | 혼합(한영숫자) | mixed-01.png | 한영 병기·특수문자 |

- [ ] **Step 2: gen_sample.py 확장**

`LINES` 리스트를 `SAMPLES` dict로 교체:
```python
SAMPLES = {
    "id-korean-01": [
        ("주민등록증", 60),
        ("홍길동 (洪吉童)", 40),
        ("900101-1234567", 40),
        ("서울특별시 강남구 테헤란로 123", 36),
        ("2020년 03월 15일 발급", 32),
    ],
    "id-korean-02": [
        ("주민등록증", 60),
        ("김영수", 40),
        ("830515-1987654", 40),
        ("부산광역시 해운대구 센텀2로 45", 36),
        ("2018년 11월 02일 발급", 32),
    ],
    # ... 10개
}

def render_sample(name: str, lines, out_dir: Path) -> None:
    W, H = 900, 500
    img = Image.new("RGB", (W, H), "white")
    draw = ImageDraw.Draw(img)
    y = 40
    for text, size in lines:
        font = ImageFont.truetype(find_korean_font(), size)
        draw.text((60, y), text, fill="black", font=font)
        y += size + 24
    out = out_dir / f"{name}.png"
    img.save(out)
    print(f"wrote {out}")

def main():
    out = Path(__file__).parent.parent / "accuracy" / "fixtures"
    out.mkdir(parents=True, exist_ok=True)
    for name, lines in SAMPLES.items():
        render_sample(name, lines, out)
```

- [ ] **Step 3: 답안 JSON 10개 직접 작성**

`tests/accuracy/fixtures/<name>.answer.json` 10개. 각각 expected_fields + tolerances.

- [ ] **Step 4: 기존 sample-id-korean.png 리네임/삭제 처리**

B-0/B-1 smoke에서 `tests/images/sample-id-korean.png`가 사용됨. fixtures 하위로 이동시키지 말고 복사본으로 유지 (smoke 호환성).

- [ ] **Step 5: Commit**

```bash
git add tests/images/gen_sample.py tests/accuracy/
git commit -m "feat(b2/T1): accuracy fixtures — 10 images + answer JSON"
```

---

### Task B2-T2: 정확도 측정 하니스

**Files:**
- Create: `tests/accuracy/run_accuracy.py`
- Create: `tests/accuracy/metrics.py`
- Create: `tests/accuracy/reports/` (gitignore 제외, 실행 결과만)
- Create: `tests/accuracy/README.md`
- Create: `.gitignore` 항목 추가 (`tests/accuracy/reports/*.json` 제외는 선택)

**측정 지표:**

| 지표 | 정의 | 용도 |
|---|---|---|
| exact_match_rate | 정확히 일치한 필드 수 / 필수 필드 수 | 정형 필드 강한 기준 |
| avg_edit_distance | Levenshtein distance 평균 / 필드 | 오인식 심각도 |
| char_accuracy | 1 - (총 edit distance / 총 char 수) | CLOVA·ABBYY와 동일 공식 |
| field_recall | 탐지된 필드 수 / 기대 필드 수 | 누락 탐지 |
| low_conf_rate | confidence<0.5 필드 비율 | 자가 진단 |

- [ ] **Step 1: metrics.py 작성**

```python
from difflib import SequenceMatcher
import re, unicodedata

def normalize(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    s = re.sub(r"\s+", "", s)
    return s.strip()

def levenshtein(a: str, b: str) -> int:
    # 간단한 DP; Python-Levenshtein 없어도 동작
    if len(a) < len(b): a, b = b, a
    if not b: return len(a)
    prev = list(range(len(b)+1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cost = 0 if ca==cb else 1
            cur.append(min(cur[-1]+1, prev[j]+1, prev[j-1]+cost))
        prev = cur
    return prev[-1]

def match_field(expected: str, items: list[dict]) -> tuple[str, float]:
    """items 중 expected와 가장 가까운 text 반환 (matched_text, edit_distance)."""
    exp = normalize(expected)
    best = None
    best_d = 10**9
    for it in items:
        got = normalize(it["text"])
        d = levenshtein(exp, got)
        if d < best_d:
            best_d = d
            best = it["text"]
    return best or "", best_d
```

- [ ] **Step 2: run_accuracy.py 작성**

- 인자: `--endpoint http://localhost:18080` `--token <bearer>` `--fixtures tests/accuracy/fixtures` `--out tests/accuracy/reports`
- 각 이미지: POST /documents → GET 폴링(최대 60s) → items 수집
- 답안과 매칭: field별 edit_distance, exact_match 집계
- 총 지표 집계 → stdout 표 + JSON 저장

```python
# 출력 예시
# ╔═══════════════════════════════════╤═══════╤═══════╤══════════╗
# ║ image                             │ exact │ edit  │ char_acc ║
# ╠═══════════════════════════════════╪═══════╪═══════╪══════════╣
# ║ id-korean-01                      │  4/5  │  0.4  │ 98.2%    ║
# ║ id-korean-02                      │  5/5  │  0.0  │100.0%    ║
# ║ driver-license-01                 │  3/6  │  1.8  │ 92.4%    ║
# ...
# ╠═══════════════════════════════════╪═══════╪═══════╪══════════╣
# ║ SUMMARY (10 images, 54 fields)    │ 38/54 │ 1.12  │ 95.3%    ║
# ╚═══════════════════════════════════╧═══════╧═══════╧══════════╝
```

- [ ] **Step 3: Bash 래퍼 `tests/accuracy/run.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Keycloak cluster-internal token 발급(T5 smoke 패턴)
TOKEN=$(kubectl -n admin exec keycloak-0 -- sh -c '
  KC_PASS=$(cat /opt/bitnami/keycloak/conf/...  # (T5 smoke와 동일한 재사용 로직)
  ...
')
kubectl -n dmz port-forward svc/upload-api 18080:80 &
PF=$!
trap "kill $PF 2>/dev/null || true" EXIT
sleep 3
python3 tests/accuracy/run_accuracy.py \
  --endpoint http://localhost:18080 \
  --token "$TOKEN" \
  --fixtures tests/accuracy/fixtures \
  --out tests/accuracy/reports
```

- [ ] **Step 4: 초기 baseline 실행**

```bash
bash tests/accuracy/run.sh
```

결과 저장: `tests/accuracy/reports/baseline-<commit>.json` + stdout 캡처를 `tests/accuracy/reports/baseline.md`로 보관.

- [ ] **Step 5: Commit + baseline 태깅**

```bash
git add tests/accuracy/*.py tests/accuracy/run.sh tests/accuracy/README.md tests/accuracy/reports/baseline.md
git commit -m "feat(b2/T2): accuracy harness + EasyOCR 1.7.1 baseline"
git tag -a b2-baseline -m "EasyOCR 1.7.1 baseline: char_acc=<X>% on 10 Korean samples"
```

---

### Task B2-T3: README 요약 + Phase 1 목표 수치화

**Files:**
- Modify: `services/upload-api/README.md` (accuracy 섹션 추가)
- Create: `docs/accuracy-targets.md` (Phase별 목표)

- [ ] **Step 1: Phase별 목표 문서화**

| Phase | 대상 | char_accuracy | exact_match | 비고 |
|---|---|---|---|---|
| B-2 baseline | EasyOCR ko+en CPU, OrbStack | 측정 예정(~90-95%?) | 측정 예정 | 재학습 없음 |
| B-3 이후 | 동일 + UI 검증 | 동일 | 동일 | UI 수동 QA |
| Phase 1 MVP | PaddleOCR PP-OCRv4 복원 | ≥97% | ≥85% | Triton GPU |
| Phase 1 파인튜닝 | PP-OCRv4 + 1만장 도메인 | ≥99% | ≥95% | 정형 |
| 상업용 동등 | Phase 1 후반 | ≥99.5% | ≥98% | 정형, 반정형은 -2%p |

- [ ] **Step 2: README accuracy 섹션 추가**

설명 + `bash tests/accuracy/run.sh` 실행법 + 리포트 해석법.

- [ ] **Step 3: docs-sync + Commit**

```bash
make docs-sync
git add services/upload-api/README.md docs/accuracy-targets.md Documents/accuracy-targets.docx
git commit -m "feat(b2/T3): accuracy targets + harness docs"
```

---

## Self-Review

- 모든 필수 필드에 답안 JSON 존재? (10×~5 fields = 50+)
- metrics.py가 NFKC 정규화 + whitespace 제거 적용?
- run_accuracy.py가 실제 upload-api + OCR worker 경로를 호출 (stub 아님)?
- baseline 태그에 구체 수치 포함?
- Phase 1 목표가 설계 스펙(§3.3)과 일치?

## 누락 요주의 (다음 Stage 후보)

- B-3 Next.js UI (업로드 + bbox 오버레이)
- PaddleOCR 복원 (Linux-native, Phase 1)
- HITL(Label Studio) 연동
- 정기 baseline 재실행 CI
