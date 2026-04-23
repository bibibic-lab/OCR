import { auth } from "@/auth";
import { redirect } from "next/navigation";
import { getDocument } from "@/lib/api";

/**
 * /documents/[id] — OCR 결과 페이지 스텁 (B3-T2).
 *
 * 현재는 API 응답 JSON을 그대로 출력한다.
 * B3-T3에서 bbox 오버레이 + 결과 뷰어로 교체 예정.
 */
export default async function DocumentPage({
  params,
}: {
  params: { id: string };
}) {
  const session = await auth();
  if (!session) {
    redirect("/api/auth/signin");
  }

  const { id } = params;
  let data: unknown;
  let fetchError: string | null = null;

  try {
    data = await getDocument(id, session.accessToken ?? "");
  } catch (err) {
    fetchError =
      err instanceof Error ? err.message : "문서 조회 중 오류가 발생했습니다.";
  }

  return (
    <main className="min-h-screen bg-gray-50 dark:bg-gray-900">
      <header className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 shadow-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4 flex items-center gap-4">
          <a
            href="/upload"
            className="text-sm text-blue-600 dark:text-blue-400 hover:underline"
          >
            ← 업로드
          </a>
          <span className="text-xl font-bold text-gray-900 dark:text-white">
            OCR 결과
          </span>
          <span className="font-mono text-sm text-gray-500 dark:text-gray-400 truncate">
            {id}
          </span>
        </div>
      </header>

      <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        {fetchError ? (
          <div
            role="alert"
            className="rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 p-6"
          >
            <p className="text-sm font-semibold text-red-800 dark:text-red-300 mb-1">
              조회 실패
            </p>
            <p className="text-sm text-red-700 dark:text-red-400">
              {fetchError}
            </p>
          </div>
        ) : (
          <div className="bg-white dark:bg-gray-800 rounded-xl shadow-sm border border-gray-200 dark:border-gray-700 p-6">
            {/* B3-T3에서 뷰어로 교체 예정 */}
            <p className="text-xs text-amber-600 dark:text-amber-400 mb-4 font-medium">
              [B3-T2 스텁] B3-T3에서 bbox 오버레이 + 결과 뷰어로 교체됩니다.
            </p>
            <pre className="text-xs text-gray-800 dark:text-gray-200 overflow-auto whitespace-pre-wrap">
              {JSON.stringify(data, null, 2)}
            </pre>
          </div>
        )}
      </div>
    </main>
  );
}
