/**
 * 테스트 사용자 자격증명 헬퍼
 *
 * 우선순위:
 *   1. 환경 변수 E2E_USER / E2E_PASS
 *   2. 기본값: submitter1 / submitter1
 *      (realm-ocr.json에 정적으로 추가된 개발 전용 테스트 계정)
 *
 * 주의: 프로덕션 Keycloak에는 이 계정을 생성하지 않는다.
 *       개발·CI 환경에서만 사용.
 */
export const TEST_USER = process.env.E2E_USER ?? "submitter1";
export const TEST_PASS = process.env.E2E_PASS ?? "submitter1";

/** Keycloak base URL (port-forward 기준) */
export const KC_URL = process.env.KC_URL ?? "https://localhost:8443";

/** admin-ui base URL */
export const ADMIN_UI_URL = process.env.ADMIN_UI_URL ?? "http://localhost:3000";

/** storageState 경로 — auth.setup.ts가 저장, 다른 테스트가 읽음 */
export const AUTH_STATE_PATH = "playwright/.auth/user.json";
