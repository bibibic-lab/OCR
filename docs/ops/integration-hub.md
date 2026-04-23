# Integration Hub 운영 Runbook

**작성일**: 2026-04-22
**버전**: 0.1.0 (Phase 1 Walking Skeleton)
**네임스페이스**: `processing`
**서비스 FQDN**: `integration-hub.processing.svc.cluster.local:8080`

---

## 1. 개요

Integration Hub는 OCR 플랫폼의 **외부 기관 연계 단일 경로(Single Controlled Path)**를 담당한다.

| 항목 | 내용 |
|------|------|
| 스택 | Spring Boot 3.2.5 + Kotlin 1.9.23 + JVM 21 |
| 라우팅 엔진 | Apache Camel 4.4.4 (LTS) |
| 탄력성 | Resilience4j Circuit Breaker + Bulkhead |
| 현재 모드 | mock (내장 MockAgencyController) |
| 프로덕션 전환 | Phase 2 (실 기관 URL + Egress Gateway) |

### 스펙 §4 커버리지

| 연계 기관 | 엔드포인트 | 상태 |
|----------|-----------|------|
| 행안부 (MOIS) | POST /verify/id-card | Mock OK |
| KISA TSA | POST /timestamp | Mock OK |
| OCSP (CA) | POST /ocsp | Mock OK |
| NICE CB | - | Phase 2 예정 |

---

## 2. Camel Route 구조

```
upload-api
  │ HTTP POST
  ▼
IntegrationController (REST)
  │ ProducerTemplate
  ├─ direct:verify-id-card → IdVerifyRoute → MockAgencyController /mock/id-verify
  ├─ direct:timestamp      → TsaRoute     → MockAgencyController /mock/tsa
  └─ direct:ocsp           → OcspRoute    → MockAgencyController /mock/ocsp
```

각 Route는 **Circuit Breaker(Resilience4j)**를 포함:
- 슬라이딩 윈도우: 10회
- 실패율 임계: 50%
- Open 유지: 30초
- Half-Open 허용 횟수: 3회

---

## 3. 배포 절차

### 3.1 이미지 빌드

```bash
export JAVA_HOME=/usr/local/Cellar/openjdk@21/21.0.11/libexec/openjdk.jdk/Contents/Home
cd /Users/jimmy/_Workspace/ocr/services/integration-hub
docker build -t integration-hub:v0.1.0 .
```

빌드 완료 후 이미지 크기 확인:
```bash
docker images integration-hub:v0.1.0
```

### 3.2 kind 로드 + 배포

```bash
kind load docker-image integration-hub:v0.1.0
kubectl apply -f infra/manifests/integration-hub/
kubectl rollout status deployment/integration-hub -n processing --timeout=120s
```

### 3.3 스모크 테스트

```bash
bash tests/smoke/integration_hub_smoke.sh
```

---

## 4. 헬스체크 엔드포인트

| 경로 | 설명 |
|------|------|
| GET /actuator/health/liveness | Liveness Probe |
| GET /actuator/health/readiness | Readiness Probe |
| GET /actuator/health | 전체 상태 (JSON) |
| GET /actuator/prometheus | Prometheus 메트릭 |
| GET /actuator/camelroutes | Camel Route 상태 목록 |

```bash
# pod 내부에서 헬스 확인
kubectl exec -n processing deployment/integration-hub -- \
  curl -s http://localhost:8080/actuator/health | jq .
```

---

## 5. 수동 E2E 검증

```bash
# port-forward
kubectl port-forward -n processing svc/integration-hub 18090:8080 &

# 1) 행안부 주민등록 진위확인
curl -s -X POST http://localhost:18090/verify/id-card \
  -H "Content-Type: application/json" \
  -d '{"name":"홍길동","rrn":"9001011234567","issue_date":"20200315"}' | jq .

# 2) KISA TSA 타임스탬프
curl -s -X POST http://localhost:18090/timestamp \
  -H "Content-Type: application/json" \
  -d '{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' | jq .

# 3) OCSP 검증
curl -s -X POST http://localhost:18090/ocsp \
  -H "Content-Type: application/json" \
  -d '{"issuer_cn":"KISA-RootCA-G1","serial":"0123456789abcdef"}' | jq .
```

### 예상 응답

```json
// /verify/id-card (홍길동 3자 = 홀수 → mock FAIL)
{
  "valid": false,
  "match_score": 0.12,
  "agency_tx_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}

// /timestamp
{
  "token": "MBYAA...",
  "serial_number": "abcdef0123456789",
  "gen_time": "2026-04-22T00:00:00Z",
  "policy_oid": "1.2.410.200001.1"
}

// /ocsp
{
  "status": "good",
  "this_update": "2026-04-22T00:00:00Z",
  "next_update": "2026-04-22T01:00:00Z"
}
```

---

## 6. Circuit Breaker 상태 확인

Camel Resilience4j CB 상태는 Actuator에서 직접 노출되지 않음.
Resilience4j 자체 Actuator endpoint 사용:

```bash
curl -s http://localhost:18090/actuator/health | jq '.components.circuitBreakers // "N/A"'
```

강제 오류 유발 (CB Open 테스트):
```bash
# MockAgencyController를 임시로 500 반환하도록 수정하거나
# WireMock 스텁으로 교체하여 10회 연속 실패 유발
```

---

## 7. 로그 조회

```bash
# 최근 50줄
kubectl logs -n processing -l app.kubernetes.io/name=integration-hub --tail=50

# 실시간
kubectl logs -n processing -l app.kubernetes.io/name=integration-hub -f
```

주요 로그 패턴:
- `행안부 주민등록 진위확인 요청: name=...` — IdVerify 요청 수신
- `IdVerify Circuit Open — 기본 응답 반환` — CB 작동
- `[entrypoint] ocr-internal CA registered` — CA 주입 성공

---

## 8. 장애 대응

### 8.1 Pod 기동 실패

```bash
kubectl describe pod -n processing -l app.kubernetes.io/name=integration-hub
```

주요 원인:
| 증상 | 원인 | 조치 |
|------|------|------|
| `ImagePullBackOff` | kind에 이미지 미로드 | `kind load docker-image integration-hub:v0.1.0` |
| `CrashLoopBackOff` | 애플리케이션 오류 | `kubectl logs` 확인 |
| `Pending` | 리소스 부족 | `kubectl describe node` 확인 |
| `OOMKilled` | 메모리 초과 | resources.limits.memory 증가 |

### 8.2 Circuit Breaker Open 상태 지속

원인: 외부 기관 URL 연결 불가 (mock 모드에서는 발생 안 함).
조치:
1. pod 재시작으로 CB 초기화: `kubectl rollout restart deployment/integration-hub -n processing`
2. 환경변수 URL 확인: `kubectl exec ... env | grep URL`

### 8.3 /verify/id-card 항상 valid=false

mock 모드의 결정론적 동작:
- name 길이 짝수 → OK (valid=true)
- name 길이 홀수 → FAIL (valid=false)
- "홍길동" = 3자(홀수) → FAIL 정상

---

## 9. Phase 2 전환 체크리스트

실 외부 기관 연동 시 필요한 작업:

- [ ] Egress Gateway (Squid/Envoy) 배포 및 NetworkPolicy 활성화
- [ ] 행안부 API 키 / mTLS 인증서 → ExternalSecret으로 주입
- [ ] SPRING_PROFILES_ACTIVE: "mock" → "prod" 변경
- [ ] ID_VERIFY_URL, TSA_URL, OCSP_URL → 실 URL (egress proxy 통과)
- [ ] RRN 전송 구간 암호화 (HSM/OpenBao)
- [ ] BouncyCastle TSARequest 빌더로 실 RFC 3161 요청 생성
- [ ] BouncyCastle OCSPReqBuilder로 실 OCSP 요청 생성
- [ ] upload-api → integration-hub JWT 서비스 토큰 인증 추가
- [ ] 감사 로그 (agency_tx_id 영구 보관) DB 스키마 추가

---

## 10. 참고

- Apache Camel 4.4 LTS 문서: https://camel.apache.org/camel-spring-boot/4.4.x/
- Resilience4j Spring Boot: https://resilience4j.readme.io/docs/getting-started-3
- 행안부 API 표준 v2.3: (사내 공문 #2026-MOIS-023)
- KISA TSA RFC 3161: https://www.rfc-editor.org/rfc/rfc3161
- 스펙 원본: `docs/superpowers/specs/2026-04-18-ocr-solution-design.md` §4
