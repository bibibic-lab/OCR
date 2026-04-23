# Playwright OIDC E2E 테스트 운영 가이드

작성일: 2026-04-22
Phase: Phase 1 Medium #5

---

## 목적

admin-ui의 Keycloak OIDC 로그인 → 문서 업로드 → OCR 결과 확인 전체 흐름을
실제 Chromium 브라우저로 자동 검증한다.

기존 curl 기반 smoke 테스트(`admin_ui_e2e_smoke.sh`)는 `/api/health` 응답만 확인하며
CSRF/state 쿠키가 필요한 브라우저 OIDC 플로우를 검증하지 못한다.
이 테스트는 그 공백을 메운다.

---

## 아키텍처 결정 사항

| 항목 | 선택 | 사유 |
|---|---|---|
| 브라우저 엔진 | Chromium 단일 | Phase 1 범위. Firefox·WebKit은 Phase 2 추가 예정 |
| admin-ui 실행 방식 | `npm run dev` (로컬) | 클러스터 배포 admin-ui에 localhost 자체 서명 인증서 전달이 복잡. dev 서버는 `NODE_TLS_REJECT_UNAUTHORIZED=0`으로 Keycloak TLS 우회 가능 |
| Keycloak 접근 | port-forward (localhost:8443) | 브라우저가 보는 issuer URL과 admin-ui가 토큰 검증에 쓰는 issuer URL이 동일해야 NextAuth 콜백이 성공 |
| 테스트 계정 | `submitter1 / submitter1` | `realm-ocr.json`에 정적 추가. 개발·CI 전용. 프로덕션 적용 금지 |
| storageState | Playwright setup 프로젝트 | 로그인을 1회 수행 후 `playwright/.auth/user.json`에 저장. 나머지 테스트는 재사용 |

---

## 전제 조건

- `kubectl`이 `ocr-dev` kind 클러스터에 연결된 상태
- Node.js ≥ 18 (프로젝트에서 v25 확인됨)
- `tests/e2e-ui/` 에서 `npm install` 완료
- `npx playwright install chromium` 완료

---

## 테스트 계정

| 사용자 | 비밀번호 | Realm 역할 |
|---|---|---|
| `submitter1` | `submitter1` | `submitter` |

계정 출처: `infra/manifests/keycloak/realm-ocr.json` (2026-04-22 추가).

> **주의**: 이 계정은 개발·CI 전용이다. Keycloak 어드민 콘솔에서 직접 생성한 경우 동일한 자격증명을 사용하면 된다. 프로덕션 realm에는 절대 추가하지 않는다.

---

## 실행 방법

### 방법 1: 자동화 smoke 스크립트 (권장)

```bash
# 프로젝트 루트에서
./tests/smoke/admin_ui_playwright_smoke.sh
```

스크립트가 수행하는 작업:
1. `npm install` (node_modules 없는 경우)
2. Keycloak port-forward (localhost:8443)
3. upload-api port-forward (localhost:18080)
4. admin-ui dev 서버 기동 (`services/admin-ui/.env.local` 자동 생성)
5. Playwright 테스트 실행
6. 종료 시 port-forward + dev 서버 정리

### 방법 2: 터미널 4개로 수동 실행

**터미널 1 — Keycloak port-forward**
```bash
kubectl -n admin port-forward svc/keycloak 8443:443
```

**터미널 2 — upload-api port-forward**
```bash
kubectl -n dmz port-forward svc/upload-api 18080:80
```

**터미널 3 — admin-ui dev 서버**
```bash
cd services/admin-ui
AUTH_SECRET=$(openssl rand -base64 32)
cat > .env.local <<EOF
KEYCLOAK_CLIENT_ID=ocr-backoffice
KEYCLOAK_CLIENT_SECRET=ocr-backoffice-dev-secret
KEYCLOAK_ISSUER=https://localhost:8443/realms/ocr
AUTH_SECRET=${AUTH_SECRET}
NEXTAUTH_URL=http://localhost:3000
NEXT_PUBLIC_UPLOAD_API_BASE=http://localhost:18080
NODE_TLS_REJECT_UNAUTHORIZED=0
EOF
npm run dev
```

**터미널 4 — Playwright**
```bash
cd tests/e2e-ui
npm install
npx playwright install chromium
npx playwright test
```

### 방법 3: 이미 dev 서버와 port-forward가 실행 중인 경우

```bash
SKIP_PORT_FORWARD=1 SKIP_DEV_SERVER=1 \
  ./tests/smoke/admin_ui_playwright_smoke.sh
```

---

## 환경 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `ADMIN_UI_URL` | `http://localhost:3000` | admin-ui base URL |
| `KC_URL` | `https://localhost:8443` | Keycloak base URL |
| `E2E_USER` | `submitter1` | 테스트 사용자명 |
| `E2E_PASS` | `submitter1` | 테스트 비밀번호 |
| `KEYCLOAK_CLIENT_SECRET` | `ocr-backoffice-dev-secret` | OIDC client secret |
| `SKIP_PORT_FORWARD` | `0` | `1`이면 port-forward 스킵 |
| `SKIP_DEV_SERVER` | `0` | `1`이면 dev 서버 기동 스킵 |
| `PLAYWRIGHT_HEADED` | `0` | `1`이면 브라우저 GUI 표시 |

---

## 테스트 케이스 상세

| ID | 분류 | 설명 | 예상 소요 |
|---|---|---|---|
| TC-AUTH-01 | 인증 | 비인증 홈 접근 → 200 + 로그인 버튼 | <5s |
| TC-AUTH-02 | 인증 | Keycloak 로그인 → 세션 정보 표시 | <30s |
| TC-AUTH-03 | 인증 | 로그아웃 → 로그인 버튼 복귀 | <15s |
| TC-AUTH-04 | 부정 | 잘못된 비밀번호 → Keycloak 오류 | <15s |
| TC-AUTH-05 | 인가 | /upload 미인증 → signin redirect | <10s |
| TC-UPLOAD-01 | 업로드 | /upload 페이지 렌더링 확인 | <5s |
| TC-UPLOAD-02+03 | 업로드+결과 | 이미지 업로드 → OCR_DONE → bbox polygon | <90s (**) |
| TC-UPLOAD-04 | 부정 | 허용되지 않는 MIME → UI 오류 | <5s |

전체 예상 소요 시간: **약 3~5분** (OCR 처리 포함)

> **(\*\*) TC-UPLOAD-02+03 — JWT Issuer 불일치 제약**
>
> port-forward 환경에서 Keycloak 발급 토큰의 issuer는 `https://localhost:8443/realms/ocr` 이나,
> upload-api(in-cluster)가 기대하는 issuer는 `https://keycloak.admin.svc.cluster.local/realms/ocr` 다.
> 불일치 시 upload-api가 401을 반환하고 테스트는 자동으로 SKIP된다.
>
> **해결 방법**: `/etc/hosts`에 `127.0.0.1 keycloak.admin.svc.cluster.local` 추가 후 재실행.
> 또는 CI 환경에서 CoreDNS가 클러스터 내부 DNS를 처리하는 경우 자동 해결된다.

---

## 파일 구조

```
tests/e2e-ui/
├── package.json              # @playwright/test 의존성
├── playwright.config.ts      # base URL, timeout, projects
├── .gitignore                # node_modules, playwright/.auth 제외
├── fixtures/
│   └── test-user.ts          # E2E_USER / E2E_PASS 헬퍼
├── tests/
│   ├── auth.setup.ts         # setup 프로젝트: 로그인 후 storageState 저장
│   ├── auth.spec.ts          # OIDC 인증 플로우 테스트 (5개)
│   └── upload.spec.ts        # 업로드 + 결과 테스트 (3개)
└── playwright/.auth/
    └── user.json             # 세션 상태 (git-ignored)

tests/smoke/
└── admin_ui_playwright_smoke.sh  # 통합 실행 스크립트

tests/images/
└── sample-id-korean.png          # 업로드 테스트 픽스처
```

---

## 알려진 제약 및 이월 항목

| 항목 | 상태 | 설명 |
|---|---|---|
| CI 연동 | Phase 1 이월 | GitHub Actions 워크플로우 미포함. `playwright.yml` 추가 필요 |
| TC-UPLOAD-02+03 issuer 불일치 | Phase 1 이월 | port-forward 환경에서 JWT issuer 불일치로 SKIP됨. `/etc/hosts` 패치 또는 CI 환경에서 해결 |
| storageState 만료 | Phase 2 | Keycloak 토큰 만료(~300s) 시 storageState가 무효화됨. refresh 또는 재로그인 로직 추가 필요 |
| Firefox / WebKit | Phase 2 | Chromium 단일. `playwright.config.ts`에서 projects 배열 확장으로 추가 가능 |
| bbox count 고정 검증 | Phase 2 | TC-UPLOAD-03은 `polygon >= 1` 검증. 정확한 expected count는 OCR 엔진 버전에 따라 달라짐 |
| 프로덕션 Keycloak | 주의 | `submitter1` 계정은 개발 realm-ocr.json에만 존재. 프로덕션 realm에는 별도 계정 정책 적용 |
| Keycloak redirect_uri | 설정됨 | `http://localhost:3000/*`를 Keycloak Admin API로 추가 (2026-04-22). 클러스터 재생성 시 realm-ocr.json import로 자동 반영됨 |
| submitter1 계정 | 설정됨 | Keycloak Admin API로 직접 생성 (2026-04-22). 클러스터 재생성 시 realm-ocr.json import로 자동 반영됨 |

---

## 트러블슈팅

### Keycloak port-forward 실패

```bash
kubectl -n admin get svc keycloak
kubectl -n admin get pod -l app.kubernetes.io/name=keycloak
```

Pod가 Running이 아니면 먼저 Keycloak 배포 상태 확인.

### NextAuth 콜백 실패 (500 또는 redirect loop)

- `KEYCLOAK_ISSUER`가 브라우저가 접근하는 URL과 동일한지 확인.
- `localhost:8443`의 TLS 인증서가 자체 서명인 경우 `NODE_TLS_REJECT_UNAUTHORIZED=0` 필수.
- `.env.local`의 `NEXTAUTH_URL`이 `http://localhost:3000`인지 확인.

### submitter1 로그인 실패

Keycloak이 최초 기동 시 `realm-ocr.json`을 import하지 않은 경우:
```bash
# Keycloak admin CLI로 직접 사용자 추가
kubectl -n admin exec -it deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh create users \
    -r ocr \
    -s username=submitter1 \
    -s enabled=true \
    -s credentials='[{"type":"password","value":"submitter1","temporary":false}]' \
    --server http://localhost:8080 --realm master \
    --user admin --password <admin-password>
```

또는 Keycloak 어드민 UI (`https://localhost:8443/admin/`) 에서 수동 생성.

### Playwright 리포트 열기

```bash
cd tests/e2e-ui
npx playwright show-report
```

### 테스트 개별 실행

```bash
cd tests/e2e-ui

# 인증 테스트만
npx playwright test tests/auth.spec.ts

# 업로드 테스트만
npx playwright test tests/upload.spec.ts

# 헤드 모드 (브라우저 GUI 표시)
npx playwright test --headed

# 디버그 모드
npx playwright test --debug
```

---

## 관련 문서

- `docs/ops/` — 운영 Runbook 모음
- `tests/smoke/admin_ui_e2e_smoke.sh` — curl 기반 인프라 smoke (헬스체크)
- `infra/manifests/keycloak/realm-ocr.json` — Keycloak realm 설정 (테스트 계정 포함)
- `services/admin-ui/auth.config.ts` — NextAuth 라우트 보호 설정
