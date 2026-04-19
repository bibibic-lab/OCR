# OCR 솔루션 설계서

- **작성일**: 2026-04-18
- **상태**: 초안 (브레인스토밍 승인 완료, 구현계획 대기)
- **스코프**: 통합 플랫폼 아키텍처 설계. 개별 서브시스템의 상세 구현계획은 별도 스펙으로 분리 예정.

---

## 0. 개요

### 0.1 프로젝트 목표

상업용 OCR 엔진(CLOVA·삼성SDS·카카오 등)에 견줄 인식률을 가진 문서 처리 플랫폼을 **오픈소스 중심**으로 구축한다. 단순 OCR 엔진이 아니라 **업로드–문자인식–인증(내·외부 연계)–자료관리–물리파일관리** 전체를 통합하는 엔터프라이즈 솔루션을 지향한다.

### 0.2 요구사항 네 축

1. **인식률** — 다국어(한·영·일·중), 정형(신분증·여권) + 반정형(계약서·송장) 혼합 대응. 상업용 수준.
2. **연계 처리** — 외부망(인터넷) 사용자 업로드 ↔ 내부망 처리서버 간 I/F·API·연결관리. 외부기관(행안부·NICE·KISA TSA 등) 인증 연계.
3. **보안** — 업로드 이후 전송·보관 전 과정에서 **압축+암호화**. 단순 암호화 이상 — 다중 레이어 방어.
4. **백오피스** — 업로드·문자인식·인증·자료관리·물리파일 통합관리. 사용자/권한 관리 포함.

### 0.3 스택 선정 요약 (후보 A)

| 레이어 | 선택 | 라이선스 |
|---|---|---|
| OCR 엔진 | PaddleOCR PP-OCRv4 + PP-Structure + SLANet | Apache 2.0 |
| 정형 KIE | Donut | MIT |
| 반정형 KIE | LiLT + Donut | MIT |
| 필기체 | TrOCR | MIT |
| 추론 서버 | Triton Inference Server | BSD-3 |
| 모델 레지스트리 | MLflow | Apache 2.0 |
| HITL | Label Studio Community | Apache 2.0 |
| API Gateway | Spring Cloud Gateway | Apache 2.0 |
| 워크플로 | Camunda 7 Community | Apache 2.0 |
| 통합(외부연계) | Apache Camel + Bouncy Castle | Apache 2.0 / MIT-style |
| SSO | Keycloak | Apache 2.0 |
| 권한 정책 | OPA (Open Policy Agent) | Apache 2.0 |
| 메시징 | Apache Kafka + MirrorMaker 2 | Apache 2.0 |
| 객체 스토리지 | **SeaweedFS** | Apache 2.0 |
| KMS | **OpenBao** | MPL 2.0 |
| DB | PostgreSQL | PostgreSQL License |
| 검색/로그 | OpenSearch | Apache 2.0 |
| 관측 | Prometheus + Grafana (unmodified) | Apache 2.0 + AGPL-3 (unmodified OK) |
| 편집기 | Collabora Online (MPL 2.0 소스 빌드 또는 상용 구독) | MPL 2.0 |
| AV | ClamAV (독립 프로세스 호출) | GPL-2 (분리 시 비전염) |
| PDF | pdf2image + pdfplumber + pikepdf | MIT |
| 암호 | age, libsodium, Zstandard | BSD-3 / ISC / BSD-3 |

라이선스 감사 결과 상세는 §8 참조.

---

## 1. 아키텍처 — 존 구성과 문서 유통

### 1.1 존 분리

세 개의 보안 존으로 분리한다.

- **외부망(DMZ)**: 사용자 브라우저·모바일 접점. 업로드 API, NGINX Ingress, DMZ 객체스토리지(임시), Egress presigned 엔드포인트만 상주.
- **내부망(Processing Zone)**: OCR/KIE 워커, 외부기관 연계 허브, Camunda, PostgreSQL, 영구 아카이브 저장소, OpenBao. 원본 DEK·KEK가 여기에만 존재.
- **관리망(Admin Zone)**: 백오피스, Keycloak, 모니터링·감사 로그. 관리자 VPN/Zero-Trust 통한 접근만 허용. 처리망과 별도로 분리돼 관리자 계정 탈취 시 처리망 직접 접근 불가.

### 1.2 문서 유통 방식 — 하이브리드 (통제된 양방향)

"단방향 복제만"으로는 **과거 업로드 문서를 사용자에게 제공하여 수정 후 재제출**하는 플로우를 처리할 수 없다. 다음 하이브리드를 채택한다.

- **기본(웹 에디터 경로)** — 조회·수정은 내부망 Collabora Online 세션을 외부망 사용자가 리버스 프록시로 접근. 원본 파일은 내부망을 떠나지 않고 브라우저에는 렌더링만 전달된다. DLP 관점에서 기본 경로.
- **보완(반출 패키지 경로)** — 오프라인 서명·전자문서 원본 교환이 필요한 경우에만 Egress Gateway를 경유한다. 승인 → 압축+암호화 패키징 → 워터마킹 → DMZ Egress 버킷 → presigned URL, 키/비번은 OOB 전달, TTL·다운로드 횟수 제한.
- **재제출** — 기존 업로드 경로를 재사용. 메타에 `original_doc_id` / `parent_revision_id`를 기록해 버전 체인을 축적.

### 1.3 방향별 단방향 채널

"양방향"이 아니라 **두 개의 통제된 단방향**으로 구성한다.

- `upload-kafka` (외→내): 업로드·재업로드
- `egress-kafka` (내→외): 승인된 반출 패키지만
- 두 채널 모두 MirrorMaker 2로 단방향 복제, 서로 응답 채널이 없다. 방화벽은 각 방향에 대해 출발지·목적지·포트를 엄격히 제한한다.

### 1.4 존 간 통신 보안

- 모든 서비스 간 통신은 **mTLS + 요청 HMAC 서명**.
- Phase 1은 Keycloak OIDC + mTLS 기본 레벨. **SPIFFE/SPIRE**, 추가 MFA 강화, Zero-Trust 서비스 메시 전면 적용은 Phase 2 로드맵.

### 1.5 이중 저장

- **DMZ SeaweedFS (Staging)**: TTL ≤ 1h, 스캔·이관 완료 시 즉시 파기.
- **내부 아카이브**: 영구 보관, 별도 Storage-KEK로 재암호화된 상태로 저장.
- 두 저장소는 서로 다른 KEK 계층을 사용해 한 영역 침해가 전체 유출로 번지지 않게 한다.

---

## 2. 압축+암호화 파이프라인 — 6겹 방어

### 2.1 보호 레이어 개요

| # | 레이어 | 적용 지점 | 기술 |
|---|---|---|---|
| L1 | 클라이언트 사전암호화 | 브라우저/모바일 | WebCrypto, 청크별 Zstandard 압축 → AES-256-GCM (DEK) |
| L2 | 봉투 암호화 | 브라우저 | DEK를 서버 RSA-OAEP-256 공개키로 암호화 후 전송 |
| L3 | 전송 암호화 | 외↔DMZ, DMZ↔내부 | TLS 1.3 + mTLS + HMAC-SHA256 요청 서명(nonce 포함) |
| L4 | DMZ 저장 암호화 | DMZ SeaweedFS | 암호화본 그대로 저장 + 스토리지 SSE |
| L5 | 내부 저장 암호화 | 내부 SeaweedFS | 별도 **Storage-KEK**로 재암호화 — DEK/KEK/Storage-KEK 3계층 |
| L6 | 민감필드 토큰화 | OCR 결과 | OpenBao Transform FPE로 주민번호·카드번호 등 치환 |

### 2.2 "단순 암호화 이상"의 의미

키를 여러 영역에 분산하여 한 지점의 침해가 전체 유출로 번지지 않게 한다.

- DMZ는 DEK 봉투를 풀 수 없음(개인키는 내부 OpenBao에만 존재).
- 내부 처리망도 Storage-KEK는 별도(또 한 번의 재암호화).
- 민감필드는 토큰화되어 OCR 결과 DB에 원본이 존재하지 않음.

### 2.3 업로드 파이프라인 (브라우저 → DMZ)

1. 파일 → 청크 분할(8MB) → Zstandard 압축 → DEK(AES-256-GCM) 생성 → 각 청크 암호화(GCM 태그 + 카운터 기반 nonce)
2. 전체 무결성: Merkle root(SHA-256) + 서명
3. DEK → 서버 공개키(RSA-OAEP-256)로 봉투 암호화 → `EncryptedDEK`
4. manifest = `{file_id, chunks[], merkle_root, encrypted_dek, alg_versions}` 생성
5. HTTPS + mTLS + 요청 HMAC 서명으로 DMZ Upload API 전송
6. DMZ Upload API: OIDC 사용자 인증, 요청 서명 검증, manifest 검증
7. 청크는 암호화된 채 DMZ SeaweedFS에 저장. AV 스캔은 격리 sandbox(별도 네임스페이스)에서 일시 복호화 후 즉시 파기
8. Kafka `upload-topic`에 메타·포인터·`EncryptedDEK` 발행

### 2.4 전송·내부 처리·장기 보관

1. DMZ SeaweedFS → Internal SeaweedFS-Staging 복제 (TLS)
2. DMZ Kafka → Internal Kafka (MirrorMaker 2, mTLS)
3. OCR Worker: OpenBao Transit으로 `EncryptedDEK` Unwrap → 메모리에서만 복호화·OCR·KIE → 결과를 새 DEK로 재암호화
4. 민감필드 토큰화 Worker: Transform FPE로 치환
5. Archive Worker: Storage-KEK로 청크 재암호화(3층) → Internal SeaweedFS Archive에 최종 저장. Staging 임시본은 Crypto-shred(DEK 파기)
6. PostgreSQL에는 메타·해시·봉투정보만 저장 (원본 바이트 없음)

### 2.5 키 계층

```
HSM (SoftHSM 개발 / 제조사 HSM 프로덕션)
  └ Root Master Key (3년 로테이션)
       └ OpenBao Transit Engine (auto-unseal)
           ├ Upload-KEK   (1년 로테이션)
           ├ Storage-KEK  (1년)
           └ Egress-KEK   (1년)
                └ 파일별 DEK (AES-256-GCM, 90일 로테이션 — 신규 암호화본에만 적용)
```

- Worker는 k8s ServiceAccount 인증으로 OpenBao에 접근. 최소권한(특정 KEK Unwrap만).
- 모든 키 사용은 OpenBao Audit Log → OpenSearch로 영속화.

### 2.6 Crypto-shredding 파기

파기 요청 시 파일 바이트 삭제 대신 해당 DEK를 OpenBao에서 삭제한다. 암호화본은 남아있어도 복호화 불가. GDPR·PIPA 파기 요구를 수초 내 충족.

### 2.7 민감필드 토큰화 (L6)

- 대상: 주민등록번호, 외국인등록번호, 여권번호, 카드번호, 계좌번호 (확장 가능)
- OpenBao Transform Engine FPE로 형식 보존 토큰 치환 (예: `900101-1******`)
- 원본은 물리/네트워크 분리된 **PII 금고(별도 PostgreSQL 인스턴스)** 에 `PII-KEK`로 암호화 저장
- 백오피스 일반 화면은 토큰만 렌더. 원본 열람은 Step-up MFA + 감사로그 + (정책별) 2인 승인

### 2.8 무결성·감사

- 각 문서: SHA-256 + Merkle root, HMAC-SHA256 서명
- 감사로그: OpenSearch append-only, 매일 해시체인 블록 서명 (tamper-evident) → 월 단위 WORM 아카이브
- 기록 대상: 키 사용, 문서 열람/다운로드/인쇄/반출/파기, 권한 변경, 정책 변경

### 2.9 클라이언트 사전암호화 지원 브라우저

- **지원**: Chrome/Edge ≥ 90, Firefox ≥ 102, Safari ≥ 15 (iOS 15+), Samsung Internet ≥ 14 (스트리밍 사전암호화 완전 동작)
- **제한 모드**: WebCrypto만 가능한 환경 → 30MB 이하 단일 파일 업로드 허용 (서버 `Slim-Upload` 헤더로 감지·검증)
- **차단**: IE 11, Edge Legacy, Android 4.x WebView, iOS 10 이하 → 업그레이드 안내 페이지
- **특수 이슈**: 한국 보안 플러그인(nProtect 등) 환경 주요 고객사 실기기 테스트 필수

---

## 3. OCR 처리 파이프라인

### 3.1 처리 단계

1. **전처리**: PDF 렌더링(300DPI, pdf2image), Orientation 보정(딥러닝 기반), Deskew(Hough/Radon), Perspective correction(모바일 촬영 4점 코너), Denoise/Contrast/Shadow removal(DocUNet 계열), Resolution 정규화
2. **문서 분류**: MobileNetV3 또는 CLIP + SVM → {주민등록증·운전면허·여권·사업자등록증·계약서·영수증·송장·기타} → 특화 파이프라인으로 라우팅
3. **레이아웃 분석**: PP-Structure로 텍스트블록·표·도장·서명·사진 영역 분리, reading order 결정
4. **텍스트 검출+인식**: PaddleOCR PP-OCRv4 (DB++ 검출 + SVTR 인식, 다국어). line-level confidence 포함
5. **KIE 분기**:
   - 정형(신분증·여권·사업자등록증): **Donut** end-to-end 구조화
   - 반정형(계약서·송장·영수증): **LiLT + BIO 태깅**
   - 표(재무제표·명세): PP-Structure **SLANet** → HTML 테이블
6. **후처리·검증**: 체크섬(주민번호·사업자번호·카드 Luhn·계좌), 정규식(날짜·금액·전화), 도메인 사전 교정, 상호 일관성(생년월일 ↔ 주민번호 앞자리, 유효기간 ↔ 현재일)
7. **민감필드 토큰화** (§2.7)
8. **신뢰도 라우팅**: 전필드 ≥ 임계치 → 자동 승인; 일부 낮음 → HITL 검토 큐; 다수 실패/위조 의심 → 관리자 알림
9. **결과 영구화**: PostgreSQL(메타) + Internal SeaweedFS Archive(본문)

### 3.2 엔진 앙상블 전략

| 단계 | 1차 | 2차/검증 | 비고 |
|---|---|---|---|
| 레이아웃 | PP-Structure | — | 영역 분리 |
| 검출+인식 | PP-OCRv4 | — | 다국어 범용 |
| 정형문서 | Donut (파인튜닝) | PP-OCRv4 교차 | 신분증·여권 |
| 반정형 KIE | LiLT (파인튜닝) | 규칙엔진 | 계약서·송장 |
| 중요 필드 | PP-OCRv4 | + Donut | **투표/일치 검증** — 불일치 시 HITL |
| 표 | SLANet | — | HTML/CSV 변환 |
| 필기체 | TrOCR (한국어 파인튜닝) | — | 서명란·메모란 |

"틀리면 안 되는 필드"(주민번호·금액 등)는 복수 경로 결과를 비교한다. 단일 엔진 대비 필드 정확도 5~15%p 상승(업계 경험치).

### 3.3 상업용 수준 도달 전략

| # | 전략 | 기대 효과 |
|---|---|---|
| 1 | 도메인 파인튜닝 (Donut/LiLT를 실제 문서 1~5만장으로 재학습) | 정형 필드 95%+ → 98%+ |
| 2 | Synthetic data 증강 (TextRecognitionDataGenerator) | 희귀 패턴 robustness |
| 3 | Active Learning 루프 (HITL 교정 → 주간 재학습) | 운영 6개월 후 누적 개선 |
| 4 | 도메인 Lexicon 주입 (기업명·주소·약관) | 한국어 고유명사 인식 |
| 5 | 이미지 품질 게이트 (업로드 시 해상도·블러·조명 점수) | Garbage-in 차단 |
| 6 | 앙상블 투표 | 오인식 필터 |

**정형 문서는 상업용 동등, 반정형은 90~95% 구간(상업용 대비 약간 열위)** 을 현실적 목표로 설정한다. 최종 1~2%p는 자체 학습 데이터 축적량이 결정한다.

### 3.4 HITL 플랫폼

- Label Studio (Apache 2.0) 내부망 배치
- OCR 결과를 이미지 위에 오버레이 렌더, 검토자가 인라인 수정
- 수정 이력은 PostgreSQL + SeaweedFS에 원천 저장 → 주간 배치로 파인튜닝 데이터셋 자동 편입
- 검토 큐는 Camunda BPMN 태스크로 연결(담당자 배정·SLA·승인)

### 3.5 추론 인프라

- K8s GPU 노드(NVIDIA Device Plugin)
- **Triton Inference Server**(BSD-3) — Dynamic Batching으로 동시 요청 효율화
- Worker는 gRPC로 Triton 호출
- CPU-only 폴백: PP-OCRv4는 CPU 동작 가능(처리량 1/10) → 에어갭·저사양 환경용 `cpu-worker` 분리
- 모델 버전 관리: **MLflow Model Registry**(파인튜닝 버전·성능지표·프로덕션 승격)

### 3.6 거버넌스

- 재학습 데이터는 민감필드 마스킹 후 또는 토큰 원본으로만 포함
- 모델 버전 A/B 테스트: 신규 모델은 트래픽 10%로 시작, 주요 필드 정확도 비교 후 승격
- 모델 파일 SHA-256 + 서명, Triton 로딩 시 검증

---

## 4. 외부기관 연계 · 인증

### 4.1 연계 대상 · 프로토콜

| 용도 | 기관 예시 | 프로토콜 |
|---|---|---|
| 신분증 진위확인 | 행안부 주민등록 진위, NICE 신분증스캔 | REST, SOAP |
| 운전면허 진위 | 경찰청 | SOAP |
| 외국인등록 진위 | 법무부 | SOAP |
| 사업자등록 진위 | 국세청 홈택스 | REST |
| 본인확인(간편인증) | PASS, 카카오, 네이버, 토스 | OAuth 2.0 + 서명 |
| 계좌실명확인 | 금융결제원 오픈뱅킹 | REST |
| 신용조회 | NICE, KCB | 전용 API(mTLS) |
| 전자서명 | 자체(공인인증서) + 모두싸인·글로사인 | PKCS#11, REST |
| 타임스탬프 | KISA TSA, 한국전자인증 | RFC 3161 (TSP) |
| 인증서 검증 | OCSP / CRL | OCSP, HTTP |

### 4.2 Integration Hub

- Spring + **Apache Camel** 기반. 프로토콜 어댑터(`camel-http`, `camel-cxf`, `camel-jetty`, OAuth, TSP)로 차이를 흡수하고 내부에는 표준 DTO(`IDVerifyRequest`, `SignRequest`, `TSARequest`)만 흐르게 한다.
- **Resilience4j**: Bulkhead per 기관, Circuit Breaker(5xx 5회/30s open), 지수 백오프 재시도, 타임아웃
- **Egress Proxy (Squid/Envoy)**: 외부기관 FQDN/IP 화이트리스트, TLS 재암호화·검증, 요청/응답 전수 감사로그
- 외부기관 호출은 **반드시 Integration Hub → Egress Proxy 단일 경로**. 워커가 직접 인터넷으로 나가지 않음.
- 비밀 관리: API 키·PKCS#12/PKCS#11을 OpenBao에 저장, 호출 직전 Unwrap, 디스크 상주 금지

### 4.3 대표 플로우

**(A) 신분증 진위확인**
1. OCR/KIE 결과(성명·주민번호·발급일·사진) → Camunda Task `verifyIdCard`
2. Integration Hub: 행안부 진위확인 API 호출
3. 사진 ↔ OCR 얼굴영역 교차 검증(InsightFace 등)
4. 위변조 검사(MRZ 체크섬, 보안요소 변조 탐지)
5. 결과 DTO → BPMN 분기(자동 승인 / HITL / 관리자 알림)

**(B) 본인확인(간편인증)**
1. 사용자 브라우저 → PASS/카카오/네이버 간편인증 위젯(OAuth 2.0)
2. DMZ Upload API ← redirect (code + signed token)
3. Integration Hub 토큰 교환 → CI/DI 획득
4. OpenBao에 봉투 암호화 저장, 세션에 CI 바인딩
5. 신분증 OCR 결과 ↔ CI 기반 실명 대조. 불일치 시 재확인

**(C) 계약서 전자서명 + LTV**
1. Camunda Task `signContract` (서명자, 타임라인)
2. [자체 서명 경로] 원문 SHA-256 → PKCS#11 서명(Bouncy Castle, CAdES/PAdES) → KISA TSA 타임스탬프(RFC 3161) → 서명+체인+CRL/OCSP+TST를 담은 **PAdES-LTV** 패키지 → SeaweedFS Archive
   - 원문이 내부에만 상주, 외부 유출 없음
3. [외부 서명 서비스 경로] Egress Gateway로 암호화 반출 → 외부 당사자 서명 수집 → 서명된 PDF + 감사로그 수신 → 내부 아카이브, 반출 원본은 Crypto-shred

### 4.4 보안·탄력성

- 아웃바운드 통제: Egress Proxy FQDN 화이트리스트, TLS 재암호화/검증
- 비밀 관리: OpenBao dynamic secrets — API 키 TTL·자동 로테이션
- 장애 격리: Bulkhead per 기관, Circuit Breaker
- 응답 검증: X.509 체인 + OCSP 실시간, HMAC 서명 요구(기관 지원 시)
- 재전송 방지: nonce + timestamp, 외부 응답 캐시 TTL
- PII 최소전송: 필요 필드만 (예: 주민번호 앞자리 + 성명, 뒷자리 원칙적 미전송)
- 감사 로그: 요청/응답 원문(민감필드는 토큰) + 서명 증거 → OpenSearch append-only

### 4.5 증빙 보관

외부기관 응답(진위결과·CI/DI·TST·OCSP 응답)은 법적 증빙이다. 원본 그대로 서명·타임스탬프 적용 후 Archive 저장하고, 문서 메타 `verification_artifacts[]`로 증빙 ID 연결. 감사 시 "누가 언제 어떤 증빙으로 승인했는가"를 한 번에 재현.

### 4.6 Phase 구분

| Phase | 연계 범위 |
|---|---|
| 1 (MVP) | 행안부 신분증 진위, 사업자등록 진위, KISA TSA, 자체 PAdES-LTV |
| 2 | 간편인증(PASS/카카오/네이버), 금결원 계좌실명, 운전면허 진위 |
| 3 | 신용조회(NICE/KCB), 외부 전자서명 서비스 |

각 Phase 확장은 Integration Hub에 어댑터 추가로 처리한다 — 핵심 아키텍처는 불변.

---

## 5. 백오피스 · 사용자/권한 · 물리파일

### 5.1 백오피스 모듈

- **① 대시보드**: 업로드/처리/인증 실시간 지표
- **② 문서 조회·관리**: 검색·필터·열람·버전·재제출 이력
- **③ HITL 검토 큐**: Label Studio 임베드, SLA·담당자 배정
- **④ 인증 결과 관리**: 외부기관 응답·증빙·재인증
- **⑤ 반출 승인**: Egress 요청 승인 워크플로
- **⑥ 민감정보 열람**: Step-up MFA 후 일시 복호화
- **⑦ 사용자·권한**: 조직·역할·권한·LDAP 동기화
- **⑧ 정책 관리**: 보존기간·파기·알림·SLA
- **⑨ 물리파일**: 종이 원본·매체·캐비닛·폐기
- **⑩ 감사 로그**: 전 행위 기록·검색·무결성 검증
- **⑪ 시스템 관제**: Grafana/Prometheus/OpenSearch 임베드
- **⑫ 모델 운영**: OCR 모델 버전·A/B·성능지표 (MLflow)

각 모듈은 단일 화면 단위로 구성, 공통 레이아웃·검색·필터 컴포넌트 공유. 접근은 RBAC 롤 + 조직 스코프로 제한.

### 5.2 사용자·권한 모델

**IdP**: Keycloak (OIDC + SAML + LDAP/AD 연동)

**조직 계층**: Organization → Department → User

**Role (최소권한, SoD 적용)**

| Role | 권한 | 접근 범위 |
|---|---|---|
| Submitter | 업로드, 자기 문서 조회·수정 재제출 | 본인 업로드본 |
| Reviewer (HITL) | 검토 큐 처리, OCR 결과 교정 | 배정 건만 |
| Approver | 인증·반출 승인 | 담당 부서 |
| Operator | 파이프라인 모니터링, 재처리 | 메타만 |
| Auditor | 감사로그·증빙 조회 (읽기전용) | 전체 메타 + 감사 |
| PII Viewer | 민감필드 원본 열람 (Step-up) | 부여 범위 |
| System Admin | 사용자·정책·인프라 | 문서 본문 접근 불가 |
| Security Admin | 키·감사·권한 | 문서 본문 접근 불가 |

**SoD 원칙**: System Admin ≠ Security Admin, 어떤 Role도 "시스템관리 + 문서열람"을 동시 보유하지 않음.

**ABAC (OPA 중앙집중)**: `document.classification ≥ user.dataClearance`, `document.organization = user.organization OR role=Auditor`, 민감 문서 유형 × 업무 배정 매칭 등.

**인증 강도 단계**

| 작업 | 인증 요구 |
|---|---|
| 일반 로그인 | OIDC (ID + PW + OTP) |
| 민감필드 원본 열람 | Step-up MFA (FIDO2/WebAuthn or 인증앱 OTP) |
| 반출 승인·정책 변경 | Step-up + 2인 승인 (4-eye) |
| 키 로테이션·감사삭제 시도 | HSM 연결 + Security Admin 2인 승인 |

### 5.3 물리파일 관리

**(i) 종이 원본**

- 접수 시 바코드/QR 라벨 자동 생성, 디지털 레코드와 1:1 매핑
- 위치: 캐비닛 → 선반 → 박스 → 페이지 4단 계층. 즉시 조회 가능
- 반출입/반납/폐기 전 행위 로그

**(ii) 외부 저장매체**

- 반출 요청 → 2인 승인 → 매체 ID 발급 + 암호화 컨테이너(VeraCrypt/LUKS) 생성 → 반출 로그
- 반입 매체는 격리 존 검역(ClamAV + 격리 VM) 후에만 처리망 진입
- 매체 키는 OpenBao에 봉투, 분실·도난 시 Crypto-shred

**(iii) 오프라인 계약서**

- 전자서명 디지털본(LTV) + 수기서명 스캔본 + 종이 원본을 한 문서 ID로 연결
- 법적 증빙 요청 시 3자 조합 자동 패키징

**보존기간 · 파기**

| 유형 | 전자본 | 종이 원본 | 파기 |
|---|---|---|---|
| 신분증 사본 | 업무완료 + 30일 | 즉시 또는 개별 | Crypto-shred + 파쇄 증명 |
| 일반 계약서 | 10년 (상법) | 10년 | Crypto-shred + 소각 증명 |
| 금융 계약 | 5년 후 재검토 | 5년 | 전용 파쇄업체 |
| 영수증·송장 | 5년 (세법) | 5년 | 파쇄 |

자동 만료 배치: 매일 자정 Camunda가 만료 건을 파기 큐로 이동 → 관리자 최종 승인 → Crypto-shred(디지털) + 물리 파기 요청서 생성.

개인정보 파기 요청(GDPR·PIPA): 사용자 요청 시 30일 이내 처리(법정 기한). 법적 보관 의무가 있는 경우 사유 기록 후 보류.

### 5.4 감사·모니터링

**감사 로그** — 대상: 로그인, 열람, 다운로드, 인쇄, 수정, 반출, 파기, 권한 변경, 정책 변경, 키 사용. 저장: OpenSearch append-only + 일일 해시체인 블록 → 월 단위 WORM 아카이브. 검색 UI: 사용자·문서·기간·행위유형. 무결성 검증 도구 제공.

**시스템 관측** — Prometheus + Grafana(unmodified) + OpenSearch + Alertmanager. 처리량·지연·정확도·큐 랙·스토리지 용량, HITL 큐 적체, 외부기관 API 장애 알림. MLflow 지표로 모델 드리프트 모니터링.

### 5.5 백오피스 기술 구성

| 영역 | 선택 |
|---|---|
| 프론트엔드 | Next.js + React + TypeScript, Admin Zone 내부망 서빙 |
| UI 라이브러리 | shadcn/ui + Tailwind (MIT) 또는 Ant Design (MIT) |
| 백엔드 | Spring Boot + Spring Security + Spring Data JPA |
| 검색·필터 | OpenSearch 연동 |
| 워크플로 임베드 | Camunda Cockpit / Tasklist |
| HITL 임베드 | Label Studio iframe + SSO 토큰 |
| 대시보드 임베드 | Grafana iframe (anonymous 금지, Keycloak SSO) |
| 정책 엔진 | OPA 사이드카 |
| 리포트 | Apache Superset (선택) |

---

## 6. 보안 모델 요약

1. **3존 분리 + 통제된 양방향 단방향**: DMZ ↔ Processing ↔ Admin. 각 경계는 단방향 Kafka + 방화벽.
2. **6겹 암호화 + 3계층 KEK**: Client-side → Envelope → TLS → DMZ-SSE → Storage-KEK → PII-FPE.
3. **키 분리**: Upload-KEK, Storage-KEK, Egress-KEK, PII-KEK. 한 키 유출이 전체 유출로 전이되지 않음.
4. **Crypto-shredding 파기**: 키 삭제만으로 복호화 불가.
5. **PII 토큰화**: 기본 표시는 토큰. 원본 열람은 Step-up + 감사 + 승인.
6. **SoD**: System/Security/Business/Audit 네 영역 분리. 어떤 Role도 키·로그·본문을 동시 접근 못함.
7. **감사 무결성**: append-only + 해시체인 + WORM 아카이브.
8. **외부 호출 단일 경로**: Integration Hub → Egress Proxy. FQDN 화이트리스트.

---

## 7. 배포·운영 Phase

### Phase 1 (MVP, 4~6개월 기준 권장)

- 인프라: 단일 K8s 클러스터(존별 네임스페이스 + NetworkPolicy), CPU 기반 OCR Worker, 개발용 SoftHSM
- OCR: PP-OCRv4 기본 모델 + Donut 1차 파인튜닝(초기 샘플 수천장)
- 외부연계: 행안부 신분증 진위, 사업자등록, KISA TSA, 자체 PAdES-LTV 서명
- 백오피스: ①②③⑦⑩⑪ 모듈
- 보안: mTLS + Keycloak OIDC 기본

### Phase 2 (3~4개월)

- GPU 노드 추가, Triton 도입, LiLT·TrOCR 파인튜닝
- 간편인증(PASS/카카오/네이버), 계좌실명, 운전면허 진위
- 백오피스 ④⑤⑥⑧⑨⑫
- SPIFFE/SPIRE, 프로덕션 HSM 도입

### Phase 3 (지속 개선)

- 신용조회(NICE/KCB), 외부 전자서명 서비스 연동
- Active Learning 루프 자동화, 모델 A/B 확장
- 고객사별 튜닝 데이터 파이프라인

---

## 8. 라이선스 감사 결과

### 8.1 교체 결정 (상업 배포 리스크 → 대체)

| 원안 | 이슈 | 교체 | 라이선스 |
|---|---|---|---|
| LayoutLMv3 | CC BY-NC-SA 4.0 (비상업) | LiLT + Donut | MIT |
| MinIO | AGPL v3 (2021 전환) — 네트워크 서비스 제공 시 소스공개 의무 | SeaweedFS | Apache 2.0 |
| PyMuPDF | AGPL v3 + Artifex 상용 별매 | pdf2image + pdfplumber + pikepdf | MIT |
| HashiCorp Vault | BSL 1.1 (2023.08~) | OpenBao (Vault fork) | MPL 2.0 |

### 8.2 조건부 유지

| 컴포넌트 | 라이선스 | 조건 |
|---|---|---|
| Grafana | AGPL v3 | unmodified 내부 사용은 의무 없음. 소스 수정·네트워크 제공 시 공개 의무 발생 |
| Collabora Online | MPL 2.0 (소스) + EULA (공식 바이너리) | 소스 직접 빌드 또는 상용 구독. 프로덕션은 상용 구독 권장 |
| ClamAV | GPL v2 | 독립 프로세스 호출만 허용. 정적 링크·라이브러리 바인딩 금지 |
| Zstandard | BSD-3 / GPL dual | BSD-3로 사용 |

### 8.3 클린 — 상업 배포 안전

PaddleOCR(PP-OCRv4, PP-Structure, SLANet), Donut, TrOCR, Triton, MLflow, Label Studio Community, Kafka/MirrorMaker 2, NGINX OSS, Keycloak, Camunda 7 Community, Spring (Boot/Cloud/Security/Integration), Apache Camel, Bouncy Castle, PostgreSQL, OpenSearch, Prometheus, age, libsodium, SoftHSM, SPIFFE/SPIRE, OPA, Resilience4j, shadcn/ui, Ant Design, Next.js/React.

### 8.4 라이선스 거버넌스

- 신규 OSS 도입 시 라이선스·의존성 검토(FOSSology·ScanCode 사용 권장) 후 승인
- 연 1회 전체 의존성 라이선스 재감사
- 상용 구독이 있는 컴포넌트(Collabora Online 등)는 계약 만료 모니터링

---

## §A. 비기능요건·용량계획

### A.1 비즈니스 규모 가정

| 축 | 값 | 산출 근거 |
|---|---|---|
| 일 처리량 (자동 OCR) | **10,000 건/일** | 중견 엔터프라이즈 기준 |
| 업무시간 피크 배율 | 3× (업무시간 8h 기준) | 점심 전후·월말 집중 |
| 피크 TPS | ~1.3 docs/s (평균 0.12) | 10,000 × 3 ÷ (8 × 3600) |
| 파일 평균 크기 | 2MB (PDF+이미지 혼합) | A4 300DPI 컬러 기준 |
| 동시 사용자 | **100명** (백오피스 + Submitter 합산) | |
| 가용성 SLA | **99.9%** (연 다운타임 ≤ 8.76h) | 금융+공공 합집합 |

### A.2 지연(Latency) 목표

| 경로 | p50 | p95 | p99 |
|---|---|---|---|
| 업로드 API 응답 (암호화 청크 수신 ACK) | 200ms | 800ms | 2s |
| OCR 자동 처리 전체 (업로드→KIE→토큰화→아카이브) | 6s | **15s** | **30s** |
| HITL 검토 건 (자동 처리 실패 경로) | — | 비동기 | SLA 4h |
| 백오피스 화면 조회 | 200ms | 500ms | 2s |
| 외부기관 연계 응답 (행안부/NICE) | 1s | 3s | 8s (Circuit Breaker 임계) |
| 문서 검색(OpenSearch) | 300ms | 1s | 3s |

### A.3 스토리지 용량 계획

```
원본 일 증가:        10,000 × 2MB   = 20 GB/일
월/연 원본 증가:     600 GB/월       ≈ 7.2 TB/연
아카이브 + 3복제:   7.2 × 3          = 21.6 TB/연
DMZ Staging(TTL 1h):  최대 5 GB      (순간 부하 대비 여유)
OCR 결과(JSON+이미지 병기): 원본의 30%  → 연 2.2 TB
감사 로그 + WORM:   연 3~5 TB
PII 금고(별도 DB):   수백 GB (메타 위주)

5년 누적 Archive:    ~110 TB (복제·확장 여유 포함)
```

**스토리지 티어링**
- **Hot (≤ 90일)**: SeaweedFS SSD Volume, 즉시 읽기
- **Warm (90일~3년)**: SeaweedFS HDD Volume, 수 초 지연
- **Cold (3년 이상, WORM 아카이브 포함)**: S3 호환 Glacier급 또는 테이프 라이브러리, 분 단위 지연

### A.4 인프라 규모 산정

| 컴포넌트 | 구성 | 근거 |
|---|---|---|
| **OCR GPU Worker** | NVIDIA L4 또는 A10 × **2장** (+DR 1) | PP-OCRv4 단일 GPU 200~500 pages/min, 피크 60/min 대비 여유 5× |
| **CPU OCR Worker (폴백)** | 8core × 2 인스턴스 | 에어갭·GPU 장애 시 용량 1/10 |
| **Triton Inference Server** | GPU 노드 co-located | Dynamic Batching |
| **Kafka 클러스터** | 3 brokers × 2 (DMZ/Internal) | ISR=2, 파티션 12 (upload), 6 (egress) |
| **PostgreSQL (메인)** | Primary + Sync Standby + Async DR, 16vCPU/64GB | 메타·워크플로·사용자. TPS 여유 5× |
| **PostgreSQL (PII 금고)** | 별도 2노드 HA, 8vCPU/32GB | 물리·네트워크 분리 |
| **SeaweedFS** | Master 3 + Volume 6 (rack-aware), Replication=3 | 21.6 TB/연 × 5년 + 여유 |
| **OpenBao** | Integrated Storage(Raft) 3노드 + DR Replication 3노드 | HSM auto-unseal |
| **OpenSearch** | 3 data + 3 master, 핫-웜-콜드 티어 | 로그·검색 |
| **Keycloak** | 2 인스턴스 HA + 공유 DB | 100명 + Step-up MFA |
| **Backoffice (Spring + Next.js)** | 각각 2~3 인스턴스 + L4 LB | 100명, p95 500ms |
| **API Gateway** | 2 인스턴스 HA | mTLS 종단 |
| **Egress Proxy** | 2 인스턴스 HA (Envoy) | FQDN 화이트리스트 |
| **ClamAV** | 격리 존 2 인스턴스 | 업로드 피크 흡수 |

**노드 총 개요**: K8s 워커 노드 약 **14~18대** (Control Plane 3 별도), GPU 노드 2~3, HSM 어플라이언스 2 (주/DR), 네트워크 어플라이언스 별도.

### A.5 용량 헤드룸·확장 정책

- **설계 헤드룸**: 피크 TPS의 **2배**까지 자동 수평확장(HPA)로 흡수
- **임계 알람**: CPU 70%, GPU 80%, 큐 lag > 60s, 스토리지 가용률 < 20%
- **성장 대응**: 일 10만건으로 10× 성장 시 GPU 8장·Kafka 파티션 3×·DB 샤딩 검토 — Phase 3에 재평가 트리거

### A.6 관측 SLI/SLO

| SLI | 정의 | SLO |
|---|---|---|
| 업로드 성공률 | 2xx / 총 요청 | ≥ 99.95% |
| OCR 자동처리 성공률 | 자동승인 / 전체 (HITL 포함) | ≥ 85% |
| p99 OCR 지연 | 업로드→아카이브 | ≤ 30s |
| 외부기관 응답 가용 | 2xx / 전체 | ≥ 99% (기관별) |
| 백오피스 p95 지연 | 주요 화면 | ≤ 500ms |
| 감사로그 무손실 | 기록 성공률 | 100% |

에러버짓: 99.9% 가용성 기준 월 **43분**. 초과 시 신규 기능 배포 동결·안정화 우선.

---

## §B. DR / BCP (재해복구·업무지속계획)

### B.1 목표 등급

| 등급 | 대상 | RTO | RPO |
|---|---|---|---|
| **Tier-1 Critical** | 업로드 API, OCR Worker, OpenBao, 외부기관 연계, Kafka | **2h** | **15분** |
| **Tier-2 Standard** | 백오피스, Camunda, Keycloak, PostgreSQL(메인) | **4h** | **1h** |
| **Tier-3 Deferred** | OpenSearch 분석, 보고서, Grafana | **24h** | **24h** |

금융권 요구(RTO ≤ 4h, RPO ≤ 1h) + 공공기관 요구(등급에 따라 다름)를 충족한다.

### B.2 이중화 구성

**주센터(Primary) ↔ DR센터(Standby) — Active-Standby**

- 양 센터 모두 3존 분리(외/내/관리) 복제 구성
- 네트워크: 전용선 + VPN 백업, 대역폭은 피크 트래픽의 2배

| 컴포넌트 | 주센터 | DR 센터 | 복제 방식 |
|---|---|---|---|
| PostgreSQL (메인) | Primary + Sync Standby | Async Replica + PITR(WAL 아카이브) | 주센터 내 동기, DR은 비동기 |
| PostgreSQL (PII 금고) | Primary + Sync Standby | Async Replica | 동일 |
| Kafka | 3 broker (ISR=2) | 3 broker (MirrorMaker 2) | DR 비동기 복제 |
| SeaweedFS | Replication=3 (rack-aware) | Remote Storage 비동기 복제 | S3 호환 복제 |
| OpenBao | Raft 3노드 | DR Replication 3노드 | Performance/DR Replication |
| Keycloak/Camunda | HA + DB 의존 | DR DB 승격 시 기동 | DB 레플리카 따라감 |
| OpenSearch | 3 data + 3 master | Cross-cluster Replication | CCR 비동기 |
| HSM | 어플라이언스 2대 Active-Standby | DR 사이트 2대 | 키 미러링 (제조사 기능) |

### B.3 백업 정책 (3-2-1-1 규칙)

- **3 복사본**: 원본(주센터) + Sync Standby(주센터) + Async DR(DR센터)
- **2 매체**: SSD/HDD 티어 + 별도 오프라인 백업(테이프 또는 Immutable Object)
- **1 Offsite**: DR센터 복제
- **1 Immutable**: S3 Object Lock 또는 테이프 오프라인 보관 — **Ransomware 대비**

**백업 주기**
- PostgreSQL: WAL 연속 아카이브 + 일일 Full + 시간별 증분
- SeaweedFS: 일일 스냅샷 + WORM Archive는 영구(Object Lock)
- OpenBao: 시간별 Snapshot (Raft), 일일 Seal 백업
- Kafka: Tiered Storage 또는 일일 MirrorMaker2 체크포인트
- 감사 로그: 실시간 → 월 단위 WORM 이관, 영구 보관 (5~10년 법정)

### B.4 운영 절차

**분기별 DR 전환 훈련**
- 주센터 계획 정지 → DR 센터 승격 → 업무 스위치 → 역스위치
- 훈련 결과 리포트 → 보안위원회 보고 → CPO/CISO 서명

**연 1회 전면 재해 시뮬레이션**
- 주센터 전면 소실 가정, DR 단독 운영 24h
- 데이터 정합성·SLA 달성·외부기관 연계 가능 여부 검증

**비상 시 수동 절차**
- Egress Proxy 수동 화이트리스트 스위치
- HSM 복구 시 M-of-N(Shamir 3-of-5) 키 관리자 소집
- 외부기관 대체 경로(수동 승인 대체증빙) 활성화

### B.5 복구 우선순위

1. **P0 (1h 이내)**: Keycloak(로그인), OpenBao(키), Egress Proxy(외부연계)
2. **P1 (2h 이내)**: 업로드 API, Kafka, OCR Worker, PostgreSQL 메인
3. **P2 (4h 이내)**: 백오피스, Camunda, 외부기관 Integration Hub
4. **P3 (24h 이내)**: OpenSearch, Grafana, MLflow

### B.6 Runbook

- 컴포넌트별 장애 시나리오·검진 절차·복구 커맨드·에스컬레이션 경로
- 연 2회 갱신, 신규 인력 온보딩 시 숙지 필수
- ChatOps로 수행 기록(Slack/Teams + Bot), 사후 리뷰 템플릿 표준화

---

## §C. 규제 매핑 (금융+공공 복합)

### C.1 적용 법규·인증

| 구분 | 법규·인증 | 소관 | 적용 사유 |
|---|---|---|---|
| 법률 | 전자금융거래법 | 금융위 | 금융 업무 처리 |
| 법률 | 개인정보보호법 (PIPA) | 개인정보위 | 전 영역 |
| 법률 | 신용정보법 | 금융위 | 금융 고객 정보 |
| 법률 | 정보통신망법 | 방통위 | 인터넷 서비스 |
| 법률 | 전자정부법 | 행안부 | 공공 업무 |
| 법률 | 전자서명법 | 과기정통부 | 전자서명 |
| 고시 | 전자금융감독규정 | 금감원 | 금융 업무 |
| 고시 | 망분리 고시 | 금융위 | 금융 업무 |
| 지침 | 공공기관 개인정보보호 지침 | 개인정보위 | 공공 |
| 지침 | 공공기관 보안관리규정 | 국정원·행안부 | 공공 |
| 인증 | **ISMS-P** | 과기정통부·KISA·개인정보위 | 전 영역 필수 |
| 인증 | **전자금융기반시설 취약점 분석·평가** | 금감원 | 금융 필수 |
| 인증 | **CSAP** (클라우드 사용 시) | 행안부·KISA | 공공 클라우드 |
| 평가 | **개인정보영향평가(PIA)** | 개인정보위 | 공공 의무, 금융 권고 |

### C.2 통제항목 ↔ 설계 요소 매핑 (핵심 발췌)

#### 전자금융감독규정

| 조항 | 요구사항 | 설계 반영 |
|---|---|---|
| §11 접근통제 | 최소권한·계정분리·주기적 재인증 | Keycloak RBAC + OPA ABAC + SoD 4분리 + 분기별 권한 재인증 배치 |
| §14 단말기 보안 | 단말기 인증·통제 | mTLS 클라이언트 인증서, 디바이스 바인딩 옵션 |
| §15 **망분리** | 내부·외부 망 분리, 업무망·인터넷망 분리 | 3존 분리, 두 개 단방향 Kafka, Egress Proxy 화이트리스트 |
| §17 암호화 | 전송·저장 모두 암호화, 주요정보 안전 관리 | 6겹 암호화, mTLS, DB/스토리지 암호화 |
| §18 로그관리 | 접근·변경·이상행위 기록 | append-only 감사로그 + 해시체인 + WORM |
| §19 장애대응 | BCP·DR·복구훈련 | §B RTO/RPO, 분기 전환훈련, 연 재해 시뮬레이션 |
| §23 외부위탁 | 위탁사 보안관리 | 외부기관 Integration Hub 감사, SLA 계약 |
| §31 해킹방지 | 이상행위 모니터링·대응 | WAF, Rate limiting, SIEM 연계 |

#### ISMS-P 주요 통제

| 통제 | 요구사항 | 설계 반영 |
|---|---|---|
| 2.1 정책·조직 | CISO·CPO 지정, 정책 문서화 | 조직 체계 Phase 1 구축 |
| 2.2 인적보안 | 교육·비밀유지 | 연 2회 보안 교육, NDA |
| 2.3 외부자보안 | 외주·위탁 통제 | 계약서 보안 조항, 접근 제한 |
| 2.4 물리보안 | IDC·장비 접근 통제 | DC 티어 III+ 기준, 출입 2인승인 |
| 2.5 인증·권한 | MFA·최소권한 | Keycloak MFA, Step-up, OPA |
| 2.6 접근통제 | 특권 계정 분리 | System/Security Admin 분리 |
| 2.7 암호화 | 키관리·알고리즘 | OpenBao + HSM, AES-256-GCM, RSA-OAEP |
| 2.8 개발보안 | SAST·코드리뷰 | CI에 Semgrep·Trivy, 2인 리뷰 |
| 2.9 시스템·NW 보안 | 방화벽·IPS·NetworkPolicy | K8s NetworkPolicy, Calico/Cilium |
| 2.10 운영관리 | 변경관리·패치 | GitOps, 월간 패치 창 |
| 2.11 사고대응 | IR 계획·훈련 | IR Playbook, 반기 훈련 |
| 2.12 재해복구 | BCP·DR | §B |
| 3.1 개인정보 수집·이용 | 동의·목적 | 동의 UI, 목적 내 이용 |
| 3.2 개인정보 제공·위탁 | 동의·계약 | 외부기관 전송 동의 |
| 3.3 개인정보 파기 | 파기 절차·기록 | Crypto-shred + 파기 증명 |
| 3.4 정보주체 권리 | 열람·정정·삭제 | 백오피스 요청 처리 30일 |
| 3.5 가명·익명 처리 | PII 비식별 | 민감필드 FPE 토큰화 |

#### 개인정보보호법

| 조항 | 요구사항 | 설계 반영 |
|---|---|---|
| §15 수집·이용 | 동의 기반 | 명시적 동의 로그 |
| §21 파기 | 목적 달성 시 지체없이 | 자동 만료 배치 + Crypto-shred |
| §23 민감정보 | 별도 동의·안전조치 | PII 금고 분리, Step-up |
| §24 고유식별정보 | 주민번호 원칙적 처리 제한 | 수집 최소화, 토큰화 필수 |
| §28 안전성 확보 조치 | 암호화·접근통제·접속기록 | 6겹 암호화, 감사로그 |
| §28-2 가명정보 처리 | 결합·재식별 금지 | FPE 토큰 + 별도 키 |
| §29 영향평가 | 일정 규모 이상 의무 | PIA Phase 0 수행 |
| §39 손해배상 | 집단분쟁조정 대비 | 사고 대응·보험 |

#### 신용정보법 (금융권)

| 조항 | 요구사항 | 설계 반영 |
|---|---|---|
| §19 기술적 보호 | 암호화·접근기록 | 6겹 + 감사 |
| §21 이용·제공 | 동의·목적외 금지 | 용도별 권한 |
| §22 신용정보관리보호인 | 책임자 지정 | CPO 겸임 또는 별도 |

#### 망분리 고시 (금융위)

- 업무망/인터넷망 논리적·물리적 분리 — **3존 + Egress Proxy**로 충족
- 자료전송 승인·로깅 — **Egress Gateway 2인 승인 + 감사로그**
- 외부 저장매체 통제 — **§5.3(ii) 매체 관리**

#### CSAP (공공 클라우드 사용 시)

- 국내 데이터센터 의무
- 암호화·접근통제·로그 보관
- **권장:** 네이버클라우드·KT클라우드·카카오엔터프라이즈 CSAP 인증 서비스 활용 or On-prem
- 본 설계는 **On-prem 기본**이므로 CSAP 이슈 최소 (클라우드 채택 시 별도 검토)

### C.3 개인정보영향평가(PIA)

**Phase 0에 수행 필수** (공공 의무·금융 권고).

- 대상: 주민번호·민감정보 포함 시스템
- 수행 기관: 개인정보위 등록 PIA 기관
- 결과물: PIA 보고서 → 개인정보보호위원회 신고(공공)
- 재평가: 중대 변경 시 또는 3년 주기

### C.4 거버넌스 체계

| 직책 | 담당 | 보고 주기 |
|---|---|---|
| **CISO** (정보보호최고책임자) | 보안 정책·사고 대응·감사 대응 | 월간 경영진 |
| **CPO** (개인정보보호책임자) | 개인정보 처리·PIA·민원 | 월간 경영진 |
| 보안관리자 | 일상 운영·패치·로그 | 주간 CISO |
| 개인정보관리자 | 동의·파기·정보주체 권리 | 주간 CPO |
| 정보보호위원회 | 월 1회, 중대사안 수시 | — |

### C.5 감사·인증 타임라인

| 시점 | 작업 |
|---|---|
| Phase 0 (설계·착수) | PIA 수행, 정책·거버넌스 수립 |
| Phase 1 (MVP 배포 전) | 내부 감사, 취약점 스캔 |
| Phase 1 직후 | ISMS-P 예비심사(자체점검) |
| MVP + 3개월 | ISMS-P 본심사 신청 |
| MVP + 6~9개월 | ISMS-P 인증 획득 |
| 연 1회 | 사후 심사 + 전자금융기반시설 취약점 평가 |
| 3년 주기 | ISMS-P 갱신 심사, PIA 재평가 |

---

## §D. 품질·테스트·MLOps

### D.1 정확도 KPI (상업용 근접: 정형 95%+ / 반정형 90%+)

**정형 문서 (신분증·여권·사업자등록증)** — 필드 단위 정확도

| 필드 | 목표 | 측정 |
|---|---|---|
| 주민번호 앞 6자리 | ≥ 99% | 체크섬 통과 |
| 성명(한글) | ≥ 97% | 완전 일치 |
| 생년월일 | ≥ 98% | YYYY-MM-DD 완전 일치 |
| 발급일자 | ≥ 95% | 완전 일치 |
| 주소 (시/도 수준) | ≥ 95% | 정규화 후 일치 |
| 주소 (상세) | ≥ 90% | 정규화 후 일치 |
| **정형 평균** | **≥ 95%** | 가중 평균 |

**반정형 문서 (계약서·송장·영수증)** — 핵심 필드

| 필드 | 목표 | 측정 |
|---|---|---|
| 계약 당사자명 | ≥ 92% | 완전 일치 |
| 계약 금액 | ≥ 95% | 정규식 + 금액 정규화 |
| 계약 일자 | ≥ 92% | 완전 일치 |
| 계약 기간 | ≥ 90% | 시작-종료 쌍 |
| 주소 | ≥ 88% | 정규화 후 유사도 ≥ 0.9 |
| 서명 존재 여부 | ≥ 98% | 이진 분류 |
| **반정형 평균** | **≥ 90%** | 가중 평균 |

**파이프라인 수준 지표**

| 지표 | 목표 |
|---|---|
| 자동처리율 (HITL 없이 승인) | ≥ 85% |
| 오탐율 (잘못 승인) | ≤ 0.5% |
| HITL 검토 SLA | p95 ≤ 4h |
| 재처리율 (재OCR 요청) | ≤ 2% |

### D.2 Ground-truth 데이터셋

| 셋 | 규모 | 용도 | 갱신 |
|---|---|---|---|
| **Benchmark Set** | 1,000장 (정형 500 + 반정형 500) | 전 모델 버전 동일 평가 | 반기 1회 품질 점검 후 교체 |
| **Regression Set** | 500장 (누적) | 신규 이슈 케이스 회귀 | 주간 추가 |
| **Fairness Set** | 300장 (품질·지역·연령 균등) | 편향 검사 | 반기 재샘플링 |
| **Adversarial Set** | 200장 (저화질·왜곡·위변조 의심) | Robustness | 반기 추가 |

- 저작·동의 확보된 샘플만 포함
- 민감필드는 마스킹 또는 토큰 원본, 원본 PII는 별도 금고
- DVC(Data Version Control)로 버저닝 — 모델 버전과 데이터 버전 매칭

### D.3 파인튜닝 전략

**초기 데이터: 실 5,000장 + 합성 증강**

| 단계 | 내용 |
|---|---|
| 1. 실데이터 확보 | 고객사 협약 샘플 + 공공 공개 데이터 5,000장 |
| 2. 라벨링 | Label Studio, 2인 교차 검수, Cohen κ ≥ 0.85 |
| 3. 증강 (Synthetic) | TextRecognitionDataGenerator, 한글 폰트 50종 × 배경 20 × 왜곡 조합 → 3만장 합성 |
| 4. Active Learning | HITL 교정 건 주간 자동 편입, 월간 재학습 |
| 5. 분할 | Train 70 / Valid 15 / Test 15 (Benchmark/Regression은 완전 분리) |

**문서 유형별 전용 모델 분기** — 정형(Donut) / 반정형(LiLT+Donut) / 표(SLANet) / 필기체(TrOCR) 각각 별도 파인튜닝·배포.

### D.4 테스트 피라미드

```
                  [e2e + 카오스 + 펜테스트]   5%
             [통합 + OCR 정확도 회귀]        20%
       [단위 테스트 + API 계약]              75%
```

| 계층 | 도구 | 주기 | 커버리지 |
|---|---|---|---|
| 단위 | JUnit 5 (Java) / pytest (Python) / Vitest (TS) | PR마다 | Line ≥ 80%, Branch ≥ 70% |
| API 계약 | Spring REST Docs / Pact | PR마다 | 전 엔드포인트 |
| 통합 | Testcontainers (Kafka·PG·SeaweedFS·OpenBao) | PR마다 | 핵심 시나리오 |
| OCR 정확도 회귀 | Benchmark Set 자동 평가 | 모델 PR마다 + 일 1회 | KPI 임계치 |
| 부하 | k6 + Kafka Producer | 릴리스 전 + 월 1회 | 피크 2× 30분 |
| 카오스 | Chaos Mesh | 분기 1회 | 핵심 의존 장애 |
| 보안 SAST | Semgrep | PR마다 | High/Critical zero |
| 보안 SCA | Trivy, Grype | PR마다 + 일 1회 | CVE 7일 내 대응 |
| 보안 DAST | OWASP ZAP | 주 1회 + 릴리스 전 | OWASP Top10 |
| 펜테스트 | 외부 업체 | 반기 1회 | 전 경계 |
| E2E | Playwright | 주 1회 | 주요 업무 흐름 |

**릴리스 게이트**: 단위·API계약·통합·정확도 회귀·SAST·SCA 전 통과 + 핵심 KPI 임계치 충족 시만 Staging 승격.

### D.5 MLOps 파이프라인

```
[데이터 수집]                              [이슈 피드백]
 - HITL 교정 이력 (주간 자동)               - 운영 중 오탐 건
 - 실데이터 협약 샘플                       - 고객 VOC
 - 합성 데이터 (TextRecGen)
       ↓
[라벨링] Label Studio
       ↓
[데이터셋 버저닝] DVC + S3/SeaweedFS
       ↓
[학습] MLflow Experiment Tracking
 - 하이퍼파라미터·코드 버전·데이터 버전 기록
       ↓
[자동 평가]  Benchmark + Regression + Fairness + Adversarial
       ↓
[승격 게이트]
 - 전 지표가 현재 프로덕션 대비 악화 없음
 - Fairness Set 편향 < 임계치
 - Adversarial Set 통과율 ≥ 기준
 - 모델 파일 SHA-256 서명
       ↓
[Shadow 배포]  프로덕션 트래픽 10% 병렬 처리, 결과 비교 (1주)
       ↓
[Canary 배포]  5% → 25% → 50% → 100% (각 단계 KPI 확인)
       ↓
[운영 모니터링]
 - 필드별 정확도 추이 (MLflow + Prometheus)
 - 입력 분포 드리프트 (PSI, KL divergence)
 - 드리프트 임계 초과 시 재학습 트리거
```

### D.6 모델 거버넌스

- **모델 카드** (Model Card): 의도된 용도, 훈련 데이터 출처·규모, 성능 지표, 한계·편향, 사용 금지 사례
- **데이터 시트** (Datasheet for Datasets): 수집 방법, 동의 근거, 포함/제외 기준
- **레드팀 테스트**: 분기 1회 adversarial input·프롬프트 인젝션(OCR 결과 주입을 통한 KIE 우회 시도) 검사
- **설명가능성**: OCR 결과의 confidence + bounding box 시각화를 HITL·감사에서 제공
- **모델 라이프사이클**: 프로덕션 모델은 최소 2버전 병행 유지(이전 버전으로 즉시 롤백 가능)

### D.7 운영 SLO + 에러버짓

| SLO | 목표 | 에러버짓 (월) |
|---|---|---|
| 업로드 성공률 | 99.95% | ~22분 |
| OCR 자동처리 성공률 | 85% | — (목표) |
| OCR p99 지연 | ≤ 30s | 0.4h 초과 허용 |
| 백오피스 가용성 | 99.9% | 43분 |
| 감사로그 무손실 | 100% | 0 |

에러버짓 소진 시: 신규 기능 배포 동결, 안정화 우선 작업. 2회 연속 초과 시 경영진 에스컬레이션.

### D.8 품질 문화

- **Definition of Done**: 단위·통합·보안 테스트 통과 + 코드리뷰 2인 + 문서 업데이트 + 정확도 회귀 통과
- **Postmortem**: 모든 주요 사고 72h 내 Blameless Postmortem 작성, 보안위원회 공유
- **주간 품질 회의**: 정확도 추이·HITL 큐·드리프트·오탐 사례 리뷰

---

## 9. 리스크·가정·향후 고려

### 9.1 리스크

- **OCR 인식률 목표 달성**: 파인튜닝용 실데이터 5천장 확보가 결정적. 협약 지연 시 합성데이터 비중 확대로 보완하되 반정형 KPI 타협 가능성.
- **한국 보안 플러그인 환경**: nProtect/AhnLab Safe Transaction이 WebCrypto 동작을 간섭하는 사례 보고. 주요 고객사 실기기 테스트 필요.
- **외부기관 API SLA 및 자격 확보 지연**: 행안부·NICE 등은 사전 심사·협약이 프로젝트 시작 수 개월 전부터 필요. Phase 1 일정의 **Critical Path**.
- **ISMS-P 인증 일정**: 본심사→인증까지 최소 6~9개월. MVP 배포 직후 신청하지 않으면 Phase 2가 지연될 수 있음.
- **DR 인프라 비용**: DR센터 구성 시 하드웨어·라이선스 비용이 주센터의 70~100% 수준 추가. 예산 확보 없으면 DR 등급 타협 불가피.
- **HSM 비용·도입 시기**: 프로덕션은 제조사 HSM 권장. 초기 SoftHSM로 시작하되 Phase 2 금융 연계 전 도입 예산 확보 필요.
- **모델 라이선스 변동**: OSS 모델 라이선스가 변할 수 있음(예: LayoutLMv3의 과거 혼선). 연 1회 재감사.
- **에러버짓 조기 소진**: 99.9% 가용성 기준 월 43분. 외부기관 장애가 전체 SLA로 전이되는 구간 완충 필요.

### 9.2 가정

- 고객사(또는 자체) 내부망에 K8s 운영 역량 존재
- 공공기관 API 접근 자격·협약 Phase 0~1에 확보 가능
- 파인튜닝용 초기 데이터(실 5,000장+) 확보 가능
- 주센터·DR센터 2개소 IDC 확보 또는 동일 IDC 내 물리 분리 존 2개
- PIA 수행 외부 기관 섭외 및 Phase 0 내 완료
- 연 1회 외부 펜테스트·감사 예산 확보

### 9.3 향후 고려 (스코프 밖, 확장 여지)

- **Phase 2 이후**: SPIFFE/SPIRE 서비스 메시 전면 적용, 프로덕션 HSM
- **문서 관리 고도화**: 초기엔 PostgreSQL + SeaweedFS 자체 버전 체인. 규모 확대 시 Alfresco·Nuxeo 등 DMS 도입 검토
- **모바일 네이티브 앱**: WKWebView/WebView 기반 업로드 앱. 디바이스 카메라 품질 게이트 일체화
- **국외 확장**: 다국가 서비스 시 GDPR·각 국가 개인정보법 별도 매핑. Phase 4+.

---

## 10. 용어·참조

### 10.1 약어

| 약어 | 정의 |
|---|---|
| KIE | Key Information Extraction (핵심정보 추출) |
| DEK | Data Encryption Key |
| KEK | Key Encryption Key |
| FPE | Format-Preserving Encryption |
| LTV | Long-Term Validation (전자서명 장기 검증) |
| HITL | Human-in-the-Loop |
| SoD | Segregation of Duties (직무 분리) |
| RBAC | Role-Based Access Control |
| ABAC | Attribute-Based Access Control |
| OPA | Open Policy Agent |
| HSM | Hardware Security Module |
| TSA | Time-Stamp Authority |
| OCSP | Online Certificate Status Protocol |
| CRL | Certificate Revocation List |
| MRZ | Machine-Readable Zone (여권/신분증 기계판독 영역) |
| CI/DI | Connecting Information / Duplicated Information (한국 본인확인) |
| RTO | Recovery Time Objective (복구시간목표) |
| RPO | Recovery Point Objective (복구시점목표) |
| PIA | Privacy Impact Assessment (개인정보영향평가) |
| ISMS-P | 정보보호 및 개인정보보호 관리체계 인증 |
| CSAP | 클라우드보안인증 (Cloud Security Assurance Program) |
| SLI / SLO | Service Level Indicator / Objective |
| DVC | Data Version Control |
| PSI | Population Stability Index (입력 분포 드리프트 지표) |
| SAST / DAST / SCA | 정적·동적·의존성 보안 분석 |
| CPO / CISO | 개인정보보호책임자 / 정보보호최고책임자 |

### 10.2 주요 외부 표준·규정

- TLS 1.3 (RFC 8446)
- AES-GCM (NIST SP 800-38D)
- RSA-OAEP (RFC 8017)
- Argon2id (RFC 9106) — 필요 시 패스워드 유도
- XAdES / CAdES / PAdES 전자서명, PAdES-LTV (ETSI EN 319 142)
- RFC 3161 Time-Stamp Protocol
- OIDC, OAuth 2.0 / 2.1
- WebAuthn / FIDO2
- 개인정보보호법(PIPA) / GDPR / 상법 / 세법 문서 보관 의무

---

## 11. 다음 단계

1. **스펙 리뷰** — 유저 검토 및 수정사항 반영 (§0~11 + §A~D)
2. **Phase 0 선행작업 착수** — PIA 수행, 외부기관 API 자격·협약, IDC·DR 사이트 확정, 보안 거버넌스(CISO/CPO) 구성
3. **구현계획(writing-plans)** — 이 설계를 Phase별 태스크로 분해, 마일스톤·검증 포인트·의존성 수립
4. **세부 서브스펙** — Integration Hub, 백오피스, 암호화 파이프라인, 학습 파이프라인 등 복잡도 높은 영역은 개별 설계서로 분리 가능
5. **인증 로드맵 시작** — MVP 배포 3개월 전 ISMS-P 예비심사, 배포 직후 본심사 신청
