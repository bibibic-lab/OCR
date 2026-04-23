/**
 * auth.spec.ts — OIDC 인증 흐름 E2E 테스트
 *
 * TC-AUTH-01: 공개 홈 — 비인증 접근 시 200 응답 (Next.js가 redirect 포함)
 * TC-AUTH-02: Keycloak 로그인 → admin-ui 세션 생성 확인
 * TC-AUTH-03: 로그아웃 → 세션 종료 확인
 * TC-AUTH-04: 잘못된 비밀번호 → Keycloak 오류 메시지 표시
 * TC-AUTH-05: /upload 페이지 — 미인증 접근 시 signin redirect
 *
 * 전제: auth.setup.ts(setup 프로젝트)가 먼저 실행됨.
 *       TC-AUTH-02 이후는 storageState를 통해 이미 로그인된 상태.
 */
import { test, expect } from "@playwright/test";
import path from "path";
import { TEST_USER, TEST_PASS, AUTH_STATE_PATH } from "../fixtures/test-user";

const authFile = path.resolve(__dirname, "..", AUTH_STATE_PATH);

// ──────────────────────────────────────────────────────────────
// TC-AUTH-01: 공개 홈 페이지 비인증 접근
// ──────────────────────────────────────────────────────────────
test("TC-AUTH-01: 공개 홈 페이지는 비인증 상태에서 접근 가능", async ({
  browser,
}) => {
  // 새 컨텍스트 (storageState 없음 = 비인증)
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await ctx.newPage();

  // 홈 페이지는 Next.js가 렌더링하되 로그인 버튼을 표시
  const resp = await page.goto("/");
  // redirect(30x) 또는 200 모두 허용
  expect(resp?.status()).toBeLessThan(400);

  // "Keycloak 로그인" 버튼이 표시됨 — 비인증 상태 UX 확인
  // 홈 페이지에는 header와 body 두 곳에 버튼이 있으므로 first() 사용
  await expect(
    page.getByRole("button", { name: /Keycloak 로그인|로그인/i }).first()
  ).toBeVisible({ timeout: 10_000 });

  await ctx.close();
});

// ──────────────────────────────────────────────────────────────
// TC-AUTH-02: Keycloak 로그인 후 세션 정보 표시
// ──────────────────────────────────────────────────────────────
test.describe("로그인 상태 테스트", () => {
  test.use({ storageState: authFile });

  test("TC-AUTH-02: 로그인 후 사용자 정보가 홈 페이지에 표시됨", async ({
    page,
  }) => {
    await page.goto("/");

    // 로그아웃 버튼 — 세션 활성 증거
    await expect(
      page.getByRole("button", { name: /로그아웃/ })
    ).toBeVisible({ timeout: 20_000 });

    // 세션 정보 카드에 사용자 이름 또는 이메일 표시
    const sessionCard = page.locator("dl");
    await expect(sessionCard).toBeVisible({ timeout: 10_000 });

    // Access Token 앞 40자 표시됨
    await expect(page.getByText(/Access Token/i)).toBeVisible();
  });

  // ────────────────────────────────────────────────────────────
  // TC-AUTH-03: 로그아웃
  // ────────────────────────────────────────────────────────────
  test("TC-AUTH-03: 로그아웃 후 로그인 버튼이 다시 표시됨", async ({
    page,
  }) => {
    await page.goto("/");
    await page
      .getByRole("button", { name: /로그아웃/ })
      .click();

    // 로그아웃 후 홈 복귀 또는 Keycloak end_session → 홈 redirect
    await page.waitForURL(/localhost:3000/, { timeout: 30_000 });

    // "Keycloak 로그인" 버튼이 다시 나타남 (header + body 두 곳에 있으므로 first() 사용)
    await expect(
      page.getByRole("button", { name: /Keycloak 로그인|로그인/i }).first()
    ).toBeVisible({ timeout: 20_000 });
  });
});

// ──────────────────────────────────────────────────────────────
// TC-AUTH-04: 잘못된 비밀번호
// ──────────────────────────────────────────────────────────────
test("TC-AUTH-04: 잘못된 비밀번호 → Keycloak 오류 메시지", async ({
  browser,
}) => {
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await ctx.newPage();

  await page.goto("/");
  const loginBtn = page
    .getByRole("button", { name: /Keycloak 로그인|로그인/i })
    .first();
  await loginBtn.waitFor({ timeout: 10_000 });
  await loginBtn.click();

  await page.waitForURL(/\/realms\/ocr\/protocol\/openid-connect\/auth/, {
    timeout: 30_000,
  });

  await page.locator('input[name="username"], #username').fill(TEST_USER);
  await page.locator('input[name="password"], #password').fill("WRONG_PASSWORD");
  await page.getByRole("button", { name: /sign in|log in|로그인/i }).click();

  // Keycloak이 오류 메시지를 표시 (invalid credentials)
  // 로그인 페이지에 머뭄 + 오류 span 표시
  await expect(
    page.locator("#input-error, .pf-c-alert__title, [data-testid='error-info']")
      .or(page.getByText(/invalid username or password|잘못된 자격증명|Invalid credentials/i))
  ).toBeVisible({ timeout: 15_000 });

  await ctx.close();
});

// ──────────────────────────────────────────────────────────────
// TC-AUTH-05: /upload 미인증 접근 → signin redirect
// ──────────────────────────────────────────────────────────────
test("TC-AUTH-05: /upload 페이지는 미인증 시 signin 페이지로 redirect됨", async ({
  browser,
}) => {
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await ctx.newPage();

  await page.goto("/upload");

  // NextAuth middleware가 /api/auth/signin 또는 Keycloak으로 redirect
  await page.waitForURL(
    (url) =>
      url.pathname.includes("/api/auth/signin") ||
      url.hostname.includes("localhost") && url.port === "8443" ||
      url.pathname.includes("/realms/"),
    { timeout: 15_000 }
  );

  // 어떤 경로든 로그인 UI가 표시됨
  const isSignInPage =
    page.url().includes("/api/auth/signin") ||
    page.url().includes("/realms/") ||
    page.url().includes("8443");
  expect(isSignInPage).toBeTruthy();

  await ctx.close();
});
