import { auth } from "@/auth";
import { redirect } from "next/navigation";
import { getDocument } from "@/lib/api";
import { BboxViewer } from "./bbox-viewer";
import { EditableItems } from "./editable-items";
import { StatusBadge } from "@/components/status-badge";

/**
 * /documents/[id] — OCR 결과 뷰어 (B3-T3).
 *
 * SSR 서버 컴포넌트: 세션 검증 → API 호출 → 결과 렌더링.
 * bbox 오버레이는 클라이언트 컴포넌트(BboxViewer)가 담당.
 */
export default async function DocumentPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const session = await auth();
  if (!session?.accessToken) {
    redirect("/api/auth/signin");
  }

  const { id } = await params;
  const doc = await getDocument(id, session.accessToken).catch((err: unknown) => ({
    error: err instanceof Error ? err.message : "문서 조회 중 오류가 발생했습니다.",
  }));

  return (
    <main className="min-h-screen bg-gray-50 dark:bg-gray-900">
      {/* ── 헤더 ── */}
      <header className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 shadow-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4 flex items-center gap-4">
          <a
            href="/upload"
            className="text-sm text-blue-600 dark:text-blue-400 hover:underline"
          >
            ← 업로드 목록
          </a>
          <span className="text-xl font-bold text-gray-900 dark:text-white">
            OCR 결과
          </span>
        </div>
      </header>

      <div className="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-10">
        {/* ── API 오류 ── */}
        {"error" in doc ? (
          <div
            role="alert"
            className="rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 p-6"
          >
            <p className="text-sm font-semibold text-red-800 dark:text-red-300 mb-1">
              문서 조회 실패
            </p>
            <p className="text-sm text-red-700 dark:text-red-400">{doc.error}</p>
          </div>
        ) : (
          <>
            {/* ── 문서 헤더 ── */}
            <div className="flex items-center gap-3 mb-6">
              <h1 className="text-2xl font-bold text-gray-900 dark:text-white truncate">
                문서{" "}
                <span className="font-mono text-lg text-gray-500 dark:text-gray-400">
                  {doc.id.slice(0, 8)}…
                </span>
              </h1>
              <StatusBadge status={doc.status} />
            </div>

            {/* ── 상태별 본문 ── */}
            {doc.status === "OCR_DONE" && doc.items ? (
              <div className="space-y-8">
                {/* bbox 오버레이 뷰어 (read-only) */}
                <BboxViewer
                  documentId={doc.id}
                  items={doc.items}
                  engine={doc.engine}
                  ocrFinishedAt={doc.ocrFinishedAt}
                />
                {/* 인라인 편집 테이블 */}
                <EditableItems
                  documentId={doc.id}
                  initialItems={doc.items}
                  updatedAt={doc.updatedAt}
                  updateCount={doc.updateCount}
                />
              </div>
            ) : doc.status === "OCR_FAILED" ? (
              <div
                role="alert"
                className="rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 p-6"
              >
                <p className="text-sm font-semibold text-red-800 dark:text-red-300 mb-1">
                  OCR 처리 실패
                </p>
                <p className="text-sm text-red-700 dark:text-red-400">
                  파일을 다시 업로드해 주세요.
                </p>
              </div>
            ) : (
              /* UPLOADED / OCR_RUNNING */
              <div className="rounded-lg bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-700 p-6">
                <div className="flex items-center gap-3 mb-2">
                  <span
                    className="inline-block h-4 w-4 rounded-full border-2 border-blue-500 border-t-transparent animate-spin"
                    aria-hidden="true"
                  />
                  <p className="text-sm font-medium text-blue-800 dark:text-blue-200">
                    OCR 처리 중입니다…
                  </p>
                </div>
                <p className="text-xs text-blue-600 dark:text-blue-400">
                  처리가 완료되면 이 페이지를 새로고침하세요.
                </p>
                <p className="mt-3 font-mono text-xs text-gray-500 dark:text-gray-400">
                  ID: {doc.id}
                </p>
              </div>
            )}
          </>
        )}
      </div>
    </main>
  );
}
