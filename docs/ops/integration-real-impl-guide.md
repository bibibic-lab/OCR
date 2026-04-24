# 외부기관 연계 실 구현 가이드

**작성일**: 2026-04-22  
**상태**: v2 범위 3개 어댑터 전부 mock (POLICY-EXT-01 준수)  
**관련 정책**: POLICY-NI-01, POLICY-EXT-01 (CLAUDE.md 참조)

---

## 목적

이 문서는 v2 범위에서 mock으로 구현된 외부 기관 연계 어댑터를 실 API로 전환할 때 필요한 정보의 **단일 참조 문서**이다.

현재 상태: 3개 어댑터 모두 mock (POLICY-EXT-01 준수)

전환 트리거: 해당 기관의 test/dev API 계정 발급 시 각 섹션의 "전환 체크리스트" 실행.

### 이 문서와 코드의 1:1 매핑

| 문서 anchor | 코드 파일 | companion const |
|---|---|---|
| `#행안부-주민등록-진위확인` | `IdVerifyRoute.kt`, `IdVerifyDto.kt` | `NOT_IMPLEMENTED`, `GUIDE_ANCHOR` |
| `#kisa-tsa-타임스탬프-rfc-3161` | `TsaRoute.kt`, `TsaDto.kt` | `NOT_IMPLEMENTED`, `GUIDE_ANCHOR` |
| `#ocsp-인증서-검증` | `OcspRoute.kt`, `OcspDto.kt` | `NOT_IMPLEMENTED`, `GUIDE_ANCHOR` |
| `#softhsm-pkcs11` | (upload-api FPE, integration-hub) | — |
| `#fips-140-3` | (upload-api FPE) | — |

---

## 공통 인프라

### Egress Gateway

**목적**: 외부 기관 호출의 단일 egress 경로. 화이트리스트 · TLS 재암호화 · 감사 로그.

**현재 상태**: placeholder 주석만 존재 (POLICY-EXT-01: 전 구현 단계 더미).  
참조: `infra/manifests/integration-hub/network-policies.yaml` Egress Gateway 주석 블록.

**권장 구현 (Phase 2)**:
- Envoy Proxy (cilium-envoy 내장 활용 가능) 또는 Squid
- 설치 위치: `dmz` ns의 별도 Deployment (`egress-gateway`)
- 외부 기관 FQDN별 화이트리스트 정책

**Envoy placeholder config** (Phase 2 기준점):
```yaml
# infra/manifests/egress-gateway/envoy-config.yaml (Phase 2 생성 예정)
static_resources:
  clusters:
    - name: id_verify_agency
      # load_assignment.endpoints[].lb_endpoints[].endpoint.address:
      #   socket_address: { address: "api.행안부.go.kr", port_value: 443 }
      transport_socket:
        name: envoy.transport_sockets.tls
        # tls_context: client_certificate → integration-hub 클라이언트 cert
```

**배포 명령 (Phase 2)**:
```bash
kubectl apply -f infra/manifests/egress-gateway/
kubectl -n dmz rollout status deployment/egress-gateway
```

---

### PKCS#11 / HSM

**목적**: RRN 등 민감정보 암호화 서명 시 HSM 키 사용.

**현재 상태**: SoftHSM2 dummy signer 함수 비활성화 상태.

| 환경 | 구현 |
|---|---|
| 개발 | SoftHSM2 (OSS, k8s Secret 또는 emptyDir 마운트) |
| 스테이징 | SoftHSM2 + PKCS#11 URI 활성화 |
| 프로덕션 | 실 HSM (조달 필요 — Thales Luna, Yubico HSM2, 또는 동급) |

**SoftHSM2 초기화 명령**:
```bash
# pod 내부 또는 init container
softhsm2-util --init-token --slot 0 --label "ocr-dev" \
  --pin <PIN> --so-pin <SO_PIN>
# 키 생성 (RSA-2048)
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --login --pin <PIN> \
  --keypairgen --key-type rsa:2048 --label "ocr-sign-key"
```

**BouncyCastle PKCS#11 연동 패턴** (Phase 2 코드 scaffold):
```kotlin
// integration-hub: kr.ocr.intgr.crypto.HsmSigner (Phase 2 생성 예정)
// NOT_IMPLEMENTED: 실 HSM 미조달. 더미 서명 함수 유지.
// 전환 트리거: 실 HSM 조달 + PKCS#11 URI 확보
class HsmSigner {
    fun sign(data: ByteArray): ByteArray {
        // TODO Phase 2: PKCS11KeyStore.getInstance("PKCS11", provider).load(...)
        throw NotImplementedError("실 HSM 미조달 — SoftHSM 더미만 활성화")
    }
}
```

---

### mTLS (integration-hub → Egress Gateway → External)

**목적**: 외부 기관 호출 전 구간 mutual TLS.

**현재 상태**: 코드 경로 비활성화 (POLICY-EXT-01).

**CA 체인 구성**:
```
ocr-internal-ca (cert-manager) → integration-hub 클라이언트 인증서
기관 CA (예: 행안부 CA) → 서버 인증서 검증
```

**클라이언트 cert 주입 방법**:
```yaml
# ESO ExternalSecret (Phase 2 생성 예정)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: integration-hub-client-cert
  namespace: processing
spec:
  refreshInterval: 24h
  secretStoreRef:
    name: openbao-backend
    kind: ClusterSecretStore
  target:
    name: integration-hub-client-cert
    creationPolicy: Owner
  data:
    - secretKey: tls.crt
      remoteRef:
        key: kv/external/agencies/id-verify
        property: client_cert
    - secretKey: tls.key
      remoteRef:
        key: kv/external/agencies/id-verify
        property: client_key
```

---

### 감사 로그

**규칙**: 모든 외부 기관 호출은 `audit_log` 테이블 + OpenSearch `audit-external-*` 인덱스에 기록.

**보관 항목**: 요청 요약 · 응답 요약 · `agency_tx_id` · 호출 시각 · 결과 코드.

**영구 보관**: 해시체인 WORM 아카이브 (Phase 2 — S3 Object Lock + Glacier).

**전환 이벤트 기록 (Phase 2 코드 패턴)**:
```kotlin
auditLogRepository.save(AuditLog(
    eventType = "AGENCY_INTEGRATION_ACTIVATED",
    agencyName = "행안부",
    message = "IdVerify 실 API 전환 완료",
    agencyTxId = "N/A",
    timestamp = Instant.now(),
))
```

---

## 행안부 주민등록 진위확인

**현재 상태**: mock (NOT_IMPLEMENTED = true)  
**코드 마커**: `IdVerifyRoute.NOT_IMPLEMENTED`, `IDVerifyResponse.notImplemented`

### API 개요

| 항목 | 내용 |
|---|---|
| 서비스명 | 주민등록 진위확인 서비스 (행정안전부 정부24 API) |
| 프로토콜 | REST over HTTPS (TLS 1.2+, TLS 1.3 권장) |
| 인증 | PKCS#12 클라이언트 인증서 + IP 화이트리스트 |
| 호출 경로 | https://api.정부24.go.kr/... (실 URL 비공개 — 계약 후 발급) |
| Rate limit | 기관별 협의 (공공 API, 무료) |
| SLA | 99.5% (영업일 기준) |

### 요청·응답 스키마

```json
// POST /id-verify (행안부 실 엔드포인트 경로는 계약 후 확인)
{
  "name": "홍길동",
  "rrn_prefix": "900101",
  "issued_at": "20200315"
}
```

```json
// 성공 응답
{
  "status": "OK",
  "score": 0.95,
  "tx_id": "MOIS-2026-0001-XXXXXX"
}

// 실패 응답
{
  "status": "FAIL",
  "score": 0.12,
  "tx_id": "MOIS-2026-0001-XXXXXX"
}
```

**주의**: RRN suffix는 전송 전 HSM 암호화 필수. 현재 mock에서는 prefix만 사용.

### 계약 절차

| 항목 | 내용 |
|---|---|
| 접촉처 | 행정안전부 정부24 API 운영팀 (g24api@mois.go.kr — 실제 이메일 확인 필요) |
| 필요 서류 | 사업자등록증 · 개인정보처리방침 · 보안평가서(ISMS-P 권장) · 서비스 설명서 |
| 평균 소요 | 2-4주 |
| 비용 | 무료 (공공 API, rate limit 있음) |
| API 계정 발급 | test 계정 → 본계정 순서 (test 계정 접근 후 smoke 10건 검증 필요) |

### 전환 체크리스트

1. test API 계정 수령 및 PKCS#12 클라이언트 인증서 발급
2. `kv/external/agencies/id-verify` OpenBao KV에 client cert · key 저장
   ```bash
   bao kv put kv/external/agencies/id-verify \
     client_cert=@client.crt client_key=@client.key
   ```
3. ESO `ExternalSecret` 생성 → integration-hub Secret mount
4. `application.yml`의 `ocr.integration.agencies.id-verify.url` → 실 엔드포인트로 변경
5. `IdVerifyRoute.kt`의 `NOT_IMPLEMENTED = false` 변경
6. `IDVerifyResponse.notImplemented` 기본값 `false`로 변경
7. admin-ui `/integration-test` 배너 자동 제거 확인 (동일 flag 기반)
8. 감사 로그에 전환 이벤트 1회 기록
9. 스모크: 테스트 RRN 10건으로 연계 검증 → 성공률 확인
10. 전환 완료 후 이 섹션 상단에 `**상태: 운영 중 (YYYY-MM-DD 전환)**` 배너 추가

### 관련 코드

- `services/integration-hub/src/main/kotlin/kr/ocr/intgr/routes/IdVerifyRoute.kt`
- `services/integration-hub/src/main/kotlin/kr/ocr/intgr/dto/IdVerifyDto.kt`
- `services/integration-hub/src/main/kotlin/kr/ocr/intgr/mock/MockAgencyController.kt` (`#idVerifyMock`)
- `services/integration-hub/src/main/resources/application.yml` (`ocr.integration.agencies.id-verify`)

---

## KISA TSA 타임스탬프 (RFC 3161)

**현재 상태**: mock (NOT_IMPLEMENTED = true) — 반환 token은 실 RFC 3161 서명이 아닌 dummy DER blob  
**코드 마커**: `TsaRoute.NOT_IMPLEMENTED`, `TSAResponse.notImplemented`

### API 개요

| 항목 | 내용 |
|---|---|
| 서비스명 | KISA 공인 타임스탬프 서비스 (RFC 3161 준거) |
| 프로토콜 | HTTP(S) over TSP (Time-Stamp Protocol, RFC 3161) |
| 인증 | IP 화이트리스트 + (선택) 클라이언트 인증서 |
| 호출 경로 | http://tsa.kisa.or.kr/... (실 URL은 계약 후 확인) |
| 정책 OID | `1.2.410.200001.1` (KISA TSA 정책 — mock에서 동일값 사용) |
| Rate limit | 기관별 협의 |

### RFC 3161 요청·응답 구조

**실 구현 시 흐름**:
1. BouncyCastle `TimeStampRequestGenerator`로 DER 인코딩 `TimeStampReq` 생성
2. HTTP POST (Content-Type: `application/timestamp-query`)
3. `TimeStampResponse` DER 수신 → `TimeStampToken` 추출
4. token Base64 인코딩 후 `TSAResponse.token`에 저장

**BouncyCastle 코드 scaffold** (Phase 2):
```kotlin
// NOT_IMPLEMENTED: 현재 dummy DER blob 반환 중
// 실 전환 시 아래 코드 활성화 (TsaRoute.kt에 추가)
import org.bouncycastle.tsp.TimeStampRequestGenerator
import org.bouncycastle.tsp.TimeStampResponse

fun buildRealTsaRequest(sha256Hex: String): ByteArray {
    val gen = TimeStampRequestGenerator()
    gen.setCertReq(true)
    val hash = sha256Hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    val req = gen.generate(
        org.bouncycastle.asn1.nist.NISTObjectIdentifiers.id_sha256,
        hash
    )
    return req.encoded
}
```

**요청 예시** (JSON 래퍼, 현재 mock API 형식):
```json
{
  "sha256": "aabbcc...64자 hex",
  "nonce": "1234567890abcdef",
  "req_cert_info": true
}
```

**응답 예시**:
```json
{
  "token": "MIIHMgYJKoZIhvcNAQcCoIIHIzCC...(Base64 DER)",
  "serial_number": "2A3B4C5D6E7F8001",
  "gen_time": "2026-04-22T10:00:00Z",
  "policy_oid": "1.2.410.200001.1"
}
```

### 계약 절차

| 항목 | 내용 |
|---|---|
| 접촉처 | KISA 타임스탬프 서비스 운영팀 (tsa@kisa.or.kr — 실제 이메일 확인 필요) |
| 필요 서류 | 사업자등록증 · 서비스 설명서 · 보안서약서 |
| 평균 소요 | 1-2주 |
| 비용 | 건당 과금 또는 월정액 (KISA와 협의) |
| IP 화이트리스트 | egress gateway 고정 IP 등록 필요 |

### 전환 체크리스트

1. KISA TSA test 계정 수령 및 IP 화이트리스트 등록
2. `kv/external/agencies/tsa` OpenBao KV에 접속 정보 저장
   ```bash
   bao kv put kv/external/agencies/tsa \
     url="http://tsa.kisa.or.kr/..." whitelist_ip="<egress-gw-ip>"
   ```
3. ESO `ExternalSecret` 생성 → integration-hub Secret mount
4. `application.yml`의 `ocr.integration.agencies.tsa.url` → 실 엔드포인트
5. `TsaRoute.kt`의 BouncyCastle `TimeStampRequestGenerator` 코드 활성화
6. `TsaRoute.NOT_IMPLEMENTED = false`
7. `TSAResponse.notImplemented` 기본값 `false`로 변경
8. admin-ui `/integration-test` 배너 자동 제거 확인
9. 감사 로그에 전환 이벤트 1회 기록
10. 스모크: 테스트 SHA-256 10건 타임스탬프 발급 → 토큰 검증 (`TimeStampResponse.validate()`)
11. 전환 완료 후 이 섹션 상단에 `**상태: 운영 중 (YYYY-MM-DD 전환)**` 배너 추가

### 관련 코드

- `services/integration-hub/src/main/kotlin/kr/ocr/intgr/routes/TsaRoute.kt`
- `services/integration-hub/src/main/kotlin/kr/ocr/intgr/dto/TsaDto.kt`
- `services/integration-hub/src/main/kotlin/kr/ocr/intgr/mock/MockAgencyController.kt` (`#tsaMock`)
- `services/integration-hub/src/main/resources/application.yml` (`ocr.integration.agencies.tsa`)
- BouncyCastle 의존성: `build.gradle.kts` (`bcprov-jdk18on`, `bcpkix-jdk18on`)

---

## OCSP 인증서 검증

**현재 상태**: mock (NOT_IMPLEMENTED = true) — 항상 "good" 반환  
**코드 마커**: `OcspRoute.NOT_IMPLEMENTED`, `OcspResponse.notImplemented`

### API 개요

| 항목 | 내용 |
|---|---|
| 서비스명 | KISA 인증서 유효성 검증 (OCSP, RFC 6960) |
| 프로토콜 | HTTP over OCSP (Online Certificate Status Protocol) |
| 인증 | 없음 (공개 OCSP 응답자) 또는 IP 화이트리스트 |
| 호출 경로 | http://ocsp.kisa.or.kr/... (실 URL은 인증서 AIA 확장에서 추출) |
| 응답 형식 | ASN.1 DER (`application/ocsp-response`) |
| TTL | `nextUpdate` 필드 기준 (일반적으로 24시간) |

### OCSP 요청·응답 구조

**실 구현 시 흐름**:
1. BouncyCastle `OCSPReqBuilder`로 DER 인코딩 `OCSPReq` 생성
2. HTTP POST (Content-Type: `application/ocsp-request`)
3. `BasicOCSPResp` 파싱 → `status` 추출 (`CertificateStatus.GOOD` / `RevokedStatus` / `UnknownStatus`)
4. 결과를 `OcspResponse.status` ("good"/"revoked"/"unknown")로 매핑

**BouncyCastle 코드 scaffold** (Phase 2):
```kotlin
// NOT_IMPLEMENTED: 현재 더미 응답(always "good") 반환 중
// 실 전환 시 아래 코드 활성화 (OcspRoute.kt에 추가)
import org.bouncycastle.cert.ocsp.OCSPReqBuilder
import org.bouncycastle.cert.ocsp.CertificateID
import org.bouncycastle.cert.ocsp.BasicOCSPResp

fun buildOcspRequest(issuerCert: X509Certificate, serialNumber: BigInteger): ByteArray {
    val id = CertificateID(
        JcaDigestCalculatorProviderBuilder().build().get(CertificateID.HASH_SHA1),
        JcaX509CertificateHolder(issuerCert),
        serialNumber
    )
    return OCSPReqBuilder().addRequest(id).build().encoded
}
```

**요청 예시** (JSON 래퍼, 현재 mock API 형식):
```json
{
  "issuer_cn": "KISA-RootCA-G1",
  "serial": "0123456789abcdef"
}
```

**응답 예시**:
```json
// good (유효)
{
  "status": "good",
  "this_update": "2026-04-22T00:00:00Z",
  "next_update": "2026-04-23T00:00:00Z"
}

// revoked (폐기)
{
  "status": "revoked",
  "this_update": "2026-04-22T00:00:00Z",
  "revoked_at": "2026-01-01T00:00:00Z"
}
```

### 계약 절차

| 항목 | 내용 |
|---|---|
| 접촉처 | KISA 인증서 운영팀 (공개 OCSP는 별도 계약 없이 사용 가능, 단 Rate limit 존재) |
| 필요 서류 | 공개 OCSP의 경우 서류 불필요. 전용 OCSP 응답자 필요 시 협의. |
| 평균 소요 | 공개 OCSP: 즉시. 전용: 1-2주 |
| 비용 | 공개 OCSP: 무료. 전용: KISA와 협의 |
| 제약사항 | AIA(Authority Information Access) 확장에서 OCSP URL 추출 권장 |

### 전환 체크리스트

1. KISA 공개 OCSP URL 확인 (인증서 AIA 확장에서 추출 또는 KISA 문서 참조)
2. `kv/external/agencies/ocsp` OpenBao KV에 URL 저장
   ```bash
   bao kv put kv/external/agencies/ocsp \
     url="http://ocsp.kisa.or.kr/..."
   ```
3. `application.yml`의 `ocr.integration.agencies.ocsp.url` → 실 OCSP 엔드포인트
4. `OcspRoute.kt`의 BouncyCastle `OCSPReqBuilder` 코드 활성화
5. `OcspRoute.NOT_IMPLEMENTED = false`
6. `OcspResponse.notImplemented` 기본값 `false`로 변경
7. admin-ui `/integration-test` 배너 자동 제거 확인
8. 감사 로그에 전환 이벤트 1회 기록
9. 스모크: 유효 인증서 5건 + 폐기 인증서 2건 OCSP 검증 → 상태 정확도 확인
10. 전환 완료 후 이 섹션 상단에 `**상태: 운영 중 (YYYY-MM-DD 전환)**` 배너 추가

### 관련 코드

- `services/integration-hub/src/main/kotlin/kr/ocr/intgr/routes/OcspRoute.kt`
- `services/integration-hub/src/main/kotlin/kr/ocr/intgr/dto/OcspDto.kt`
- `services/integration-hub/src/main/kotlin/kr/ocr/intgr/mock/MockAgencyController.kt` (`#ocspMock`)
- `services/integration-hub/src/main/resources/application.yml` (`ocr.integration.agencies.ocsp`)

---

## SoftHSM PKCS#11

**현재 상태**: dummy signer 비활성화  
**관련 코드**: `services/upload-api` FPE 서비스 연동 부분  
**upload-api not-implemented 항목**: `feature: "SoftHSM PKCS#11 실 서명"`

### 개요

| 항목 | 내용 |
|---|---|
| 목적 | RRN 등 민감정보 암호화 키의 HSM 보관 및 서명 연산 오프로드 |
| 개발 환경 | SoftHSM2 (OSS) — 기능 동일하나 물리적 변조 방지 없음 |
| 프로덕션 | 실 HSM 조달 필요 (Thales Luna Network HSM 또는 동급) |
| FIPS 요건 | FIPS 140-3 Level 3 이상 (공공 보안 요건) |
| 전환 트리거 | 실 HSM 조달 + PKCS#11 URI 확보 |

### 전환 체크리스트

1. 실 HSM 조달 및 설치 (데이터센터 또는 클라우드 HSM)
2. HSM 초기화 및 키 생성 (HSM 벤더 CLI 사용)
3. PKCS#11 라이브러리 경로 확인 (`/usr/lib/libCryptoki2_64.so` 등)
4. BouncyCastle PKCS11 provider 설정
5. `HsmSigner.kt` (Phase 2 생성) — `NOT_IMPLEMENTED` flag 제거
6. upload-api `application.yml` HSM PKCS#11 URI 설정
7. integration-hub RRN 암호화 경로 활성화
8. 스모크: 서명 + 검증 10회 → 성공률 확인

---

## FIPS 140-3 암호화 라이브러리

**현재 상태**: OSS FF3 사용 중  
**upload-api not-implemented 항목**: `feature: "FIPS 140-3 암호화 라이브러리"`

### 개요

| 항목 | 내용 |
|---|---|
| 현재 | FF3 (Format-Preserving Encryption) OSS 구현 |
| 요건 | FIPS 140-3 인증 라이브러리 (공공기관 요건) |
| 후보 | Bouncy Castle FIPS (`bc-fips-1.0.x.jar`) 또는 국가공인 라이브러리 |
| 전환 트리거 | ISMS-P 심사 전 또는 조달 요구사항 확정 시 |

### 전환 체크리스트

1. 국가공인 암호 라이브러리 검토 (ARIA, LEA 지원 여부)
2. `bc-fips` 라이센스 확인 (상용 라이선스 요구 가능)
3. `build.gradle.kts` 의존성 교체 (`bcprov-jdk18on` → `bc-fips`)
4. FPE 암호화 알고리즘 검증 (FF1/FF3-1 FIPS 준수 여부)
5. 단위 테스트 전체 통과 확인
6. ISMS-P 심사 준비 문서 갱신

---

## 일반 전환 절차 체크리스트 (모든 기관 공통)

이 절차는 모든 외부 기관 어댑터 전환 시 공통으로 실행한다.

1. test API 접근권 확보 (기관 담당자 연락 → 계약 → 계정 발급)
2. 인증서·키를 OpenBao KV에 저장
   ```bash
   bao kv put kv/external/agencies/<기관명> \
     client_cert=@<cert.pem> client_key=@<key.pem>
   ```
3. ESO `ExternalSecret` 배포 → integration-hub Secret mount 확인
4. `application.yml` URL 업데이트 + ConfigMap 또는 env 변경
5. NetworkPolicy: integration-hub → egress-gateway 허용 블록 활성화
   - `infra/manifests/integration-hub/network-policies.yaml` Egress Gateway 주석 해제
6. Egress Gateway 화이트리스트에 기관 FQDN 추가
7. `*Route.NOT_IMPLEMENTED = false` 변경
8. `*Response.notImplemented` 기본값 `false` 변경
9. 통합 smoke 10 요청 수행
10. 감사 로그 전환 이벤트 1건 기록
11. admin-ui `/integration-test` 배너 자동 제거 확인
12. 해당 섹션 상단에 `**상태: 운영 중 (YYYY-MM-DD 전환)**` 배너 추가

---

## 가이드 문서 관리

- 새 기관 추가 시 이 문서에 섹션 추가 (구조 공통: 개요 · 요청응답 · 계약절차 · 전환체크리스트 · 관련코드)
- 전환 완료 시 해당 섹션 위에 `**상태: 운영 중 (YYYY-MM-DD 전환)**` 배너 추가
- 이 문서의 anchor는 코드 `GUIDE_ANCHOR` 상수와 **반드시 1:1 일치** 유지
- 관련 정책: POLICY-NI-01, POLICY-EXT-01 (프로젝트 루트 `CLAUDE.md` 참조)

| anchor | 코드 상수 위치 |
|---|---|
| `행안부-주민등록-진위확인` | `IdVerifyRoute.GUIDE_ANCHOR` |
| `kisa-tsa-타임스탬프-rfc-3161` | `TsaRoute.GUIDE_ANCHOR` |
| `ocsp-인증서-검증` | `OcspRoute.GUIDE_ANCHOR` |
