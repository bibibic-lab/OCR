# Stage B-1 Walking Skeleton — Upload API + Storage + Result

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 인증된 사용자가 파일을 업로드하면 SeaweedFS S3에 원본이 저장되고, PG에 메타가 기록되고, OCR 결과가 API로 조회 가능한 최소 수직 슬라이스를 구현한다.

**Architecture:** dmz ns에 Spring Boot Kotlin 기반 `upload-api` (OIDC 인증, multipart 수신, 비동기 OCR 트리거) 배포. 메타는 `pg-main`의 `dmz` DB에 저장, 원본 바이트는 `seaweedfs-s3` 에 저장. OCR 결과는 동기 호출로 `ocr-worker.processing.svc` 를 호출해 반환값을 PG에 저장. B-1 범위는 **사전암호화/압축/Kafka/토큰화 제외** — 이것들은 Phase 1 carry-over.

**Tech Stack:** Spring Boot 3.2 (Kotlin 1.9) · Spring Security OAuth2 Resource Server · AWS SDK v2 (S3) · jOOQ (PG) · Flyway · Gradle Kotlin DSL · BuildKit multi-stage Docker · Keycloak `ocr` realm (기존) · SeaweedFS S3 (기존) · CloudNativePG `pg-main` (기존).

**Walking Skeleton 경계 (명시적 YAGNI):**
- 사전암호화/DEK/KEK 경로 — **제외** (Phase 1)
- Kafka `upload-topic` 비동기 파이프라인 — **제외** (동기 호출로 시작)
- AV 스캔 sandbox — **제외**
- FPE 토큰화 — **제외**
- mTLS · HMAC 요청 서명 — **제외** (Ingress TLS만)
- Merkle root · manifest — **제외** (SHA-256 파일 해시만)
- 프로덕션 급 압축 — **제외**

---

### Task B1-T1: dmz DB 스키마 + Flyway 마이그레이션 V1

**Files:**
- Create: `services/upload-api/src/main/resources/db/migration/V1__init.sql` (Spring Boot Flyway 표준 classpath)
- Create: `infra/manifests/upload-api/dmz-db-bootstrap.yaml` (pg-main 내 `dmz` database + user + grants Job — 스키마 생성은 Flyway가 앱 기동 시 수행, Job은 DB/role만)
- Test: `tests/smoke/upload_api_db_smoke.sh`

- [ ] **Step 1: SQL 스키마**

```sql
CREATE TABLE IF NOT EXISTS document (
  id              UUID PRIMARY KEY,
  owner_sub       TEXT NOT NULL,                       -- Keycloak sub
  filename        TEXT NOT NULL,
  content_type    TEXT NOT NULL,
  byte_size       BIGINT NOT NULL,
  sha256_hex      TEXT NOT NULL,
  s3_bucket       TEXT NOT NULL,
  s3_key          TEXT NOT NULL,
  status          TEXT NOT NULL CHECK (status IN ('UPLOADED','OCR_RUNNING','OCR_DONE','OCR_FAILED')),
  uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ocr_finished_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS ocr_result (
  document_id     UUID PRIMARY KEY REFERENCES document(id) ON DELETE CASCADE,
  engine          TEXT NOT NULL,
  langs           TEXT NOT NULL,
  items_json      JSONB NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_document_owner ON document(owner_sub, uploaded_at DESC);
```

- [ ] **Step 2: dmz DB + user 생성 Job**

Job uses `kubectl exec pg-main-1 -- psql` pattern (CloudNativePG cluster). Create `dmz_app` role with random password, store as Secret `dmz/upload-api-db-creds` (keys: `username`, `password`, `jdbc-url`).

- [ ] **Step 3: Apply + smoke**

```bash
kubectl apply -f infra/manifests/upload-api/dmz-db-bootstrap.yaml
kubectl -n dmz wait --for=condition=complete job/dmz-db-bootstrap --timeout=120s
kubectl -n dmz get secret upload-api-db-creds -o jsonpath='{.data.jdbc-url}' | base64 -d
```

- [ ] **Step 4: Commit**

```bash
git add services/upload-api/db infra/manifests/upload-api tests/smoke/upload_api_db_smoke.sh
git commit -m "feat(b1/T1): dmz DB (document/ocr_result) + Flyway V1 + creds Secret"
```

---

### Task B1-T2: Upload API Spring Boot Kotlin scaffold + Keycloak OIDC

**Files:**
- Create: `services/upload-api/build.gradle.kts`, `settings.gradle.kts`, `gradle.properties`
- Create: `services/upload-api/src/main/kotlin/kr/ocr/upload/UploadApiApplication.kt`
- Create: `services/upload-api/src/main/kotlin/kr/ocr/upload/SecurityConfig.kt`
- Create: `services/upload-api/src/main/resources/application.yml`
- Create: `services/upload-api/src/test/kotlin/kr/ocr/upload/SecurityConfigTest.kt`

- [ ] **Step 1: Gradle 설정 (Spring Boot 3.2.5 · Kotlin 1.9.23 · JVM 21)**

Dependencies: `spring-boot-starter-web`, `spring-boot-starter-security`, `spring-boot-starter-oauth2-resource-server`, `spring-boot-starter-actuator`, `jackson-module-kotlin`, `kotlin-reflect`, `software.amazon.awssdk:s3:2.25.x`, `org.postgresql:postgresql`, `org.jooq:jooq:3.19.x`, `org.flywaydb:flyway-core`, `org.flywaydb:flyway-database-postgresql`.

- [ ] **Step 2: SecurityConfig — `ocr` realm JWT 검증**

`spring.security.oauth2.resourceserver.jwt.issuer-uri: https://keycloak.admin.svc.cluster.local/realms/ocr` (실제 배포: Keycloak은 admin ns, HTTPS only). `/actuator/health/**` 공개, 그 외 전부 인증. TLS 인증서는 `ocr-internal` ClusterIssuer 체인(T5에서 컨테이너 truststore에 CA 주입).

- [ ] **Step 3: 테스트 — unauthenticated 요청이 401, actuator는 200**

- [ ] **Step 4: Gradle 빌드 통과 확인**

```bash
cd services/upload-api && ./gradlew test bootJar
```

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(b1/T2): upload-api scaffold + Keycloak JWT resource server"
```

---

### Task B1-T3: POST /documents (multipart) → SeaweedFS S3 + PG insert

**Files:**
- Create: `services/upload-api/src/main/kotlin/kr/ocr/upload/DocumentController.kt`
- Create: `services/upload-api/src/main/kotlin/kr/ocr/upload/DocumentService.kt`
- Create: `services/upload-api/src/main/kotlin/kr/ocr/upload/S3Config.kt`
- Create: `services/upload-api/src/main/kotlin/kr/ocr/upload/Repositories.kt`
- Create: `services/upload-api/src/test/kotlin/kr/ocr/upload/DocumentControllerTest.kt`

- [ ] **Step 1: S3 클라이언트 (SeaweedFS S3 endpoint `http://seaweedfs-s3.processing.svc.cluster.local:8333`, path-style=true, region=us-east-1, 자격은 Secret `upload-api-s3-creds`)**

- [ ] **Step 2: POST `/documents` — multipart `file`, max 50MB, content-type allowlist (`image/png`, `image/jpeg`, `application/pdf`), 스트리밍으로 S3 put + SHA-256 동시 계산**

- [ ] **Step 3: 업로드 성공 시 document row INSERT, status=UPLOADED, 응답 201 `{id, status}`**

- [ ] **Step 4: Integration test — Testcontainers(PG + LocalStack S3) + mock JWT, 파일 업로드 → 201 + DB row 존재 검증**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(b1/T3): POST /documents — S3 put + PG insert + SHA-256"
```

---

### Task B1-T4: 동기 OCR 트리거 + GET /documents/{id}

**Files:**
- Modify: `services/upload-api/src/main/kotlin/kr/ocr/upload/DocumentService.kt`
- Create: `services/upload-api/src/main/kotlin/kr/ocr/upload/OcrClient.kt` (WebClient → `http://ocr-worker.processing.svc.cluster.local/ocr`)
- Modify: `services/upload-api/src/main/kotlin/kr/ocr/upload/DocumentController.kt` — add `GET /documents/{id}` returning status + (if DONE) items
- Create: `services/upload-api/src/test/kotlin/kr/ocr/upload/OcrFlowTest.kt`

- [ ] **Step 1: OcrClient — multipart body로 S3 object bytes 재전송 (B-1은 동기·단순). 타임아웃 60s.**

- [ ] **Step 2: DocumentService.triggerOcr — POST 이후 비동기 @Async 로 OCR 호출 → ocr_result insert + document.status 업데이트**

- [ ] **Step 3: GET `/documents/{id}` — 본인 소유 문서만(owner_sub 비교), status + (DONE 시) items**

- [ ] **Step 4: 통합 테스트 — 업로드 후 폴링(최대 30s)하여 DONE + items 존재**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(b1/T4): async OCR trigger + GET /documents/{id}"
```

---

### Task B1-T5: Docker image + k8s manifest (dmz ns) + NetworkPolicy

**Files:**
- Create: `services/upload-api/Dockerfile` (multi-stage: gradle build + eclipse-temurin:21-jre base)
- Create: `infra/manifests/upload-api/deployment.yaml`
- Create: `infra/manifests/upload-api/service.yaml`
- Create: `infra/manifests/upload-api/network-policies.yaml`
- Create: `infra/manifests/upload-api/ingress.yaml` (Ingress `upload.ocr.local` 또는 `upload-api.dmz.svc` port-forward 테스트 경로)

- [ ] **Step 1: Dockerfile (non-root UID 1000, distroless 대신 temurin slim, JVM flags: `-XX:MaxRAMPercentage=75 -Xss512k`)**

- [ ] **Step 2: Deployment — env에서 DB/S3/OIDC 정보 주입 (Secret+ConfigMap), resources 250m-1 / 512Mi-1.5Gi, probes `/actuator/health/liveness`·`/actuator/health/readiness`**

- [ ] **Step 3: NetworkPolicy — default-deny, allow egress to: pg-main.security (PG 5432), seaweedfs-s3.processing (8333), ocr-worker.processing (80), keycloak.security (80). allow ingress from ingress-nginx.**

- [ ] **Step 4: kind load docker-image → kubectl apply → pod Ready**

- [ ] **Step 5: curl smoke — Keycloak에서 token 발급 → POST /documents (sample-id-korean.png) → GET /documents/{id} 폴링 → DONE + 5 items 확인**

- [ ] **Step 6: Commit + tag**

```bash
git commit -m "feat(b1/T5): upload-api container + dmz deployment + zero-trust NP"
git tag -a b1-walking-skeleton -m "B-1: end-to-end upload→OCR→result via REST"
```

---

## 누락 요주의 (다음 Stage 후보)

- B-2: 10장 Ground-truth 정확도 harness (`tests/accuracy/`)
- B-3: Next.js admin UI (업로드 + 결과 오버레이)
- B-1+: Kafka 비동기 전환, AV 스캔, 사전암호화 복원 (각각 독립 plan)
