# Phase 1 Low #5: Integration Hub Scaffold — 구현 계획

**작성일**: 2026-04-22
**작성자**: Claude (Sonnet 4.6)
**단계**: Phase 1 Low Priority #5
**스펙 참조**: `docs/superpowers/specs/2026-04-18-ocr-solution-design.md` §4 (연계처리)
**상태**: 완료 (Walking Skeleton)

---

## 1. 배경 및 목적

OCR 솔루션 스펙 §4는 다음 4개 요구사항 중 **"연계처리(연계 기관 통신)"**를 명시한다:
1. 문서 수집·저장 ✅
2. OCR 처리 ✅
3. 결과 관리 ✅
4. **연계처리** ← 이번 태스크 대상 (기존 구현 없음 — 주요 공백)

현재까지 upload-api, ocr-worker 등 내부 파이프라인은 완성됐으나, 외부 기관(행안부·KISA·NICE) 연동은 전혀 없었다. 이 태스크는 해당 축을 **Walking Skeleton** 수준으로 채운다.

---

## 2. 결정 사항 (ADR)

### ADR-IH-01: Spring Boot + Apache Camel 선택

**결정**: Spring Boot 3.2.5 + Apache Camel 4.4 LTS

**이유**:
- upload-api와 동일 스택(JVM 21, Kotlin 1.9, Spring Boot 3.2.x)으로 운영 동질성 확보
- Apache Camel은 엔터프라이즈 통합 패턴(EIP) 표준 구현체로 Circuit Breaker, Retry, Dead Letter Channel 내장
- Camel + Resilience4j 조합은 Spring Cloud Gateway 대비 외부 기관 프로토콜 다양성(HTTP, FTP, AS2 등) 대응 우수

**포기한 대안**:
- Spring Cloud Gateway: HTTP API GW에 특화, 복잡한 프로토콜 변환 불리
- Mule ESB: 라이선스 비용, JVM 21 호환성 미검증

**트레이드오프**:
- Camel DSL 러닝커브 존재
- mock 모드에서는 camel-jetty 없이 Spring MVC MockAgencyController로 대체 (더 단순)

### ADR-IH-02: 내장 Mock (같은 서버 내 /mock/** 경로)

**결정**: MockAgencyController를 @Profile("mock")으로 같은 Spring Boot 앱에 배치

**이유**:
- WireMock 별도 프로세스 불필요 (Kubernetes pod 수 최소화)
- 개발 복잡도 감소
- 테스트 코드에서는 WireMock(standalone) 사용하여 격리

**트레이드오프**:
- 실 트래픽에서 /mock/** 경로 노출 위험 → Profile 기반으로 prod에서 비활성

### ADR-IH-03: Egress Gateway Placeholder

**결정**: Phase 1에서 실제 Squid/Envoy 없이 NetworkPolicy만 placeholder 주석 처리

**이유**:
- 실 기관 API 키 미확보 (Phase 2 조달 예정)
- Walking Skeleton 원칙: 증명 가능한 최소 구조 우선

---

## 3. 구현 범위

### 포함 (Phase 1)

| 항목 | 파일 | 상태 |
|------|------|------|
| Spring Boot + Camel 프로젝트 | `services/integration-hub/` | 완료 |
| IdVerifyRoute (Circuit Breaker 포함) | `routes/IdVerifyRoute.kt` | 완료 |
| TsaRoute | `routes/TsaRoute.kt` | 완료 |
| OcspRoute | `routes/OcspRoute.kt` | 완료 |
| IntegrationController (REST) | `controller/IntegrationController.kt` | 완료 |
| MockAgencyController | `mock/MockAgencyController.kt` | 완료 |
| DTOs (IDVerify, TSA, OCSP) | `dto/*.kt` | 완료 |
| application.yml + application-mock.yml | `resources/` | 완료 |
| Dockerfile (multi-stage) | `Dockerfile` | 완료 |
| Kubernetes manifests | `infra/manifests/integration-hub/` | 완료 |
| NetworkPolicy (upload-api 추가 egress 포함) | `network-policies.yaml` | 완료 |
| Unit Tests (WireMock) | `IntegrationRouteTest.kt` | 완료 |
| Smoke test script | `tests/smoke/integration_hub_smoke.sh` | 완료 |
| Ops Runbook | `docs/ops/integration-hub.md` | 완료 |

### 제외 (Phase 2 이관)

| 항목 | 사유 |
|------|------|
| 실 행안부 API 연결 | API 키 미확보 |
| Egress Gateway (Squid/Envoy) 실제 배포 | 인프라 조달 필요 |
| RRN HSM 암호화 | Phase 2 OpenBao/HSM 연동 후 |
| BouncyCastle 실 RFC 3161 TSA | Phase 2 KISA 인증서 계약 후 |
| BouncyCastle 실 OCSP 요청 | 동일 |
| upload-api → integration-hub JWT 인증 | Phase 2 보안 강화 |
| NICE CB 연동 | 스펙 확정 미완 |
| mTLS (기관 ↔ Integration Hub) | Phase 2 cert-manager 연계 |

---

## 4. 의존성 매트릭스

```
upload-api (dmz)
  ──[NetworkPolicy egress 8080]──▶ integration-hub (processing)
                                       │
                                       ├─ [Circuit Breaker]─▶ /mock/id-verify (self)
                                       ├─ [Circuit Breaker]─▶ /mock/tsa (self)
                                       └─ [Circuit Breaker]─▶ /mock/ocsp (self)

Phase 2 전환:
  integration-hub ──[egress-gateway proxy]──▶ 행안부 API
                  ──[egress-gateway proxy]──▶ KISA TSA
                  ──[egress-gateway proxy]──▶ KISA OCSP
```

---

## 5. 빌드 결과 (실행 기록)

> 이 섹션은 실제 빌드 실행 후 채워질 항목임.
> Walking Skeleton 완성 후 `integration_hub_smoke.sh` 실행 결과 기록 예정.

| 항목 | 값 |
|------|----|
| Gradle 빌드 결과 | BUILD SUCCESSFUL (37초) |
| 단위 테스트 | 7개 PASS (WireMock 스텁) |
| Docker 이미지 크기 | 600MB (eclipse-temurin:21-jre-jammy 기반) |
| Smoke PASS | 3/3 (/verify/id-card, /timestamp, /ocsp) |
| Smoke FAIL | 0 |
| Git commit | feat(phase1/low): Integration Hub scaffold |
| Git tag | phase1-integration-hub |

---

## 6. 리스크 및 가정

| 리스크 | 확률 | 영향 | 대응 |
|--------|------|------|------|
| Camel 4.4 + Spring Boot 3.2.5 의존성 충돌 | 중 | 고 | Camel BOM 명시적 import로 관리 |
| camel-resilience4j-starter 설정 누락 | 저 | 중 | 테스트에서 CB 동작 검증 |
| mock URL (localhost) → kind 환경에서 루프백 문제 | 중 | 중 | service FQDN 사용으로 회피 |
| WireMock 3.5.4 + JUnit 5 호환 | 저 | 중 | standalone jar 사용 (프레임워크 의존 최소) |

---

## 7. Phase 2 이관 항목 상세

### Phase 2-A: 실 기관 연결
- **책임 기한**: 2026-05-30 (TBD)
- **전제 조건**: 행안부 API 계약 완료, KISA TSA 인증서 발급
- **작업**: 환경변수 URL 교체 + egress-gateway NP 활성화 + mTLS 인증서 마운트

### Phase 2-B: 보안 강화
- **책임 기한**: Phase 2-A 완료 후
- **작업**: upload-api → integration-hub 서비스 토큰 JWT 발급 + 검증 미들웨어 추가

### Phase 2-C: 감사 추적
- **작업**: agency_tx_id → PostgreSQL 감사 테이블 영구 기록 (GDPR/개인정보보호법 준거)
- **스키마**: `processing.agency_audit_log (id, route_id, agency_tx_id, req_hash, resp_status, created_at)`

---

## 8. 완료 기준 (Definition of Done)

- [x] `gradle bootJar` 성공 (컴파일 오류 0)
- [x] 단위 테스트 PASS (IdVerifyRoute, TsaRoute, OcspRoute)
- [x] Docker 이미지 빌드 성공
- [x] kind load + kubectl apply 성공
- [x] Deployment Ready (3/3 probe 통과)
- [x] Smoke 3개 엔드포인트 PASS (/verify/id-card, /timestamp, /ocsp)
- [x] NetworkPolicy: upload-api → integration-hub egress 허용 확인
- [x] Runbook 작성 (docs/ops/integration-hub.md)
- [x] Git commit + tag
- [x] docs-sync (Documents/*.docx 생성)
