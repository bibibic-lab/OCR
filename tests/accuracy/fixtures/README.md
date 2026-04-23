# Accuracy Fixtures — 10종 한글 OCR 샘플

> **생성 스크립트**: `tests/images/gen_sample.py --mode fixtures`  
> **생성일**: 2026-04-22  
> **용도**: Stage B-2 OCR 정확도 harness (`tests/accuracy/run_accuracy.py`)

---

## 샘플 카테고리 목록

| # | 파일명 (PNG) | 카테고리 | 이미지 크기 | 필수 필드 수 | 특징 |
|---|---|---|---|---|---|
| 1 | `id-korean-01.png` | `id-card` | 900×500 | 5 | 주민등록증 기본형 (홍길동) |
| 2 | `id-korean-02.png` | `id-card` | 900×500 | 5 | 주민등록증 변형 (김영수, 부산) |
| 3 | `driver-license-01.png` | `driver-license` | 900×560 | 6 | 운전면허증 — 면허번호·유효기간 포함 |
| 4 | `biz-license-01.png` | `biz-license` | 1000×600 | 7 | 사업자등록증 법인 (주식회사) |
| 5 | `biz-license-02.png` | `biz-license` | 1000×580 | 7 | 사업자등록증 개인 (단독 상호) |
| 6 | `receipt-01.png` | `receipt` | 600×700 | 6 | 영수증 단품 (카페) |
| 7 | `receipt-02.png` | `receipt` | 620×820 | 8 | 영수증 다품목 + 소계·합계 |
| 8 | `contract-01.png` | `contract` | 1200×500 | 6 | 용역 계약서 조각 — 당사자·금액·기간 |
| 9 | `invoice-01.png` | `invoice` | 1000×680 | 9 | 거래 명세서 — 품목·단가·수량·합계 |
| 10 | `mixed-01.png` | `mixed` | 1000×600 | 7 | 한영숫자 혼합 — 특수문자·URL·전화번호 |

**총 필수 필드**: 70개 (required: true 기준)

---

## 의도 및 설계 원칙

### 현실성
- 실제 서식 레이아웃의 픽셀 완벽 복제가 아닌, OCR 엔진이 실제로 읽어야 할 텍스트 중심 렌더링.
- Pillow + AppleSDGothicNeo.ttc (macOS) / NotoSansCJK (Linux) 폰트 사용.
- 폰트 크기: 28–60pt, 라인 간격 24px — 300 DPI 동등 선명도.

### 다양성 확보 대상
- **스크립트 혼합**: 한국어 전용(1–5), 한영 병기(3·8–10), 특수문자/이모지(7·10)
- **레이아웃**: 세로형(영수증 6–7), 가로형(계약서 8), 표형 데이터(송장 9)
- **이미지 크기**: 600×700(소) ~ 1200×500(대)
- **가상 데이터**: RRN·등록번호·금액 등 모두 허구. PII 아님.

### RRN 형식
`YYMMDD-NNNNNNN` (6자리-7자리). 체크섬 유효성 미적용 — OCR 텍스트 인식만 평가 대상.

---

## 답안 JSON 스키마

각 `<name>.answer.json` 파일의 구조:

```json
{
  "image": "<name>.png",
  "category": "<category>",
  "expected_fields": [
    {
      "key": "<field_key>",
      "text": "<expected OCR text>",
      "required": true
    }
  ],
  "tolerances": {
    "exact_match_required": ["<key1>", "<key2>"],
    "whitespace_normalized": true,
    "max_edit_distance": {
      "<key>": <int>
    }
  }
}
```

### 필드 설명

| 필드 | 타입 | 설명 |
|---|---|---|
| `image` | string | 대응하는 PNG 파일명 |
| `category` | string | 문서 종류 식별자 |
| `expected_fields[].key` | string | harness가 찾을 필드 식별자 |
| `expected_fields[].text` | string | OCR이 반환해야 할 기대 텍스트 |
| `expected_fields[].required` | bool | false = 누락 허용(field_recall 분모 제외) |
| `tolerances.exact_match_required` | string[] | 이 필드는 edit_distance=0 이어야 점수 인정 |
| `tolerances.whitespace_normalized` | bool | 비교 전 공백 normalize 적용 여부 |
| `tolerances.max_edit_distance` | object | 키별 허용 최대 Levenshtein distance |

### 카테고리별 주요 필드 키

| 카테고리 | 공통 키 | 고유 키 |
|---|---|---|
| `id-card` | `doc_title`, `name`, `rrn` | `address`, `issue_date` |
| `driver-license` | `doc_title`, `name`, `rrn` | `license_no`, `license_type`, `expiry_date` |
| `biz-license` | `doc_title`, `reg_no` | `company_name`, `ceo_name`, `business_type`, `address`, `open_date` |
| `receipt` | `doc_title`, `date`, `total` | `store_name`, `item*_name`, `item*_price`, `subtotal` |
| `contract` | `doc_title` | `party_a`, `party_b`, `contract_amount`, `start_date`, `end_date` |
| `invoice` | `doc_title`, `total` | `supplier`, `supplier_reg`, `buyer`, `issue_date`, `item*_name/price/qty` |
| `mixed` | `doc_title` | `customer_no`, `product_name`, `price_krw`, `price_usd`, `resolution`, `warranty` |

---

## 파일 재생성 방법

```bash
# 프로젝트 루트에서 실행
python3 tests/images/gen_sample.py --mode fixtures

# 출력 디렉터리 지정 시
python3 tests/images/gen_sample.py --mode fixtures --out /tmp/my-fixtures

# B-0 smoke 이미지(sample-id-korean.png)와 동시 생성
python3 tests/images/gen_sample.py --mode all
```

---

## 주의사항

- `tests/images/sample-id-korean.png` — B-0/B-1 smoke 테스트 전용. 이 폴더로 이동 금지.
- `<name>.answer.json` 수정 시 `text` 값이 해당 PNG의 실제 렌더링 텍스트와 반드시 일치해야 함.
- 이미지 재생성 시 폰트 경로가 달라질 경우 텍스트 렌더링이 달라질 수 있음 → baseline 재실행 필요.
