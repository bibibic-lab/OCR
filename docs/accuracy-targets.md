# OCR 정확도 목표 및 측정 기준

> **정본 위치**: `docs/accuracy-targets.md`  
> **최초 작성**: 2026-04-22  
> **기준 커밋**: `11fee76` (b2-baseline tag)  
> **관련 스펙**: `docs/superpowers/specs/2026-04-18-ocr-solution-design.md` §3.3

---

## 1. 목적

OCR 파이프라인이 상업용 수준(CLOVA OCR, ABBYY FineReader 동등)에 도달했는지를 **재현 가능하고 자동화된 방식**으로 측정하기 위한 정확도 harness 운영 기준을 정의합니다.

### 측정이 필수인 이유

- 엔진 교체(PaddleOCR → EasyOCR → PP-OCRv4 등) 시 회귀 여부를 즉시 판단
- 도메인 파인튜닝 효과의 정량적 검증
- CI gate로 활용 — `char_accuracy < 0.95` 이면 PR 병합 차단
- 상업용 SaaS 대비 정확도 격차 추적 및 의사결정 근거 제공

---

## 2. 지표 정의

### 2.1 핵심 지표

| 지표 | 정의 | 계산식 |
|------|------|--------|
| `char_accuracy` | 문자 단위 정확도 | `1 - (Σ edit_distance) / (Σ char_count)` |
| `exact_match_rate` | 필드 단위 완전일치 비율 (엄격 지표) | `exact_matched / total_fields` |
| `field_recall` | 부분일치라도 탐지 성공한 필드 비율 | `within_tolerance / total_fields` |
| `avg_edit_distance` | 필드당 평균 편집거리 (Levenshtein) | `Σ edit_distance / total_fields` |
| `low_conf_rate` | 낮은 신뢰도 바운딩박스 비율 | `low_conf_count / total_bbox` |

### 2.2 tolerance 기준

`is_within_tolerance`: 편집거리가 `ceil(char_count × 0.1)` 이하인 경우 허용 (10% 오차 이내)

### 2.3 상업용 엔진 비교 공식

```
gap_to_commercial = commercial_char_accuracy - ours_char_accuracy
CLOVA OCR 기준:    gap_to_commercial = 0.995 - char_accuracy
ABBYY FineReader:  gap_to_commercial = 0.998 - char_accuracy
```

상업용 동등 달성 조건: `char_accuracy ≥ 0.995` AND `exact_match_rate ≥ 0.98`

---

## 3. Phase별 목표

### 3.1 목표 표

| Phase | 엔진/설정 | `char_accuracy` | `exact_match_rate` | `field_recall` | 비고 |
|---|---|---|---|---|---|
| **현재 (b2-baseline)** | EasyOCR 1.7.1 ko+en, CPU, OrbStack amd64 emulation | **95.8%** | **78.8%** | **100.0%** | 10개 샘플, 66 fields, 525 chars |
| Phase 1 MVP | PaddleOCR PP-OCRv4 복원, Triton GPU, Linux-native | ≥97% | ≥85% | ≥90% | 스펙 §3.3 기반 |
| Phase 1 파인튜닝 | + 도메인 1만 장 재학습 (Donut, LiLT) | ≥99% | ≥95% | ≥95% | 정형 문서 기준 |
| 상업용 동등 | Phase 1 후반 | ≥99.5% | ≥98% | ≥98% | 정형; 반정형은 -2%p |

### 3.2 샘플 구성 (b2-baseline 기준)

| 카테고리 | 샘플 수 | 총 필드 수 | exact_matched | char_accuracy (평균) |
|---|---|---|---|---|
| biz-license | 2 | 14 | 13 | 99.1% |
| contract | 1 | 6 | 5 | 88.5% |
| driver-license | 1 | 6 | 5 | 98.1% |
| id-card | 2 | 10 | 7 | 97.0% |
| invoice | 1 | 9 | 8 | 98.7% |
| mixed | 1 | 7 | 3 | 91.2% |
| receipt | 2 | 14 | 11 | 95.5% |
| **합계** | **10** | **66** | **52** | **95.8%** |

---

## 4. 현재 한계 (b2-baseline 확인 사항)

baseline 실행(`commit 11fee76`) 분석에서 다음 5개 패턴이 반복적으로 확인됩니다.

### 4.1 ₩ → w 오인식 (유니코드 통화기호)

- **증상**: `₩5,000,000` → `버5,OOO,OO0`, `₩ 399,000` → `w 399,000`
- **원인**: EasyOCR이 U+20A9 (₩, WON SIGN)를 라틴 소문자 w 또는 한글 자모로 혼동
- **영향 필드**: `contract_amount`, `price_krw` — `exact_match_required: true` 필드이므로 exact_match_rate에 직접 영향
- **우선순위**: High — 금액 필드 정확도는 상업 서비스에서 critical

### 4.2 O/0 혼동 (숫자/영문)

- **증상**: `5OOmL` (500mL의 0→O), `OOO,OO0` (0을 O로 혼용)
- **원인**: CPU 모드에서 낮은 해상도 픽셀 처리 시 O와 0의 획 두께 유사성
- **영향 필드**: 단가·수량·모델번호 등 숫자 포함 필드
- **우선순위**: Medium — tolerance 내 포함되는 경우가 많으나 exact_match 실패

### 4.3 한영 혼합 라인 한글 드롭

- **증상**: `혼합 문서 / Mixed Document` → `Mixed Document` (한글 파트 누락)
- **원인**: EasyOCR ko+en 동시 추론 시 한글-영문 혼합 라인에서 언어 분기 오류
- **영향 필드**: `doc_title` 등 혼합 텍스트 필드
- **우선순위**: Medium — 문서 분류 정확도에 간접 영향

### 4.4 EasyOCR CPU 모드 정확도 한계

- **증상**: 전반적 char_accuracy 95.8% — Phase 1 목표(≥97%)에 1.2%p 미달
- **원인**: OrbStack amd64 emulation + CPU 전용 추론 → 해상도 저하·속도 제한으로 전처리 품질 감소
- **영향**: 모든 카테고리에 분산된 편집거리 발생
- **우선순위**: High — GPU + Linux-native 환경(Phase 1 MVP) 전환으로 해결 예정

### 4.5 fixtures 내 label-stripping 의존성

- **증상**: `party_b` expected `프리랜서 최수진`이나 matched에 `올:` prefix 포함 — label 포함 매칭으로 통과
- **원인**: 정답 레이블(expected)이 label prefix를 제거한 순수 값이지만, OCR 결과에 label이 포함된 채로 `is_within_tolerance` 판정
- **영향**: field_recall 과대 계산 가능성 (현재 100.0%는 label 포함 매칭 결과)
- **우선순위**: Medium — 테스트 harness 개선 시 정정 필요 (B2-T5에서 처리 예정)

---

## 5. 회귀 방지

### 5.1 b2-baseline tag

```bash
# baseline tag 확인
git tag | grep b2-baseline

# baseline 리포트 경로
tests/accuracy/reports/baseline-11fee76.json
```

### 5.2 CI 연결 방안 (scaffold)

현재(2026-04-22): 수동 실행 (`bash tests/accuracy/run.sh`)

Phase 1 목표:
- GitHub Actions workflow 추가: `.github/workflows/accuracy-gate.yml`
- 트리거: `push` to `main`, `pull_request` targeting `main`
- Gate 조건:
  - `char_accuracy < 0.95` → fail
  - `exact_match_rate < 0.78` (현재 baseline 이하) → fail
- 리포트 아티팩트: `tests/accuracy/reports/` 디렉토리를 Actions artifact로 업로드

재검토 조건: Phase 1 MVP 완료 시점(EasyOCR → PP-OCRv4 전환 후) CI gate 임계값을 Phase 1 MVP 목표치(≥97%, ≥85%)로 상향 조정.  
책임자: 프로젝트 리드.

---

## 6. 참고 링크

| 항목 | 경로 / 출처 |
|---|---|
| 솔루션 설계서 §3.3 (정확도 기준) | `docs/superpowers/specs/2026-04-18-ocr-solution-design.md` §3.3 |
| Stage B-2 구현 계획 | `docs/superpowers/plans/2026-04-23-stage-b2-accuracy-harness.md` |
| baseline 리포트 (11fee76) | `tests/accuracy/reports/baseline-11fee76.json` |
| accuracy harness 실행 스크립트 | `tests/accuracy/run.sh` |
| EasyOCR 공식 문서 | https://github.com/JaidedAI/EasyOCR |
| Levenshtein distance (Wikipedia) | https://en.wikipedia.org/wiki/Levenshtein_distance |
| CLOVA OCR 벤치마크 | https://clova.ai/ocr (외부, 참고용) |
