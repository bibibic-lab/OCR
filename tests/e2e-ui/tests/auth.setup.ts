/**
 * auth.setup.ts — 인증 셋업 픽스처
 *
 * Playwright의 "setup" 프로젝트에서 단 한 번 실행된다.
 * 로그인 후 storageState(쿠키 + localStorage)를 파일에 저장한다.
 * 다른 테스트는 이 파일을 재사용하여 반복 로그인을 피한다.
 *
 * storageState 경로: playwright/.auth/user.json
 */
import { test as setup, expect } from "@playwright/test";
import path from "path";
import { TEST_USER, TEST_PASS, AUTH_STATE_PATH } from "../fixtures/test-user";

const authFile = path.resolve(__dirname, "..", AUTH_STATE_PATH);

setup("authenticate — submitter1 Keycloak 로그인", async ({ page }) => {
  console.log(`[auth.setup] 로그인 시도: ${TEST_USER}`);

  // 1. admin-ui 홈 접근 — NextAuth가 /api/auth/signin 으로 redirect
  await page.goto("/");

  // 2. 로그인 버튼 클릭 — "Keycloak 로그인" 버튼 탐색
  //    로그인이 이미 되어 있는 경우 아래 분기로 빠짐
  const signedIn = await page
    .locator("button", { hasText: /로그아웃/ })
    .isVisible({ timeout: 2_000 })
    .catch(() => false);

  if (signedIn) {
    console.log("[auth.setup] 이미 로그인 상태 — storageState 저장");
  } else {
    // NextAuth sign-in 선택 페이지 또는 Keycloak 직행
    const loginBtn = page
      .getByRole("button", { name: /Keycloak 로그인|로그인/i })
      .first();
    await loginBtn.waitFor({ timeout: 10_000 });
    await loginBtn.click();

    // 3. Keycloak 로그인 페이지 대기
    await page.waitForURL(/\/realms\/ocr\/protocol\/openid-connect\/auth/, {
      timeout: 30_000,
    });
    console.log("[auth.setup] Keycloak 로그인 페이지 진입");

    // 4. 자격증명 입력
    //    Keycloak PF5 UI에서 username input은 id="username"
    //    password input은 id="password" (getByLabel은 "Show password" 토글 버튼도 잡으므로 locator 사용)
    await page.locator('input[name="username"], #username').fill(TEST_USER);
    await page.locator('input[name="password"], #password').fill(TEST_PASS);
    await page
      .getByRole("button", { name: /sign in|log in|로그인/i })
      .click();

    // 5. admin-ui 콜백 대기 — NextAuth가 세션 쿠키 설정
    await page.waitForURL(/localhost:3000/, { timeout: 30_000 });
    console.log("[auth.setup] admin-ui 복귀 완료");
  }

  // 6. 로그인 상태 검증
  await expect(
    page.getByRole("button", { name: /로그아웃/ })
  ).toBeVisible({ timeout: 20_000 });

  // 7. storageState 저장
  await page.context().storageState({ path: authFile });
  console.log(`[auth.setup] storageState 저장됨: ${authFile}`);
});
