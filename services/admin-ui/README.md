# OCR Admin UI

Next.js 14 기반 OCR 문서 처리 관리 인터페이스.  
Keycloak `ocr` realm을 통해 OIDC 인증을 수행합니다.

## 스택

| 항목 | 버전 |
|------|------|
| Next.js | 14.2.x (App Router) |
| TypeScript | 5.x |
| Tailwind CSS | 3.4.x |
| NextAuth | v5 beta (next-auth@5.0.0-beta.25) |
| Node.js | 20 LTS 권장 (현재 환경: v25.x — 호환 동작 확인됨) |

## 로컬 개발 설정

### 1. 의존성 설치

```bash
cd services/admin-ui
npm install
```

### 2. 환경 변수 설정

```bash
cp .env.example .env.local
# .env.local 을 편집하여 실제 값을 입력
```

주요 환경 변수:

| 변수 | 설명 | 예시 |
|------|------|------|
| `KEYCLOAK_CLIENT_ID` | Keycloak 클라이언트 ID | `ocr-backoffice` |
| `KEYCLOAK_CLIENT_SECRET` | 클라이언트 시크릿 | `__BACKOFFICE_CLIENT_SECRET__` |
| `KEYCLOAK_ISSUER` | Keycloak Realm URL | `https://localhost:8443/realms/ocr` |
| `AUTH_SECRET` | NextAuth 서명 키 | `openssl rand -base64 32` |
| `NEXTAUTH_URL` | 앱 기본 URL | `http://localhost:3000` |
| `NODE_TLS_REJECT_UNAUTHORIZED` | **개발 전용** TLS 검증 비활성화 | `0` |

> ⚠️ `NODE_TLS_REJECT_UNAUTHORIZED=0` 은 **개발 환경에서만** 사용합니다.  
> 운영 배포(B3-T4)에서는 반드시 제거하고 `NODE_EXTRA_CA_CERTS=/certs/ocr-internal-ca.crt` 로 대체합니다.

### 3. Keycloak Port-Forward (개발용)

클러스터가 실행 중인 경우:

```bash
# 새 터미널에서 실행 (포어그라운드 유지)
kubectl -n admin port-forward svc/keycloak 8443:443
```

접근 확인:
```bash
curl -sk https://localhost:8443/realms/ocr/.well-known/openid-configuration | python3 -m json.tool | head -20
```

### 4. Keycloak 클라이언트 redirect URI 추가

`ocr-backoffice` 클라이언트는 현재 `https://backoffice.ocr.local/*` 만 허용합니다.  
로컬 개발용으로 redirect URI 추가가 필요합니다.

**방법 A — realm-ocr.json 수정 후 재적용 (권장)**:
```json
// infra/manifests/keycloak/realm-ocr.json
"redirectUris": [
  "https://backoffice.ocr.local/*",
  "http://localhost:3000/*"    // 추가
],
"webOrigins": [
  "https://backoffice.ocr.local",
  "http://localhost:3000"      // 추가
]
```

**방법 B — Keycloak Admin Console에서 직접 수정**:
1. `https://localhost:8443` → Admin Console 접속
2. `ocr` realm → Clients → `ocr-backoffice` → Settings
3. Valid redirect URIs에 `http://localhost:3000/*` 추가

### 5. 개발 서버 실행

```bash
npm run dev
# http://localhost:3000 에서 접근
```

### 6. 빌드 테스트

```bash
npm run build
```

### 7. 테스트 사용자

realm-ocr.json 기준:

| 사용자 | 역할 | 비고 |
|--------|------|------|
| `dev-admin` | `system-admin` | 패스워드: Keycloak `keycloak-dev-creds` 시크릿 참고 |

개발 환경 시크릿 확인:
```bash
kubectl -n admin get secret keycloak-dev-creds -o jsonpath='{.data.admin-password}' | base64 -d
```

## 프로젝트 구조

```
services/admin-ui/
├── app/
│   ├── api/auth/[...nextauth]/route.ts  # NextAuth API handler
│   ├── globals.css                       # Tailwind base styles
│   ├── layout.tsx                        # Root layout + SessionProvider
│   └── page.tsx                          # Home page (server component)
├── components/
│   └── auth-buttons.tsx                  # Login/logout (client component)
├── auth.ts                               # NextAuth v5 config + Keycloak provider
├── auth.config.ts                        # Route protection rules (edge-safe)
├── middleware.ts                         # Route guard via NextAuth middleware
├── next.config.mjs
├── tailwind.config.ts
├── tsconfig.json
└── .env.example
```

## 향후 작업 (Roadmap)

| Task | 내용 |
|------|------|
| B3-T2 | 문서 업로드 페이지 + upload-api 연동 |
| B3-T3 | OCR 결과 조회 + bbox 오버레이 |
| B3-T4 | Docker 이미지 + admin namespace 배포 + CA 인증서 마운트 |

## 알려진 제약

- **Node v25 경고**: 공식 권장은 Node 20 LTS이나, v25에서도 빌드·실행 정상 동작 확인.  
  CI/CD 및 Docker 이미지(B3-T4)는 `node:20-alpine` 기반으로 구성.
- **TLS**: 로컬 개발 시 `NODE_TLS_REJECT_UNAUTHORIZED=0` 필요 (ocr-internal 자체서명 CA).  
  운영 배포 시 B3-T4에서 CA 번들 마운트로 해결.
- **토큰 갱신**: 현재 만료된 토큰은 `TokenExpired` 에러를 세션에 표시만 함.  
  자동 refresh는 B3-T4에서 구현.
