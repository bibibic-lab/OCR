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
| B3-T2 | **완료** (2026-04-22) | 업로드 페이지 + upload-api 연동 |
| B3-T3 | **완료** (2026-04-22) | OCR 결과 조회 + bbox 오버레이 |
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

### 완료 일시
2026-04-22

### 커밋
`493536a` — `feat(b3/T2): upload page + API client + status polling`

### 생성 파일

| 파일 | 역할 |
|------|------|
| `services/admin-ui/app/upload/page.tsx` | 업로드 페이지 서버 컴포넌트 |
| `services/admin-ui/app/upload/upload-form.tsx` | 클라이언트 컴포넌트, 파일 선택·업로드·폴링 |
| `services/admin-ui/lib/api.ts` | upload-api fetch 클라이언트 (uploadDocument / getDocument / pollDocument) |

---

## B3-T3: 결과 페이지 + bbox 오버레이

### 완료 일시
2026-04-22

### 커밋
`7109ef2` — `feat(b3/T3): document result viewer + bbox SVG overlay`

### 생성·수정 파일

| 파일 | 역할 | 신규/수정 |
|------|------|-----------|
| `services/admin-ui/app/documents/[id]/page.tsx` | SSR 서버 컴포넌트 — 인증 체크 + getDocument + 상태별 렌더링 | 수정(전체 재작성) |
| `services/admin-ui/app/documents/[id]/bbox-viewer.tsx` | 클라이언트 컴포넌트 — SVG bbox 오버레이 + 접근성 테이블 | 신규 |
| `services/admin-ui/components/status-badge.tsx` | 공통 상태 뱃지 컴포넌트 | 신규 |
| `services/admin-ui/lib/bbox.ts` | bbox 좌표 유틸 (bboxToPointsStr / confidenceColor / bboxRect) | 신규 |
| `services/admin-ui/app/upload/upload-form.tsx` | 업로드 후 sessionStorage에 data URL + 크기 저장 추가 | 수정 |

### 아키텍처 결정

#### 원본 이미지 전달 방법: sessionStorage (Option 1)
- 선택 이유: 순수 프론트엔드, 백엔드 코드 변경 없음, T3 스코프에 적합
- 제약: 동일 브라우저 세션 내에서만 동작 (크로스-세션 조회 시 "원본 이미지 없음" 표시)
- 대안(T4 이후): upload-api에 `GET /documents/{id}/original` 엔드포인트 추가 → S3 presigned URL 또는 스트리밍

#### SVG 오버레이 방식
- Canvas 대신 SVG 선택 → hover/click 이벤트, 접근성(aria), 스타일링 용이
- bbox polygon 클릭 시 항목 선택 + 상세 패널 표시
- confidence 색상: green-500 (≥0.9) / yellow-500 (≥0.5) / red-500 (<0.5)
- 신뢰도 <0.5인 항목은 bbox 위에 `!` 경고 텍스트 표시

#### SessionStorage 키 규칙
- `doc:{id}:original` — data URL (string)
- `doc:{id}:dim` — `{width}x{height}` (string)

### 빌드 결과

```
npm run build  →  ✓ 성공
npm run lint   →  ✓ No ESLint warnings or errors

Route (app)
├ ƒ /documents/[id]    2.33 kB / 89.5 kB
├ ƒ /upload            3.07 kB / 94.1 kB
```

### T4 이월 사항

| 항목 | 내용 |
|------|------|
| 원본 이미지 영속성 | 현재 sessionStorage → T4에서 upload-api GET /original 엔드포인트 추가 검토 |
| OCR_RUNNING 자동 갱신 | 현재 "새로고침 안내" 메시지만 → T4에서 AutoRefresh 클라이언트 컴포넌트 (router.refresh() 2초 폴링) 추가 검토 |
| next.config.mjs `output: standalone` | B3-T4에서 Docker 빌드 시 활성화 |

---

## B3-T4: Docker + admin namespace 배포 + smoke

(미시작 — 상세 계획은 태스크 착수 시 추가)
