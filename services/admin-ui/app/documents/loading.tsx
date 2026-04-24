/**
 * /documents 경로 Suspense 스켈레톤.
 * Next.js App Router — loading.tsx 자동 Suspense 경계.
 */
export default function DocumentsLoading() {
  return (
    <main className="min-h-screen bg-gray-50 dark:bg-gray-900">
      <header className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 shadow-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div className="h-6 w-32 bg-gray-200 dark:bg-gray-700 rounded animate-pulse" />
        </div>
      </header>

      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8 space-y-4">
        {/* 필터 바 스켈레톤 */}
        <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-4">
          <div className="flex gap-3">
            <div className="h-9 w-56 bg-gray-200 dark:bg-gray-700 rounded-lg animate-pulse" />
            <div className="h-9 w-32 bg-gray-200 dark:bg-gray-700 rounded-lg animate-pulse" />
            <div className="h-9 w-40 bg-gray-200 dark:bg-gray-700 rounded-lg animate-pulse" />
          </div>
        </div>

        {/* 테이블 스켈레톤 */}
        <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 overflow-hidden">
          <div className="divide-y divide-gray-100 dark:divide-gray-700">
            {Array.from({ length: 5 }).map((_, i) => (
              <div key={i} className="px-4 py-4 flex gap-4">
                <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded animate-pulse flex-1" />
                <div className="h-4 w-24 bg-gray-200 dark:bg-gray-700 rounded animate-pulse" />
                <div className="h-4 w-16 bg-gray-200 dark:bg-gray-700 rounded animate-pulse" />
                <div className="h-4 w-32 bg-gray-200 dark:bg-gray-700 rounded animate-pulse" />
              </div>
            ))}
          </div>
        </div>
      </div>
    </main>
  );
}
