# Phase 1 Low #4 — FPE 토큰화 upload-api 통합 구현 계획 및 결과

- **작성일**: 2026-04-22
- **완료일**: 2026-04-23
- **작성자**: Claude (Sonnet 4.6)
- **관련 스펙**: `docs/superpowers/specs/2026-04-18-ocr-solution-design.md`

---

## 1. 목표

upload-api가 ocr-worker에서 받은 OCR 결과를 DB에 저장하기 **전에** RRN 패턴을 탐지하고 fpe-service를 통해 토큰화하여 민감 데이터가 pg-main에 저장되지 않도록 한다.

## 2. 설계 결정

| 항목 | 결정 | 이유 |
|------|------|------|
| RRN 패턴 | `\b(\d{6})-(\d{7})\b` | 전화번호·카드번호 오탐 방지. 보수적 정규식 |
| 실패 시 정책 | OCR_FAILED 전이 (저장 차단) | 민감 데이터 노출 > 가용성 손실 |
| Feature flag | `FPE_TOKENIZATION_ENABLED=true/false` | 점진적 롤아웃 지원 |
| 배치 처리 | 고유 값만 1회 `/tokenize-batch` 요청 | 동일 RRN 중복 최소화 |
| 역변환 | upload-api에서 미지원 | step-up MFA 필요 (admin-ui Phase 2) |

## 3. 구현 항목

### 3.1 신규 파일

| 파일 | 역할 |
|------|------|
| `services/upload-api/src/main/kotlin/kr/ocr/upload/FpeClient.kt` | fpe-service `/tokenize-batch` RestClient |
| `services/upload-api/src/main/kotlin/kr/ocr/upload/TokenizationService.kt` | RRN 탐지 + 치환 로직 |
| `services/upload-api/src/main/resources/db/migration/V2__sensitive_fields_flag.sql` | ocr_result 컬럼 추가 |
| `services/upload-api/src/test/kotlin/kr/ocr/upload/TokenizationServiceTest.kt` | 단위 테스트 9개 |
| `tests/smoke/fpe_upload_integration_smoke.sh` | 통합 스모크 테스트 |

### 3.2 수정 파일

| 파일 | 변경 내용 |
|------|-----------|
| `OcrProperties.kt` | `FpeProps` 내부 클래스 추가 |
| `OcrTriggerService.kt` | TokenizationService 주입, 토큰화 후 저장 |
| `Repositories.kt` | `OcrResultRow`에 신규 컬럼 필드, INSERT 쿼리 확장 |
| `application.yml` | `ocr.fpe.*` 기본값 추가 |
| `infra/manifests/upload-api/deployment.yaml` | FPE_SERVICE_URL, FPE_TOKENIZATION_ENABLED env + 이미지 v0.2.0 |
| `infra/manifests/upload-api/network-policies.yaml` | egress → security ns:8080 추가 |

## 4. NetworkPolicy 변경

```yaml
# upload-api-egress에 추가
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: security
  ports:
    - port: 8080
      protocol: TCP
```

fpe-service NetworkPolicy `fpe-service-ingress-dmz`는 이미 dmz/upload-api → port 8080을 허용하고 있어 추가 변경 불필요.

## 5. Flyway V2 마이그레이션

```sql
ALTER TABLE ocr_result
    ADD COLUMN IF NOT EXISTS sensitive_fields_tokenized BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS tokenized_count            INT     NOT NULL DEFAULT 0;
```

- 2026-04-23T13:11:33 클러스터 기동 시 자동 적용 확인

## 6. 단위 테스트 결과

- 테스트 클래스: `TokenizationServiceTest`
- 9개 테스트 모두 PASS (2026-04-23 실행)
- 주요 검증 항목:
  - RRN 없음 → fpeClient 미호출
  - RRN 1건 탐지 후 토큰 치환
  - 동일 RRN 중복 시 1회 배치 요청
  - 다중 고유 RRN 단일 배치 처리
  - 전화번호 패턴 오탐 없음
  - FPE 비활성화 시 no-op
  - fpeClient 오류 시 FpeCallException 전파
  - 응답 수 불일치 시 예외 발생
  - 단어 경계(\b) 패턴 검증

## 7. 스모크 테스트 결과 (2026-04-23)

| 항목 | 결과 |
|------|------|
| 테스트 이미지 | `tests/images/sample-id-korean.png` |
| documentId | `aca1b5c3-c223-4926-9e07-35960c666548` |
| OCR 최종 상태 | `OCR_DONE` |
| 원본 RRN | `900101-1234567` |
| 저장된 토큰 | `982367-9811901` |
| 역변환 검증 | `982367-9811901` → `900101-1234567` ✓ |
| DB `sensitive_fields_tokenized` | `true` |
| DB `tokenized_count` | `1` |

## 8. 운영 절차 (Runbook)

### 8.1 토큰화 비활성화 (긴급 롤백)

```bash
kubectl set env deployment/upload-api FPE_TOKENIZATION_ENABLED=false -n dmz
kubectl rollout status deployment/upload-api -n dmz
```

원복:
```bash
kubectl set env deployment/upload-api FPE_TOKENIZATION_ENABLED=true -n dmz
```

### 8.2 fpe-service 장애 시

fpe-service 장애 → upload-api OCR_FAILED 전이 (민감 데이터 저장 차단).

확인:
```bash
kubectl logs -n dmz deployment/upload-api | grep "FPE 토큰화 오류"
```

임시 우회: `FPE_TOKENIZATION_ENABLED=false` + 수동 마스킹 후 재업로드.

### 8.3 Flyway 롤백 (V2 제거)

```sql
ALTER TABLE ocr_result
    DROP COLUMN IF EXISTS sensitive_fields_tokenized,
    DROP COLUMN IF EXISTS tokenized_count;
DELETE FROM flyway_schema_history WHERE version = '2';
```

## 9. Phase 2 이월 사항

| 항목 | 이유 |
|------|------|
| admin-ui detokenize (step-up MFA) | 별도 보안 흐름 필요. Phase 2 범위 |
| 재시도 정책 (fpe-service 일시 장애) | 현재 즉시 OCR_FAILED. 지수 백오프 + DLQ 검토 |
| 카드번호 패턴 탐지 추가 | 현재 RRN만. 카드번호 `\d{4}-\d{4}-\d{4}-\d{4}` 추가 가능 |
| 토큰화 감사 로그 | fpe-service 내 audit_reason 연계 |
