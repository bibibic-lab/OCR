# B3-T4 구현 기록: admin-ui Docker 컨테이너화 + admin ns 배포 + Smoke

- **날짜**: 2026-04-22
- **태스크**: B3-T4 (Stage B-3 최종 태스크)
- **상태**: 완료

---

## 1. 목표

admin-ui Next.js 앱을 Docker 이미지로 패키징하여 kind(ocr-dev) 클러스터의 `admin` 네임스페이스에 배포하고, curl 기반 smoke test로 자동 검증.

---

## 2. 구현 내역

### 2-1. /api/health 라우트 추가

- **파일**: `services/admin-ui/app/api/health/route.ts`
- **내용**: `{"status":"ok"}` 반환하는 force-dynamic GET 엔드포인트
- **이유**: Kubernetes liveness/readiness probe 전용. `/_not-found`나 `/` 사용 시 인증 리디렉션이 섞여 probe 판정이 불안정함.

### 2-2. auth.config.ts 수정

- **파일**: `services/admin-ui/auth.config.ts`
- **변경**: `publicPaths`에 `/api/health` 추가
- **이유**: 미들웨어가 `/api/health`를 공개 경로로 허용해야 probe가 인증 없이 접근 가능.

### 2-3. next.config.mjs 수정

- **파일**: `services/admin-ui/next.config.mjs`
- **변경**: `output: "standalone"` 주석 해제
- **이유**: Next.js standalone 모드는 `node_modules` 없이 실행 가능한 `server.js`와 최소 의존성만 `.next/standalone/`에 복사. Docker 이미지 크기 최소화.

### 2-4. Dockerfile (multi-stage)

- **파일**: `services/admin-ui/Dockerfile`
- **베이스 이미지**: `node:20-alpine` (builder + runtime)
- **플랫폼**: `linux/amd64` (kind 노드 아키텍처)
- **빌드 단계**:
  1. `builder`: `npm ci` → `npm run build` (standalone 출력)
  2. `runtime`: standalone 결과물만 복사, GID/UID 1001 비루트 사용자
- **비고**: alpine node:20은 GID 1000을 `node` 그룹으로 예약 → 1001 사용
- **최종 이미지 크기**: 224 MB

### 2-5. .dockerignore

- **파일**: `services/admin-ui/.dockerignore`
- **제외 항목**: `node_modules/`, `.next/`, `.env*`, `.git`, `*.md`

### 2-6. k8s 매니페스트 (admin ns)

| 파일 | 내용 |
|------|------|
| `infra/manifests/admin-ui/deployment.yaml` | Deployment, replicas=1, 비루트(1001), liveness/readiness probe `/api/health` |
| `infra/manifests/admin-ui/service.yaml` | ClusterIP, port 80 → targetPort 3000 |
| `infra/manifests/admin-ui/network-policies.yaml` | Egress: DNS/Keycloak(8443)/upload-api(8080). Ingress: observability scraping |

**주요 환경 변수**:
- `AUTH_SECRET` — Secret `admin-ui-env`에서 참조
- `KEYCLOAK_CLIENT_ID=ocr-backoffice`
- `KEYCLOAK_CLIENT_SECRET` — Secret `admin-ui-env`에서 참조
- `KEYCLOAK_ISSUER=https://keycloak.admin.svc.cluster.local/realms/ocr`
- `NEXTAUTH_URL=http://admin-ui.admin.svc.cluster.local`
- `NEXT_PUBLIC_UPLOAD_API_BASE=http://upload-api.dmz.svc.cluster.local`
- `NODE_EXTRA_CA_CERTS=/etc/ssl/ocr-internal/ca.crt` (Keycloak HTTPS 검증용 CA)

**리소스**: requests 250m/512Mi, limits 1CPU/1Gi

### 2-7. upload-api NetworkPolicy 수정

- **파일**: `infra/manifests/upload-api/network-policies.yaml`
- **추가 규칙**: admin ns의 admin-ui pod → upload-api 8080 허용
- **이유**: admin-ui가 Next.js API route를 통해 upload-api에 프록시 요청 전송.

### 2-8. Secret 생성

```bash
# AUTH_SECRET (랜덤 32바이트 base64)
kubectl -n admin create secret generic admin-ui-env \
  --from-literal=AUTH_SECRET="$(openssl rand -base64 32)" \
  --from-literal=KEYCLOAK_CLIENT_SECRET="ocr-backoffice-dev-secret"

# CA cert (dmz ns에서 복사)
kubectl -n dmz get secret ocr-internal-ca -o yaml | \
  python3 -c "..." | kubectl apply -f -
```

### 2-9. Smoke Test

- **파일**: `tests/smoke/admin_ui_e2e_smoke.sh`
- **검증 단계**: 8단계 (빌드 → kind load → Secret → apply → Ready → port-forward → health → home)
- **결과**: 8/8 PASS

---

## 3. 트레이드오프

| 결정 | 이유 |
|------|------|
| `readOnlyRootFilesystem: false` | Next.js standalone은 실행 시 임시 파일 쓰기 필요 |
| GID/UID 1001 | alpine node:20 이미지에서 1000은 node 그룹/유저가 예약 |
| OIDC 플로우 자동화 미구현 | CSRF+state+세션 쿠키 조합으로 curl 자동화 불가 — 수동 체크리스트로 대체 |
| `public/` 디렉토리 COPY 제거 | 이 프로젝트는 public/ 없이 스캐폴드됨. Next.js standalone은 없어도 정상 작동 |

---

## 4. 검증 결과

| 항목 | 결과 |
|------|------|
| Docker 이미지 빌드 | 성공 (224 MB) |
| kind load | 성공 (4개 노드 전체) |
| Pod 기동 | 성공 (Restarts: 0) |
| /api/health | HTTP 200, `{"status":"ok"}` |
| 홈 페이지 | HTTP 200 |

---

## 5. Phase 1 이월 항목

| 항목 | 사유 |
|------|------|
| OIDC 플로우 자동화 | CSRF+state 제약, Playwright/Cypress로 Phase 1에서 구현 |
| Keycloak port-forward 연동 | dev 환경에서 `NEXTAUTH_URL` 재설정 필요. Ingress 구성 후 해소 |
| readOnlyRootFilesystem | emptyDir tmpfs 마운트로 개선 가능 (Phase 1) |
| CiliumNetworkPolicy 세분화 | 현재 NetworkPolicy(k8s 표준)로 충분. Phase 1에서 CiliumNP로 전환 |

---

## 6. 참고

- Next.js Standalone 출력 문서: https://nextjs.org/docs/app/api-reference/next-config-js/output
- NextAuth.js App Router 가이드: https://authjs.dev/reference/nextjs
