# PaddleOCR PP-OCRv5 운영 런북

작성일: 2026-04-22  
적용 환경: OCR 통합 플랫폼 — kind cluster `ocr-dev` (Intel Mac x86_64, OrbStack)  
워크로드: `ocr-worker-paddle` Deployment, `processing` namespace  
담당 Phase: Phase 1 #4 — PaddleOCR PP-OCRv4/v5 복원

---

## 1. 구성 요약

| 항목 | 값 |
|------|---|
| 이미지 | `ocr-worker-paddle:v0.1.0` |
| 이미지 크기 | 2.01GB |
| 엔진 | PaddleOCR 3.5.0 (PP-OCRv5) |
| PaddlePaddle | 3.0.0 |
| 모델 | PP-OCRv5_server_det + korean_PP-OCRv5_mobile_rec + PP-LCNet 방향분류 + UVDoc 보정 |
| 언어 | 한국어 (korean) |
| CPU 요건 | AVX/AVX2 필수 (Intel Mac OrbStack 환경 확인됨) |
| Service | `ocr-worker-paddle.processing.svc.cluster.local:80` → container 8000 |
| 리소스 요청 | 500m CPU, 2Gi memory |
| 리소스 한도 | 2 CPU, 4Gi memory |
| 초기 기동 시간 | ~90-120초 (모델 로딩) |

---

## 2. 버전 선정 배경

### 2.1 SEGV 원인 (기존 paddlepaddle 2.6.2)

기존 `paddlepaddle==2.6.2 + paddleocr==2.7.3`은 python:3.11-slim에서 `double free or corruption` SIGABRT 발생.

- 원인: libgomp 버전 충돌 및 paddleocr 2.7.x의 PyMuPDF 의존성 빌드 실패
- 확인 명령: `docker run --rm python:3.11-slim bash -c "pip install paddlepaddle==2.6.2 paddleocr==2.7.3 && python -c 'from paddleocr import PaddleOCR'"`

### 2.2 작동 조합 (검증일 2026-04-22)

```
paddlepaddle==3.0.0 + paddleocr==3.5.0 (PP-OCRv5)
python:3.11-slim + libgomp1 + libglib2.0-0 + libgl1 + libsm6 + libxext6 + libxrender1
```

### 2.3 API 변경사항 (paddleocr 2.x → 3.x)

| 2.x API | 3.x API |
|---------|---------|
| `PaddleOCR(use_angle_cls=True, use_gpu=False)` | `PaddleOCR(use_textline_orientation=True)` |
| `ocr.ocr(path, cls=True)` | `ocr.predict(path)` |
| 반환: `[[bbox, (text, conf)], ...]` | 반환: `[{"rec_texts": [...], "rec_scores": [...], "rec_polys": [...]}]` |

---

## 3. 이미지 빌드

### 3.1 빌드 명령

```bash
cd /Users/jimmy/_Workspace/ocr/services/ocr-worker-paddle
DOCKER_HOST=unix:///Users/jimmy/.orbstack/run/docker.sock \
docker build --platform linux/amd64 -t ocr-worker-paddle:v0.1.0 .
```

- 빌드 시간: ~2분 30초
- 모델 다운로드: 빌드 중 자동 (~600MB, huggingface-hub / aistudio-sdk 경유)
- 환경 변수: `PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True` (connectivity check 우회)

### 3.2 kind 로드

```bash
DOCKER_HOST=unix:///Users/jimmy/.orbstack/run/docker.sock \
kind load docker-image ocr-worker-paddle:v0.1.0 --name ocr-dev
```

- 로드 시간: ~5분 (2GB 이미지, 4노드)

---

## 4. 배포

```bash
kubectl apply -f infra/manifests/ocr-worker-paddle/deployment.yaml
kubectl apply -f infra/manifests/ocr-worker-paddle/network-policies.yaml
```

### 4.1 Pod Ready 확인

```bash
kubectl -n processing wait --for=condition=Ready \
  pod -l app.kubernetes.io/name=ocr-worker-paddle --timeout=180s
```

### 4.2 로그 확인

```bash
kubectl -n processing logs -l app.kubernetes.io/name=ocr-worker-paddle --tail=20
```

정상 기동 시 마지막 줄:
```
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8000
```

---

## 5. 헬스체크 / Smoke

### 5.1 port-forward

```bash
kubectl -n processing port-forward svc/ocr-worker-paddle 18888:80
```

### 5.2 healthz / readyz

```bash
curl http://localhost:18888/healthz
# {"status":"ok"}

curl http://localhost:18888/readyz
# {"status":"ready","engine":"PaddleOCR PP-OCRv5","langs":"ko,en"}
```

### 5.3 POST /ocr

```bash
curl -F "file=@tests/images/sample-id-korean.png" http://localhost:18888/ocr | jq .
```

예상 응답:
```json
{
  "filename": "sample-id-korean.png",
  "engine": "PaddleOCR PP-OCRv5",
  "langs": ["ko", "en"],
  "count": 5,
  "items": [
    {"text": "주민등록증", "confidence": 0.9998, "bbox": [[12,26],[309,30],[308,102],[11,98]]},
    ...
  ]
}
```

### 5.4 자동화 smoke

```bash
bash tests/smoke/ocr_worker_paddle_smoke.sh
```

---

## 6. 정확도 harness

### 6.1 PaddleOCR 정확도 측정 (direct 모드)

port-forward 후:
```bash
bash tests/accuracy/run-paddle.sh
# 또는 verbose:
bash tests/accuracy/run-paddle.sh --verbose
```

결과 파일: `tests/accuracy/reports/paddle-baseline-<commit>.json`

### 6.2 직접 run_accuracy.py 실행

```bash
python3 tests/accuracy/run_accuracy.py \
  --direct-ocr-endpoint http://localhost:18888 \
  --engine "PaddleOCR PP-OCRv5" \
  --fixtures tests/accuracy/fixtures \
  --out tests/accuracy/reports \
  --commit $(git rev-parse --short HEAD) \
  --min-success-rate 0.8
```

---

## 7. 정확도 기준치 (2026-04-22 측정)

| 지표 | EasyOCR 1.7.1 | PaddleOCR PP-OCRv5 | Phase 1 MVP 목표 |
|------|---------|---------|------|
| char_accuracy | 95.8% | **99.3%** | ≥97% |
| exact_match_rate | 78.8% | **93.9%** | ≥85% |
| tolerance_rate | 90.9% | **95.5%** | - |

**결론: PaddleOCR PP-OCRv5가 Phase 1 MVP 목표 충족.**

자세한 비교: `tests/accuracy/reports/comparison-easyocr-vs-paddle.md`

---

## 8. 알려진 한계 / 트레이드오프

| 이슈 | 내용 | 대응 |
|------|------|------|
| `₩` → `W/w` 오인식 | 원화기호 폰트 렌더링 혼동 | post-processing 정규화 (Phase 1 B-3) |
| 한/영 혼재 영역 혼동 | Invoice `Invoice` → `Inv이ice` | PP-OCRv5_server_rec 전환 검토 |
| 이미지 크기 2.01GB | kind load 5분, 디스크 부담 | 멀티스테이지 빌드 최적화 (Phase 1 B-3) |
| 초기 기동 120초 | 모델 로딩 시간 | 빌드 타임 pre-download로 최소화됨. 운영환경 HPA 주의 |
| AVX2 의존 | paddlepaddle CPU 빌드 요건 | GPU 없는 구형 CPU: `paddlepaddle-noavx` 대체 가능 |

---

## 9. 장애 대응

### 9.1 Pod CrashLoopBackOff

```bash
kubectl -n processing describe pod -l app.kubernetes.io/name=ocr-worker-paddle
kubectl -n processing logs -l app.kubernetes.io/name=ocr-worker-paddle --previous
```

주요 원인:
- OOM: limits 4Gi 미만 환경 → limits 상향 또는 노드 메모리 증가
- SIGABRT: libgomp 미설치 → Dockerfile apt 레이어 확인
- 모델 캐시 손상: `/home/ocr/.paddlex` 내용 확인, 이미지 재빌드

### 9.2 /ocr 요청 타임아웃

PaddleOCR 첫 요청은 JIT 컴파일로 수십 초 소요 가능.

- readinessProbe initialDelaySeconds: 90 (설정됨)
- 클라이언트 타임아웃: 120초 이상 권장
- 대용량 이미지 (>5MB): 처리 시간 증가 → 업로드 전 리사이즈 권장

### 9.3 모델 소스 체크 실패

```
Error: Failed to connect to model hoster
```

처리:
```bash
kubectl -n processing set env deploy/ocr-worker-paddle PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
```
(이미 Dockerfile에 기본 설정됨. 재확인 용도.)

---

## 10. 향후 작업 (Phase 1 B-3 이후)

1. `ocr-worker-paddle` → `ocr-worker` 기본 엔진 전환 (upload-api OCR_WORKER_URL 변경)
2. 기존 EasyOCR `ocr-worker` Deployment 제거 또는 대기
3. 통화기호 정규화 미들웨어 추가
4. PP-OCRv5_server_rec 모델로 rec 교체 후 재측정
5. 이미지 멀티스테이지 빌드로 크기 최적화
6. HPA 설정 (Phase 1 B-4+)
