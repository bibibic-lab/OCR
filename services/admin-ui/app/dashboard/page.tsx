import { auth } from "@/auth";
import { redirect } from "next/navigation";
import { getStats } from "@/lib/api";
import { StatsCards } from "./stats-cards";

/**
 * /dashboard — 관리 대시보드 페이지 (서버 컴포넌트).
 *
 * - 세션 검증 → 미인증 시 로그인 리디렉션
 * - GET /documents/stats SSR
 * - POLICY-NI-01: Not Implemented 섹션 반드시 포함
 */
export default async function DashboardPage() {
  const session = await auth();
  if (!session?.accessToken) {
    redirect("/api/auth/signin");
  }

  let stats = null;
  let fetchError: string | null = null;

  try {
    stats = await getStats(session.accessToken);
  } catch (e) {
    fetchError = e instanceof Error ? e.message : "통계 조회 실패";
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
              관리 대시보드
            </span>
          </div>
          <div className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400">
            <span>{session.user?.email ?? session.user?.name}</span>
          </div>
        </div>
      </header>

      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8 space-y-8">
        {fetchError ? (
          <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-xl p-6">
            <p className="text-red-700 dark:text-red-400">
              통계를 불러오지 못했습니다: {fetchError}
            </p>
          </div>
        ) : stats ? (
          <StatsCards stats={stats} />
        ) : null}
      </div>
    </main>
  );
}
