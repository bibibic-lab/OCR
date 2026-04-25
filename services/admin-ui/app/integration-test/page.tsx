import { auth } from "@/auth";
import { redirect } from "next/navigation";
import { IntegrationTestPanel } from "./test-form";

/**
 * /integration-test — 외부연계 테스트 페이지 (서버 컴포넌트).
 *
 * POLICY-NI-01 Step 3 — UI 배너:
 *   3 외부 기관 엔드포인트 호출 + 노란 배너 + [Dummy] 프리픽스 표시.
 *
 * 세션 인증 → 미인증 시 로그인 리디렉션.
 * 실제 호출은 /api/integration/[agency] Next.js API route를 통해 수행.
 */
export default async function IntegrationTestPage() {
  const session = await auth();
  if (!session?.accessToken) {
    redirect("/api/auth/signin");
  }

  return (
    <main className="min-h-screen bg-gray-50 dark:bg-gray-900">
      {/* Header */}
      <header className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 shadow-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <a
              href="/"
              className="text-xl font-bold text-gray-900 dark:text-white hover:text-blue-600 dark:hover:text-blue-400"
            >
              OCR Admin
            </a>
            <span className="text-gray-400">/</span>
            <span className="text-xl font-semibold text-gray-700 dark:text-gray-300">
              외부연계 테스트
            </span>
          </div>
          <div className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400">
            <span>{session.user?.email ?? session.user?.name}</span>
          </div>
        </div>
      </header>

      {/* Body */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* 페이지 설명 */}
        <div className="mb-6">
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
            외부 기관 연계 테스트
          </h1>
          <p className="text-gray-600 dark:text-gray-400 text-sm">
            integration-hub의 3 외부 기관 어댑터를 직접 호출합니다.
            현재 모든 어댑터는 더미 응답을 반환합니다 (POLICY-EXT-01).
          </p>
        </div>

        {/* 전역 Not Implemented 배너 */}
        <div className="mb-6 rounded-lg bg-yellow-50 border border-yellow-300 px-4 py-4 dark:bg-yellow-900/20 dark:border-yellow-700">
          <div className="flex items-start gap-3">
            <span className="text-yellow-500 text-xl">⚠️</span>
            <div>
              <p className="font-semibold text-yellow-800 dark:text-yellow-300">
                Not Implemented — 전체 외부연계 더미 모드
              </p>
              <p className="text-sm text-yellow-700 dark:text-yellow-400 mt-1">
                3개 어댑터(행안부·KISA TSA·OCSP) 모두 실 API 계약 대기 중입니다.
                모든 응답은 결정론적 더미값이며, 실제 기관 데이터와 무관합니다.
              </p>
              <a
                href="https://github.com/bibibic-lab/OCR/blob/main/docs/ops/integration-real-impl-guide.md"
                target="_blank"
                rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-sm text-yellow-700 dark:text-yellow-300 underline hover:no-underline"
              >
                실 구현 가이드 보기 (GitHub) →
              </a>
            </div>
          </div>
        </div>

        {/* 테스트 패널 (클라이언트 컴포넌트) */}
        <IntegrationTestPanel />
      </div>
    </main>
  );
}
