# OCR 엔진 비교: EasyOCR vs PaddleOCR PP-OCRv5

생성일: 2026-04-22  
EasyOCR baseline commit: `36632cf`  
PaddleOCR baseline commit: `c5c598f`

## 요약

| 지표 | EasyOCR 1.7.1 | PaddleOCR PP-OCRv5 | 개선 |
|------|--------------|---------------------|------|
| **char_accuracy** | 95.8% | **99.3%** | +3.5%p |
| **exact_match_rate** | 78.8% | **93.9%** | +15.1%p |
| tolerance_rate | 90.9% | 95.5% | +4.6%p |
| avg_edit_distance | - | 0.06 | - |
| field_recall | - | 100.0% | - |
| low_conf_rate | - | 0.0% | - |
| 샘플 수 | 10/10 성공 | 10/10 성공 | = |

**권고: PaddleOCR PP-OCRv5로 전환.** Phase 1 MVP 목표(char≥97%, exact≥85%) 충족.

## 카테고리별 상세 (PaddleOCR PP-OCRv5)

| 카테고리 | n | char_acc | exact_rate |
|---------|---|---------|-----------|
| biz-license | 2 | 100.0% | 100.0% |
| contract | 1 | 98.1% | 83.3% |
| driver-license | 1 | 100.0% | 100.0% |
| id-card | 2 | 100.0% | 100.0% |
| invoice | 1 | 98.7% | 88.9% |
| mixed | 1 | 97.8% | 71.4% |
| receipt | 2 | 100.0% | 100.0% |

## 실패/미달 케이스 분석 (PaddleOCR)

### contract-01: `₩5,000,000` 인식 실패
- 인식결과: `약금액:금오백만원정(w5,000,000)` — `₩` → `w` 오인식 (1 edit distance)
- 원인: 원화 기호 `₩`는 폰트 렌더링에서 w와 유사 → 특수기호 인식 한계
- 대응: post-processing 정규화 레이어 추가 가능 (Phase 1 B-3)

### invoice-01: `거래명세서(Invoice)` → `거래명세서(Inv이ice)` 오인식
- `o` → `이` 오인식 (1 edit distance) — 영문 소문자 o와 한글 이 혼재 문서
- 원인: 한/영 혼재 영역 혼동. PP-OCRv5_mobile_rec 모델 한계 가능성
- 대응: PP-OCRv5_server_rec (대형 rec 모델)으로 교체 시 개선 예상

### mixed-01: `₩399,000` → `W399,000` 오인식 및 `UItraHD` (I→l)
- 동일한 `₩` → `W` 문제 + `U`ltra → `U`ltra (I vs l) 폰트 혼동
- 대응: 통화기호 정규화 후처리

## PaddleOCR 이미지 정보

- 버전: `paddlepaddle==3.0.0` + `paddleocr==3.5.0`
- 모델: PP-OCRv5_server_det + korean_PP-OCRv5_mobile_rec + PP-LCNet 방향분류
- 이미지 크기: 2.01GB
- 빌드 시간: ~2분 30초
- Pod 기동 시간: ~98초 (Ready 기준)
- 메모리 요청: 2Gi / 한도 4Gi

## 권고사항

1. **즉시 전환**: `ocr-worker-paddle` → `ocr-worker` 기본 엔진으로 승격 (Phase 1 B-3)
2. **후처리 추가**: 통화기호 `₩/₩` 정규화 미들웨어 (Phase 1)
3. **rec 모델 업그레이드 검토**: `PP-OCRv5_server_rec` → exact rate 추가 개선 기대
4. **이미지 최적화**: 2.01GB → 멀티스테이지 빌드로 ~1.5GB 목표 (Phase 1 B-3)
