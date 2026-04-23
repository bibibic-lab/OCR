# Stage B3 Admin UI — 구현 계획 및 진행 기록

- 작성일: 2026-04-22
- 담당: Claude Sonnet 4.6 (B3-T1), 이후 태스크 순차 진행
- 관련 스펙: `docs/superpowers/specs/2026-04-18-ocr-solution-design.md`

---

## 목표

OCR 플랫폼의 관리자·검토자용 웹 UI 구축. Keycloak `ocr` realm OIDC 인증 기반.

---

## 태스크 분해

| Task | 상태 | 내용 |
|------|------|------|
| B3-T1 | **완료** (2026-04-22) | Next.js 스캐폴드 + Keycloak OIDC |
| B3-T2 | pending | 업로드 페이지 + upload-api 연동 |
| B3-T3 | pending | OCR 결과 조회 + bbox 오버레이 |
| B3-T4 | pending | Docker 이미지 + admin namespace 배포 + smoke |

---

## B3-T1: Next.js 스캐폴드 + Keycloak OIDC

### 완료 일시
2026-04-22

### 커밋
`a79af8b` — `feat(b3/T1): admin-ui Next.js scaffold + Keycloak OIDC auth`

### 생성 파일

| 파일 | 역할 |
|------|------|
| `services/admin-ui/package.json` | Next.js 14.2.29, next-auth 5.0.0-beta.25, Tailwind 3.4.x |
| `services/admin-ui/tsconfig.json` | TypeScript 5.x, bundler module resolution |
| `services/admin-ui/next.config.mjs` | 이미지 도메인 허용 (Keycloak) |
| `services/admin-ui/tailwind.config.ts` | content 경로 설정 |
| `services/admin-ui/postcss.config.mjs` | Tailwind + autoprefixer |
| `services/admin-ui/.gitignore` | node_modules, .next, .env 제외 |
| `services/admin-ui/.eslintrc.json` | next/core-web-vitals + next/typescript |
| `services/admin-ui/.env.example` | 환경 변수 예시 (시크릿 미포함) |
| `services/admin-ui/auth.ts` | NextAuth v5 설정, Keycloak provider, JWT/session callback |
| `services/admin-ui/auth.config.ts` | Edge-safe 라우트 보호 규칙 |
| `services/admin-ui/middleware.ts` | NextAuth middleware, route matcher |
| `services/admin-ui/app/api/auth/[...nextauth]/route.ts` | NextAuth App Router handler |
| `services/admin-ui/app/layout.tsx` | Root layout + SessionProvider |
| `services/admin-ui/app/page.tsx` | Home — 서버 컴포넌트, 세션 상태 표시 |
| `services/admin-ui/app/globals.css` | Tailwind base |
| `services/admin-ui/components/auth-buttons.tsx` | 클라이언트 컴포넌트, signIn/signOut |
| `services/admin-ui/README.md` | 로컬 개발 가이드 |
| `infra/manifests/keycloak/realm-ocr.json` | `ocr-backoffice` 클라이언트에 localhost:3000 redirect URI 추가 |

### 기술 결정 및 트레이드오프

#### 클라이언트 선택: `ocr-backoffice` (public 아님, secret 필요)

- realm-ocr.json에 `ocr-backoffice` (confidential, PKCE enabled)와 `ocr-api` (bearerOnly)만 존재
- `admin-cli`는 realm-ocr.json에 정의되지 않아 사용 불가
- `ocr-backoffice` 채택, `__BACKOFFICE_CLIENT_SECRET__` 플레이스홀더를 실제 시크릿으로 교체 필요
- 개발 편의를 위해 redirect URI에 `http://localhost:3000/*` 추가 (realm-ocr.json 수정)

#### NextAuth v5 JWT 타입 처리

- NextAuth v5 beta에서 `next-auth/jwt` 모듈 보강이 지원되지 않음
- jwt/session 콜백에서 `any` 타입 캐스팅 사용 (eslint-disable 주석 포함)
- Why: next-auth 5 stable 출시 시 제거 예정. B3-T4에서 재검토.

#### TLS: `NODE_TLS_REJECT_UNAUTHORIZED=0`

- ocr-internal 자체서명 CA로 Keycloak TLS 발급됨
- NextAuth가 토큰 교환 시 Keycloak OIDC endpoint에 직접 HTTP 요청 → TLS 검증 실패
- 개발용 임시 비활성화 채택
- 운영(B3-T4): `NODE_EXTRA_CA_CERTS=/certs/ocr-internal-ca.crt` + ConfigMap 마운트로 해결

#### Node.js 버전 불일치

- 권장: Node 20 LTS
- 실제 환경: v25.8.2
- 빌드·실행 정상 동작 확인. CI/Docker는 node:20-alpine 사용 예정 (B3-T4).

### 빌드 결과

```
npm run build  →  ✓ 성공
npm run lint   →  ✓ No ESLint warnings or errors

Route (app)
├ ƒ /                         588 B   /  91.5 kB
├ ○ /_not-found               875 B  /   88 kB
└ ƒ /api/auth/[...nextauth]     0 B  /    0 B
ƒ Middleware  76.6 kB
```

### 보안 취약점 (npm audit)

- `next@14.2.29`: 보안 취약점 경고 (2025-12-11 패치 권고)
- B3-T4에서 Next.js 14.2 최신 패치 버전으로 업그레이드 검토
- 현재 스코프에서는 내부망 전용 관리 UI이므로 위험도 낮음

### 개발 실행 방법

```bash
# 1. Keycloak port-forward (새 터미널)
kubectl -n admin port-forward svc/keycloak 8443:443

# 2. 환경 변수 설정
cd services/admin-ui
cp .env.example .env.local
# KEYCLOAK_CLIENT_SECRET, AUTH_SECRET 입력

# 3. 개발 서버
npm run dev
# → http://localhost:3000
```

### T2 이월 사항

| 항목 | 내용 |
|------|------|
| `KEYCLOAK_CLIENT_SECRET` 실제 값 | Keycloak 콘솔에서 `ocr-backoffice` 시크릿 확인 필요 |
| Next.js 버전 패치 | 14.2.x 보안 취약점 최신 패치 버전 확인 |
| refresh token 처리 | 현재 만료 시 `TokenExpired` 에러만 표시 — 자동 갱신은 B3-T4 |
| `output: standalone` 활성화 | next.config.mjs에 주석으로 준비됨 — B3-T4에서 활성화 |

---

## B3-T2: 업로드 페이지 + API 호출

(미시작 — 상세 계획은 태스크 착수 시 추가)

## B3-T3: 결과 페이지 + bbox 오버레이

(미시작 — 상세 계획은 태스크 착수 시 추가)

## B3-T4: Docker + admin namespace 배포 + smoke

(미시작 — 상세 계획은 태스크 착수 시 추가)
