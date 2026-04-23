import { auth } from "@/auth";
import { AuthButtons } from "@/components/auth-buttons";

/**
 * Home page — server component.
 * Reads session on the server via auth() — no client round-trip.
 */
export default async function Home() {
  const session = await auth();

  return (
    <main className="min-h-screen bg-gray-50 dark:bg-gray-900">
      {/* Header */}
      <header className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 shadow-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <span className="text-2xl font-bold text-gray-900 dark:text-white">
              OCR Admin
            </span>
            <span className="px-2 py-0.5 text-xs font-medium bg-blue-100 text-blue-800 rounded-full">
              Beta
            </span>
          </div>

          {/* Auth controls */}
          <AuthButtons signedIn={!!session} userEmail={session?.user?.email ?? session?.user?.name ?? undefined} />
        </div>
      </header>

      {/* Body */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        {session ? (
          <div className="space-y-6">
            {/* Session info card */}
            <div className="bg-white dark:bg-gray-800 rounded-xl shadow-sm border border-gray-200 dark:border-gray-700 p-6">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
                세션 정보
              </h2>
              <dl className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div>
                  <dt className="text-sm font-medium text-gray-500 dark:text-gray-400">
                    사용자
                  </dt>
                  <dd className="mt-1 text-sm text-gray-900 dark:text-white font-mono">
                    {session.user?.name ?? "—"}
                  </dd>
                </div>
                <div>
                  <dt className="text-sm font-medium text-gray-500 dark:text-gray-400">
                    이메일
                  </dt>
                  <dd className="mt-1 text-sm text-gray-900 dark:text-white font-mono">
                    {session.user?.email ?? "—"}
                  </dd>
                </div>
                <div>
                  <dt className="text-sm font-medium text-gray-500 dark:text-gray-400">
                    Access Token (앞 40자)
                  </dt>
                  <dd className="mt-1 text-xs text-gray-600 dark:text-gray-300 font-mono break-all">
                    {session.accessToken
                      ? session.accessToken.slice(0, 40) + "…"
                      : "없음"}
                  </dd>
                </div>
                {session.error && (
                  <div className="sm:col-span-2">
                    <dt className="text-sm font-medium text-red-500">오류</dt>
                    <dd className="mt-1 text-sm text-red-700 dark:text-red-400">
                      {session.error}
                    </dd>
                  </div>
                )}
              </dl>
            </div>

            {/* Placeholder nav for future tasks */}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-6 opacity-50 cursor-not-allowed">
                <h3 className="font-semibold text-gray-700 dark:text-gray-300">
                  문서 업로드
                </h3>
                <p className="text-sm text-gray-500 mt-1">B3-T2에서 구현 예정</p>
              </div>
              <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-6 opacity-50 cursor-not-allowed">
                <h3 className="font-semibold text-gray-700 dark:text-gray-300">
                  OCR 결과 조회
                </h3>
                <p className="text-sm text-gray-500 mt-1">B3-T3에서 구현 예정</p>
              </div>
            </div>
          </div>
        ) : (
          <div className="flex flex-col items-center justify-center py-24 space-y-6">
            <div className="text-center">
              <h1 className="text-3xl font-bold text-gray-900 dark:text-white mb-2">
                OCR 문서 처리 관리
              </h1>
              <p className="text-gray-500 dark:text-gray-400">
                계속하려면 Keycloak 계정으로 로그인하세요.
              </p>
            </div>
            <AuthButtons signedIn={false} />
          </div>
        )}
      </div>
    </main>
  );
}
