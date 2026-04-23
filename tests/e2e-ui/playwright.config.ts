import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright E2E 설정 — OCR admin-ui OIDC 플로우 테스트
 *
 * 실행 전제:
 *   1. kubectl -n admin port-forward svc/keycloak 8443:443
 *   2. kubectl -n dmz  port-forward svc/upload-api 18080:80
 *   3. cd services/admin-ui && npm run dev  (with .env.local configured)
 *
 * 환경 변수:
 *   ADMIN_UI_URL  — admin-ui base URL (기본: http://localhost:3000)
 *   KC_URL        — Keycloak base URL (기본: https://localhost:8443)
 *   E2E_USER      — 테스트 사용자 (기본: submitter1)
 *   E2E_PASS      — 테스트 비밀번호 (기본: submitter1)
 */
export default defineConfig({
  testDir: "./tests",
  timeout: 120_000,
  expect: { timeout: 15_000 },

  /* 단일 워커 — OCR 백엔드 쓰로틀링 고려 */
  fullyParallel: false,
  workers: 1,

  /* 실패 시 재시도 1회 (CI 환경에서만 의미 있음) */
  retries: process.env.CI ? 1 : 0,

  /* 리포터 */
  reporter: [
    ["list"],
    ["html", { outputFolder: "playwright-report", open: "never" }],
  ],

  use: {
    baseURL: process.env.ADMIN_UI_URL ?? "http://localhost:3000",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "off",
    /* Keycloak 자체 서명 인증서 허용 */
    ignoreHTTPSErrors: true,
    /* 브라우저 헤드리스 기본값 */
    headless: true,
  },

  /* Phase 1: Chromium 단일 브라우저 */
  projects: [
    {
      name: "setup",
      testMatch: /auth\.setup\.ts/,
    },
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup"],
    },
  ],
});
