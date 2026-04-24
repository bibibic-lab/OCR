# 원 범위 계획·설계 보존 (2026-04-23 축소 전)

## 문서 목적

이 프로젝트의 **원 스펙 기준 전 범위 계획과 설계**를 보존한다. 2026-04-23 유저 지정으로 진행 범위가 **6가지 기본 기능**으로 축소되었으며, 이 문서는 차후 상업 프로덕션·Phase 2·DR 진입 시 참조할 **deferred roadmap**이다.

**정본 스펙**: `docs/superpowers/specs/2026-04-18-ocr-solution-design.md` (1006 lines)
**현 범위 정책**: `~/.claude/projects/-Users-jimmy--Workspace/memory/project_scope_v2_basic_flow.md`
**관련 정책**: POLICY-NI-01 (Not Implemented 3지점 표시), POLICY-EXT-01 (외부연계 전면 더미)

---

## 원 스펙 요약 (상업 프로덕션 기준)

### 비전

상업용 OCR 엔진(CLOVA·삼성SDS·카카오 등) 수준의 인식률을 가진 **금융+공공 복합 엔터프라이즈 문서 처리 플랫폼**. 단순 OCR이 아닌 **업로드–문자인식–인증(내외부연계)–자료관리–물리파일관리** 전 과정 통합 솔루션.

### 4대 요구사항

1. **OCR 상업용 인식률**
2. **연계처리**: 외부망(인터넷) ↔ 내부망(처리서버) + 외부 기관 10+ 연계
3. **압축암호화**: 단순 암호화 이상, 다중 레이어 방어 (6겹)
4. **백오피스**: 업로드·인식·인증·자료관리·물리파일 통합 + 사용자/권한 관리

### Phase 구분

- **Phase 1 MVP** (4-6개월): 행안부·사업자·KISA TSA 3 기관 연계, OCR 엔진, 기본 백오피스, 핵심 보안
- **Phase 2** (3-4개월): 간편인증(PASS·카카오·네이버·토스), 계좌실명확인, 고급 기능, DR
- **Phase 3** (지속): 신용조회(NICE·KCB), 자체 학습 루프, 모델 고도화

---

## 원 스펙의 완전 기술 스택

| 레이어 | 컴포넌트 | 라이선스 |
|---|---|---|
| OCR 엔진 | PaddleOCR PP-OCRv4 + PP-Structure + SLANet | Apache 2.0 |
| 정형 KIE | Donut | MIT |
| 반정형 KIE | LiLT + Donut | MIT |
| 필기체 | TrOCR (한국어 파인튜닝) | MIT |
| 추론 서버 | Triton Inference Server | BSD-3 |
| 모델 관리 | MLflow Model Registry | - |
| API Gateway | Spring Cloud Gateway | Apache 2.0 |
| 워크플로 | Camunda 7 Community | Apache 2.0 |
| 외부연계 통합 | Apache Camel + Bouncy Castle | Apache 2.0 |
| SSO | Keycloak | Apache 2.0 |
| 권한 정책 | OPA | Apache 2.0 |
| 메시징 | Apache Kafka + MirrorMaker 2 | Apache 2.0 |
| 객체 스토리지 | SeaweedFS | Apache 2.0 |
| KMS | OpenBao | MPL 2.0 |
| DB | PostgreSQL (CloudNativePG) | PostgreSQL |
| 검색/로그 | OpenSearch | Apache 2.0 |
| 관측 | Prometheus + Grafana | Apache 2.0 |
| 편집기 | Collabora Online | MPL 2.0 |
| AV | ClamAV | GPL 2.0 |
| PDF | pdf2image + pdfplumber + pikepdf | BSD/MIT |
| 암호 | age / libsodium / Zstandard | BSD/ISC |
| HITL | Label Studio | Apache 2.0 |
| GitOps | ArgoCD | Apache 2.0 |
| CNI | Cilium | Apache 2.0 |

**v2 축소로 미구현**: Triton · MLflow · Donut · LiLT · TrOCR · Camunda · Collabora · Label Studio · Kafka(MirrorMaker)

---

## 원 스펙 아키텍처 (축소 전)

### 1. 3존 분리 (외부망·내부망·관리망) + 5 네임스페이스

- **외부망 (DMZ)**: 브라우저·모바일 접점. Upload API · NGINX Ingress · DMZ SeaweedFS(Staging TTL≤1h) · Egress presigned
- **내부망 (Processing)**: OCR Worker · KIE Worker · Archive Worker · Internal SeaweedFS · pg-main · Kafka
- **관리망 (Admin)**: 백오피스 UI · Keycloak · OPA · Camunda · 감사 로그 영속
- **Security**: OpenBao · cert-manager · PKCS#11/HSM · pg-pii(PII 원본)
- **Observability**: Prometheus · OpenSearch · Grafana · Fluentbit

**하이브리드 문서유통**: Collabora Online 웹 에디터 + Egress Gateway로 수정 후 재제출 사이클 지원

### 2. 6겹 암호화 설계

| Layer | 설명 | 구현 위치 |
|---|---|---|
| L1 | 클라이언트 사전암호화 | 브라우저 WebCrypto FF1 → DEK AES-256-GCM + 청크 8MB + Zstandard |
| L2 | TLS 전송 | HTTPS + mTLS (browser→DMZ) + HMAC 서명 |
| L3 | DMZ↔Internal 전송 | TLS + mTLS (cross-zone) |
| L4 | DMZ 저장 | DMZ SeaweedFS 암호화본 + SSE |
| L5 | 내부 저장 | Storage-KEK 재암호화 3층 (DEK/KEK/Storage-KEK) |
| L6 | 필드 토큰화 | OpenBao Transform FPE (RRN·카드·계좌·여권번호) |

**3계층 KEK**: Upload-KEK (1년 로테이션) · Storage-KEK (1년) · Egress-KEK (1년) + 파일별 DEK (90일)

**Crypto-shredding**: 파기 요청 시 DEK 삭제 → 암호문 복호화 불가 → GDPR·PIPA 수초 내 대응

### 3. OCR 처리 파이프라인 9단계

1. **전처리**: PDF 렌더링 300DPI · Orientation 보정 · Deskew · Perspective correction · Denoise
2. **문서 분류**: MobileNetV3 또는 CLIP+SVM → {주민증·운전면허·여권·사업자·계약서·영수증·송장·기타}
3. **레이아웃 분석**: PP-Structure → 텍스트블록·표·도장·서명·사진 영역 분리 + reading order
4. **텍스트 검출+인식**: PP-OCRv4 (DB++ 검출 + SVTR 인식, 다국어, line-level confidence)
5. **KIE 분기**:
   - 정형(신분증·여권·사업자): **Donut** end-to-end 구조화
   - 반정형(계약서·송장·영수증): **LiLT + BIO 태깅**
   - 표(재무제표·명세): **SLANet** → HTML 테이블
6. **후처리·검증**: 체크섬(주민번호·사업자·카드 Luhn·계좌) · 정규식 · 도메인 사전 교정 · 상호 일관성
7. **민감필드 토큰화** (L6)
8. **신뢰도 라우팅**: 전필드 ≥임계치 → 자동 승인; 일부 낮음 → HITL 검토 큐; 다수 실패 → 관리자 알림
9. **결과 영구화**: PostgreSQL(메타) + Internal SeaweedFS Archive(본문)

**상업용 수준 달성 전략**:
- 도메인 파인튜닝 (Donut/LiLT 1~5만장 재학습) → 정형 95% → 98%
- Synthetic data 증강 (TextRecognitionDataGenerator)
- Active Learning 루프 (HITL → 주간 재학습)
- 도메인 Lexicon (기업명·주소·약관)
- 이미지 품질 게이트
- 앙상블 투표 (PP-OCRv4 + Donut 불일치 시 HITL)

### 4. 외부기관 연계 10+ 기관

| 용도 | 기관 | 프로토콜 |
|---|---|---|
| 신분증 진위확인 | 행안부 주민등록 진위 · NICE 신분증스캔 | REST · SOAP |
| 운전면허 진위 | 경찰청 | SOAP |
| 외국인등록 진위 | 법무부 | SOAP |
| 사업자등록 진위 | 국세청 홈택스 | REST |
| 본인확인(간편인증) | PASS · 카카오 · 네이버 · 토스 | OAuth 2.0 + 서명 |
| 계좌실명확인 | 금융결제원 오픈뱅킹 | REST |
| 신용조회 | NICE · KCB | 전용 API (mTLS) |
| 전자서명 | 공인인증서 + 모두싸인·글로사인 | PKCS#11 · REST |
| 타임스탬프 | KISA TSA · 한국전자인증 | RFC 3161 (TSP) |
| 인증서 검증 | OCSP / CRL | OCSP · HTTP |

**Integration Hub**: Spring + Apache Camel + Resilience4j (Bulkhead per 기관, Circuit Breaker) + Egress Proxy (Squid/Envoy 화이트리스트) + PKCS#11/HSM 서명 + 감사 로그

### 5. 백오피스 7개 섹션

1. **대시보드**: 업로드·처리·인증 실시간 지표 (처리량·성공률·p99 지연·오류율·HITL 큐·SLA)
2. **문서 관리**: 검색·조회·편집·재처리·파기 요청
3. **HITL 검토 큐**: Label Studio 임베딩 · OCR 결과 오버레이 · 인라인 수정 · 재학습 데이터 편입
4. **외부연계 관리**: 기관별 호출 이력 · Circuit 상태 · 자격증명 관리
5. **사용자·권한**: SoD 8 Role (Submitter·Reviewer·Approver·Auditor·Admin·PII-Admin·OCR-Ops·External-Ops)
6. **감사 로그**: append-only · 해시체인 블록 서명 · WORM 아카이브
7. **운영**: 키 로테이션·모델 A/B·파기 승인 2인

**Camunda BPMN 워크플로**: 검토 큐 → 담당자 배정 → SLA 기한 → 승인 → 재처리·파기 루틴

### 6. 관측성·운영

- **PrometheusRule**: pg lag, openbao sealed, argocd sync fail, hubble down, 워크로드 OOM, OCR 지연 p99
- **Grafana 대시보드**: OCR 성능 · 외부연계 Circuit · PII 접근 · 컴플라이언스
- **OpenSearch**: 로그 (Fluentbit) · 감사 (해시체인) · 검색 (문서 메타)
- **알람**: Slack/PagerDuty · 야간 페이지 대상(P1/P2)
- **ISM retention**: 로그 30일, 감사 7년(원본 3년 + Object Lock 4년)

### 7. DR/HA

- **Tier-1 Critical** (RTO 2h, RPO 15분): 업로드 API, OCR Worker, OpenBao, 외부연계, Kafka
- **복제**: pg-main 3-instance sync + cross-site async · SeaweedFS Replication=3 + Remote Storage
- **백업**: 일일 스냅샷 · WAL archiving + Object Lock 영구
- **DR 사이트**: Active-Standby · 분기 DR 훈련
- **PDB**: maxUnavailable 적절히

---

## v2 축소 이후 Out-of-Scope 항목

아래 항목은 **현재 작업 범위에서 제외**. 프로덕션 출시·Phase 2 진입 시 재편입.

### 암호화 심화 (deferred 10-15h)
- [ ] L1 클라이언트 사전암호화 (WebCrypto FF1 + Zstandard + 청크)
- [ ] L3 mTLS (DMZ ↔ Internal, 서비스간)
- [ ] L4 DMZ SeaweedFS SSE
- [ ] L5 3층 KEK 재암호화 파이프라인 (현재 L6만 구현)
- [ ] Crypto-shredding 파기 API
- [ ] KEK 자동 로테이션 CronJob (Upload/Storage/Egress 각 1년, DEK 90일)
- [ ] 실 HSM 조달 + PKCS#11 실 서명 (현재 SoftHSM + 자체 unsealer)
- [ ] FIPS 140-3 인증 라이브러리 (현재 OSS FF3)
- [ ] age · libsodium · Zstandard 실제 클라이언트 통합

### OCR 고도화 (deferred 20-40h)
- [ ] Donut KIE (정형 문서: 신분증·여권·사업자)
- [ ] LiLT + BIO 태깅 (반정형: 계약서·송장·영수증)
- [ ] TrOCR 한국어 파인튜닝 (필기체)
- [ ] PP-Structure SLANet (표 구조화)
- [ ] Triton Inference Server + GPU
- [ ] MLflow Model Registry
- [ ] 도메인 파인튜닝 (1-5만장 재학습)
- [ ] Synthetic data 증강 (TextRecognitionDataGenerator)
- [ ] Active Learning 루프
- [ ] 도메인 Lexicon 주입
- [ ] 이미지 품질 게이트 (업로드 시 해상도·블러·조명 점수)
- [ ] 앙상블 투표 (PP-OCRv4 + Donut 불일치 → HITL)
- [ ] 모델 A/B 테스트 파이프라인
- [ ] HITL (Label Studio 임베딩)
- [ ] 문서 분류기 (MobileNetV3 또는 CLIP+SVM)

### 외부연계 확대 (deferred, POLICY-EXT-01 하에 가이드 대체됨)
- [ ] 경찰청 운전면허 진위 SOAP
- [ ] 법무부 외국인등록 SOAP
- [ ] 국세청 홈택스 REST
- [ ] PASS OAuth 2.0 + 서명
- [ ] 카카오 인증
- [ ] 네이버 인증
- [ ] 토스 인증
- [ ] 금융결제원 오픈뱅킹 (계좌실명)
- [ ] NICE 신용조회 mTLS
- [ ] KCB 신용조회
- [ ] 모두싸인·글로사인 전자서명 REST
- [ ] 한국전자인증 TSA (RFC 3161)
- [ ] Egress Gateway 실 배포 (Squid/Envoy + TLS 재암호화 + 감사로그)
- [ ] PKCS#11 실 서명 (Bouncy Castle + HSM)
- [ ] OCSP/CRL 실 검증

### 백오피스 심화 (deferred 20-30h)
- [ ] SoD 8 Role별 상세 화면 분리 (Reviewer·Approver·Auditor·Admin·PII-Admin·OCR-Ops·External-Ops)
- [ ] Camunda BPMN 워크플로 엔진 배포
- [ ] 검토 큐 → 담당자 배정 → SLA 기한 → 승인 루틴
- [ ] HITL Label Studio 임베딩
- [ ] 감사 로그 전용 조회 UI (해시체인 검증 · 필드 drill-down)
- [ ] WORM 아카이브 관리 UI
- [ ] 원본 열람 step-up MFA + 2인 승인
- [ ] 키 로테이션 UI
- [ ] 모델 A/B 테스트 UI
- [ ] 파기 요청 2인 승인 UI
- [ ] 외부연계 Circuit 상태 대시보드
- [ ] 자격증명 관리 UI (Keycloak client secret 등)
- [ ] Collabora Online 문서 편집 임베딩

### 인프라·운영 심화 (deferred 15-25h)
- [ ] Apache Kafka (upload-topic + MirrorMaker 2 cross-zone)
- [ ] NGINX Ingress Controller
- [ ] Spring Cloud Gateway (API Gateway)
- [ ] OPA 권한 정책 엔진
- [ ] ClamAV AV 스캔 (격리 sandbox ns)
- [ ] 워크로드 PrometheusRule (OOM · OCR 지연 · Circuit 상태)
- [ ] Grafana 대시보드 (OCR 성능 · 외부연계 · PII 접근 · 컴플라이언스)
- [ ] Slack/PagerDuty 알람 통합
- [ ] ISM retention policy (로그 30일, 감사 7년 Object Lock)
- [ ] renovate / Dependabot 의존성 자동 업데이트
- [ ] ArgoCD Image Updater
- [ ] ArgoCD Notifications (Slack 웹훅)

### DR/HA (deferred 20-30h)
- [ ] pg-main 3-instance sync replication
- [ ] pg-pii 3-instance
- [ ] OpenBao 3-node Raft (Cilium identity 매칭 이슈 해결)
- [ ] SeaweedFS Replication=3 rack-aware
- [ ] SeaweedFS Remote Storage (cross-site async 복제)
- [ ] DR 사이트 Active-Standby scaffold
- [ ] 분기 DR 훈련 절차
- [ ] PDB maxUnavailable 적정화 (현재 4곳 maxUnavailable=0)
- [ ] RTO/RPO 측정 스크립트

---

## 재편입 트리거

아래 시그널 중 하나라도 발생 시 이 문서를 재참조하여 로드맵 확장:

1. 유저가 "상업 출시 준비", "Phase 2 진입", "프로덕션 전환" 명시
2. 외부 기관과 test/dev API 계약 체결
3. 실 HSM 조달 완료
4. 보안 감사·규제 심사 일정 확정
5. 성능·정확도 SLA 요구 (99.5% 이상 · p99 30s 이하)
6. 사용자 수 확대 (> 100 명)
7. DR 훈련 요구

---

## 참고 문서

- 정본 스펙: `docs/superpowers/specs/2026-04-18-ocr-solution-design.md`
- 현 범위 정책: `~/.claude/projects/-Users-jimmy--Workspace/memory/project_scope_v2_basic_flow.md`
- POLICY-NI-01: `~/.claude/projects/-Users-jimmy--Workspace/memory/feedback_not_implemented_policy.md`
- POLICY-EXT-01: `~/.claude/projects/-Users-jimmy--Workspace/memory/feedback_external_integration_dummy_only.md`
- Phase 1 구현 계획 (완료된 것): `docs/superpowers/plans/*.md`
- 통합 Integration Hub 가이드 (작성 예정): `docs/ops/integration-real-impl-guide.md`
