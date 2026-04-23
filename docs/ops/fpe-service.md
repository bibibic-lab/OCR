# FPE Tokenization Service — 운영 Runbook

- 작성일: 2026-04-22
- 버전: v0.1.0
- 상태: Phase 1 MVP (Walking Skeleton)
- 담당: OCR Platform Team
- 관련 스펙: 설계 §2.7 (FPE Tokenization)

---

## 1. 개요

### 1.1 목적

OCR로 추출된 민감 개인정보(RRN, 카드번호, 계좌번호, 여권번호)를 Format-Preserving Encryption(FPE)으로 토큰화하여, 원본 포맷을 유지하면서 원본값을 보호합니다.

### 1.2 알고리즘

| 항목 | 내용 |
|------|------|
| 알고리즘 | FF3-1 (NIST SP 800-38G Rev 1, 2024) |
| 구현체 | ff3 Python 패키지 v1.0.2 (pycryptodome 기반) |
| 키 길이 | AES-256 (256-bit, 64자 hex) |
| 트윅 | 56-bit (7 bytes, 14자 hex) |
| 결정론성 | 동일 (key, tweak, plaintext) → 동일 token |
| 참조 표준 | https://doi.org/10.6028/NIST.SP.800-38Gr1 |

**Dev-grade 표시**: 현재 구현은 키/트윅이 단순 랜덤값(OpenBao KV 저장). Phase 2에서 FIPS 140-3 검증 라이브러리 및 키 회전 메커니즘으로 업그레이드 예정.

### 1.3 지원 필드 타입

| 타입 | 원본 예시 | 토큰 예시 | 포맷 보존 |
|------|-----------|-----------|-----------|
| `rrn` | `900101-1234567` | `834721-8954162` | 6자리-7자리 하이픈 유지 |
| `card` | `1234-5678-9012-3456` | `8743-0921-5678-3411` | 4자리-4자리-4자리-4자리 |
| `account` | `1234567890` | `8743092156` | 10~16자리 숫자 |
| `passport` | `M12345678` | `M87430921` | 영문 접두사 보존, 숫자 FPE |

---

## 2. 아키텍처

```
upload-api (dmz)          admin-ui (admin)
      │                        │
      │ POST /tokenize          │ POST /detokenize
      │ (NetworkPolicy)         │ (JWT detokenize role)
      ▼                        ▼
 ┌─────────────────────────────────────┐
 │          fpe-service (security ns)  │
 │          FastAPI + FF3-1 Python     │
 └──────────────┬──────────────────────┘
                │
        ┌───────┼───────┐
        ▼               ▼
  OpenBao KV        pg-pii (CNPG)
  fpe-keys/{type}   fpe_token 테이블
  (AES key, tweak)  (감사 레지스트리)
```

### 2.1 컴포넌트

| 컴포넌트 | 역할 |
|----------|------|
| `fpe.py` | FF3-1 암호화/복호화 로직, 필드 타입별 포맷 처리 |
| `vault_client.py` | OpenBao KV에서 FPE 키 로드 (lru_cache, K8s auth) |
| `pii_store.py` | pg-pii fpe_token 테이블 감사 레지스트리 |
| `server.py` | FastAPI REST API, JWT 역할 검사, 감사 로그 |

---

## 3. REST API

### 3.1 `POST /tokenize`

```json
Request:
{
  "type": "rrn",
  "value": "900101-1234567"
}

Response 200:
{
  "token": "834721-8954162",
  "token_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479"
}
```

### 3.2 `POST /detokenize`

```json
Request:
{
  "type": "rrn",
  "token": "834721-8954162",
  "audit_reason": "back-office inquiry by user:kim@corp.com"
}

Response 200:
{
  "value": "900101-1234567"
}
```

**인증 필요**: `Authorization: Bearer <JWT>` — JWT payload의 `realm_access.roles`에 `detokenize` 포함 필요.

**Phase 2**: JWT 서명 JWKS 검증 + step-up MFA 추가.

### 3.3 `POST /tokenize-batch`

```json
Request:
{
  "items": [
    {"type": "rrn", "value": "900101-1234567"},
    {"type": "card", "value": "1234-5678-9012-3456"}
  ]
}

Response 200:
{
  "tokens": [
    {"token": "834721-8954162", "token_id": "..."},
    {"token": "8743-0921-5678-3411", "token_id": "..."}
  ],
  "errors": []
}
```

### 3.4 `GET /health`

```json
{"status": "ok", "service": "fpe-service", "version": "0.1.0"}
```

---

## 4. 배포

### 4.1 사전 조건

- kind 클러스터에 `security` namespace 존재
- OpenBao 배포 완료 + `openbao-init-keys` Secret 존재
- pg-pii CNPG 클러스터 Running
- Docker 실행 중

### 4.2 초기 설치 절차

```bash
# 1. OpenBao FPE 키 부트스트랩 (키 생성 + 정책/롤 설정)
bash scripts/fpe-bootstrap.sh

# 2. Docker 이미지 빌드 + kind 로드
docker build -t fpe-service:v0.1.0 services/fpe-service/
kind load docker-image fpe-service:v0.1.0 --name ocr

# 3. pg-pii fpe_token 스키마 생성 Job
kubectl apply -f infra/manifests/fpe-service/pg-pii-fpe-schema.yaml
kubectl wait job/pg-pii-fpe-schema -n security --for=condition=complete --timeout=120s

# 4. fpe-service 배포
kubectl apply -f infra/manifests/fpe-service/

# 5. 상태 확인
kubectl get pods -n security -l app.kubernetes.io/name=fpe-service

# 6. Smoke 테스트
bash tests/smoke/fpe_smoke.sh
```

### 4.3 환경변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `BAO_ADDR` | `https://openbao.security.svc.cluster.local:8200` | OpenBao 주소 |
| `BAO_TOKEN` | (없음) | Static 토큰 (있으면 K8s auth 대신 사용) |
| `BAO_SKIP_VERIFY` | `false` | TLS 검증 스킵 (dev only) |
| `BAO_K8S_ROLE` | `fpe-service` | Kubernetes auth 롤 |
| `PII_DB_DSN` | `postgresql://fpe_user:...@pg-pii-rw...` | pg-pii DSN |
| `FPE_REQUIRE_AUTH` | `true` | `false` 시 JWT 검증 스킵 (dev only) |
| `LOG_LEVEL` | `INFO` | 로그 레벨 |

---

## 5. OpenBao KV 구조

```
kv/
└── security/
    ├── fpe-keys/
    │   ├── rrn       → { aes_key_hex, tweak_hex, kek_version }
    │   ├── card      → { aes_key_hex, tweak_hex, kek_version }
    │   ├── account   → { aes_key_hex, tweak_hex, kek_version }
    │   └── passport  → { aes_key_hex, tweak_hex, kek_version }
    └── fpe-service   → { pii_db_dsn, pii_db_password }
```

### 5.1 키 직접 조회 (관리 용도)

```bash
# root token 획득
ROOT_TOKEN=$(kubectl -n security get secret openbao-init-keys \
  -o jsonpath='{.data.init\.json}' | base64 -d | jq -r .root_token)

# FPE 키 조회
kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao kv get kv/security/fpe-keys/rrn
```

---

## 6. pg-pii fpe_token 테이블

### 6.1 스키마

```sql
CREATE TABLE fpe_token (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash            TEXT NOT NULL,   -- SHA-256(type + ":" + token)
  type                  TEXT NOT NULL CHECK (type IN ('rrn','card','account','passport')),
  kek_version           TEXT NOT NULL DEFAULT 'v1',
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  detokenize_count      INT NOT NULL DEFAULT 0,
  last_detokenized_at   TIMESTAMPTZ,
  CONSTRAINT uq_fpe_token_hash UNIQUE (token_hash)
);
```

**설계 원칙**: 원본값 미저장. FF3-1 역산으로 복원 가능. 테이블은 순수 감사 레지스트리.

### 6.2 주요 쿼리

```sql
-- 총 토큰 수
SELECT COUNT(*) FROM fpe_token;

-- 타입별 통계
SELECT type, COUNT(*), MAX(created_at) FROM fpe_token GROUP BY type;

-- 자주 detokenize된 토큰 (이상 징후 감지)
SELECT id, type, detokenize_count, last_detokenized_at
FROM fpe_token
WHERE detokenize_count > 10
ORDER BY detokenize_count DESC;

-- 최근 24시간 detokenize 활동
SELECT COUNT(*) FROM fpe_token
WHERE last_detokenized_at > NOW() - INTERVAL '24 hours';
```

---

## 7. 감사 로그

### 7.1 출력 형식

detokenize 호출마다 JSON을 stdout으로 출력 → Fluentbit 수집 → OpenSearch `audit-fpe-*` 인덱스.

```json
{
  "@timestamp": "2026-04-22T10:30:00Z",
  "event": "detokenize",
  "field_type": "rrn",
  "audit_reason": "back-office inquiry by user:kim@corp.com",
  "client_ip": "10.0.1.5",
  "request_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "service": "fpe-service",
  "index": "audit-fpe"
}
```

### 7.2 OpenSearch 쿼리 예시

```json
GET audit-fpe-*/_search
{
  "query": {
    "bool": {
      "must": [
        {"term": {"event": "detokenize"}},
        {"range": {"@timestamp": {"gte": "now-1d"}}}
      ]
    }
  }
}
```

---

## 8. 트러블슈팅

### 8.1 Pod CrashLoopBackOff

```bash
kubectl logs -n security deployment/fpe-service --previous
```

주요 원인:
- OpenBao 연결 실패: `BAO_TOKEN` 또는 K8s auth 설정 확인
- pg-pii DSN 오류: `PII_DB_DSN` 환경변수 확인
- FPE 키 미존재: `scripts/fpe-bootstrap.sh` 재실행

### 8.2 503 서비스 오류 (토큰화 시)

OpenBao KV에서 FPE 키 로드 실패. 확인:

```bash
# 키 존재 확인
kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao kv get kv/security/fpe-keys/rrn
```

### 8.3 키 캐시 갱신

fpe-service는 프로세스 수명 동안 FPE 키를 lru_cache로 캐시합니다. 키 교체 후:

```bash
# 파드 재시작으로 캐시 초기화
kubectl rollout restart deployment/fpe-service -n security
```

### 8.4 포맷 오류 422

입력값이 지원 포맷과 다를 경우:
- RRN: `######-#######` (정확히 13자리 숫자 + 하이픈)
- 카드: `####-####-####-####` 또는 16자리 연속 숫자
- 계좌: 10~16자리 숫자
- 여권: 영문 1~2자리 + 숫자 7~9자리

---

## 9. Phase 2 업그레이드 계획

| 항목 | Phase 1 (현재) | Phase 2 계획 |
|------|---------------|-------------|
| JWT 검증 | 역할 파싱만 (서명 미검증) | JWKS 엔드포인트 + 서명 검증 |
| step-up MFA | 미구현 | /detokenize에 OTP 또는 session 재인증 요구 |
| 키 회전 | 수동 (--force) | 자동 키 버전 관리 + 재토큰화 배치 |
| FPE 라이브러리 | ff3 OSS | FIPS 140-3 검증 라이브러리 |
| DB 연결 | 단순 psycopg2 | Connection pooling (asyncpg or pgbouncer) |
| rate limiting | 미구현 | /detokenize API 속도 제한 |
| upload-api 통합 | 미구현 | OCR 후처리에서 RRN 필드 자동 토큰화 |
| 비동기 처리 | 동기 | FastAPI async + asyncpg |

---

## 10. 보안 고려사항

1. **키 노출 방지**: FPE 키는 OpenBao KV에만 저장. 환경변수/로그에 절대 출력 금지.
2. **결정론성 리스크**: FF3-1은 동일 입력 → 동일 출력. frequency analysis 공격 가능성. Phase 2에서 per-record tweak(salt) 도입 검토.
3. **FF3-1 알려진 취약점**: radix × minlen이 작을 경우 공격 표면 증가. RRN(radix=10, len=13, 10^13) 및 카드(16자리)는 충분한 보안 마진 확보.
4. **pg-pii 접근 통제**: fpe_token 테이블은 원본값 미저장이지만 감사 정보 포함. fpe_user 최소 권한 원칙 적용.
5. **감사 로그 보존**: OpenSearch audit-fpe-* 인덱스 보존 정책 90일 이상 권장.

---

## 11. 참고 자료

- NIST SP 800-38G Rev 1 (2024): https://doi.org/10.6028/NIST.SP.800-38Gr1
- ff3 Python 패키지: https://github.com/mysto/python-fpe
- OpenBao KV Secrets Engine: https://openbao.org/docs/secrets/kv/kv-v2/
- pycryptodome: https://pycryptodome.readthedocs.io/
