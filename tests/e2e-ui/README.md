# OCR Admin-UI Playwright E2E 테스트

## 개요

admin-ui의 OIDC 로그인 + 업로드 + OCR 결과 확인 전체 플로우를 브라우저 자동화로 검증합니다.

## 테스트 케이스

| ID | 설명 | 파일 |
|---|---|---|
| TC-AUTH-01 | 비인증 홈 접근 → 200 응답 + 로그인 버튼 표시 | auth.spec.ts |
| TC-AUTH-02 | Keycloak 로그인 → 세션 정보 표시 | auth.spec.ts |
| TC-AUTH-03 | 로그아웃 → 로그인 버튼 복귀 | auth.spec.ts |
| TC-AUTH-04 | 잘못된 비밀번호 → Keycloak 오류 메시지 | auth.spec.ts |
| TC-AUTH-05 | /upload 미인증 접근 → signin redirect | auth.spec.ts |
| TC-UPLOAD-01 | /upload 페이지 정상 렌더링 | upload.spec.ts |
| TC-UPLOAD-02+03 | 파일 업로드 → OCR_DONE → bbox polygon 렌더링 | upload.spec.ts |
| TC-UPLOAD-04 | 허용되지 않는 MIME → UI 오류 | upload.spec.ts |

## 빠른 시작

자세한 내용은 `docs/ops/playwright-e2e.md` 참조.

```bash
# 1. 의존성 설치
cd tests/e2e-ui && npm install

# 2. Playwright 브라우저 설치
npx playwright install chromium

# 3. smoke 스크립트로 실행 (port-forward 자동 관리)
./tests/smoke/admin_ui_playwright_smoke.sh
```

## 환경 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `ADMIN_UI_URL` | `http://localhost:3000` | admin-ui URL |
| `KC_URL` | `https://localhost:8443` | Keycloak URL |
| `E2E_USER` | `submitter1` | 테스트 사용자 |
| `E2E_PASS` | `submitter1` | 테스트 비밀번호 |

## 파일 구조

```
tests/e2e-ui/
├── package.json
├── playwright.config.ts
├── fixtures/
│   └── test-user.ts       # 테스트 자격증명 헬퍼
├── tests/
│   ├── auth.setup.ts      # 인증 storageState 생성 (setup 프로젝트)
│   ├── auth.spec.ts       # OIDC 로그인/로그아웃 테스트
│   └── upload.spec.ts     # 업로드 → OCR → 결과 테스트
└── playwright/.auth/
    └── user.json          # 세션 상태 (git-ignored)
```
