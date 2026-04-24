import { auth } from "@/auth";
import { redirect } from "next/navigation";
import { listDocuments } from "@/lib/api";
import { DocumentList } from "./document-list";
import type { DocumentStatus } from "@/lib/api";

/**
 * /documents — 문서 목록 페이지 (서버 컴포넌트).
 *
 * - 세션 검증 → 미인증 시 로그인 리디렉션
 * - URL 쿼리스트링 읽어 초기 목록 SSR
 * - 인터랙션(필터·페이지네이션)은 클라이언트 컴포넌트(DocumentList)가 담당
 */
export default async function DocumentsPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string>>;
}) {
  const session = await auth();
  if (!session?.accessToken) {
    redirect("/api/auth/signin");
  }

  const sp = await searchParams;
  const page = parseInt(sp.page ?? "0", 10);
  const size = parseInt(sp.size ?? "20", 10);
  const status = (sp.status as DocumentStatus) || undefined;
  const q = sp.q || undefined;
  const sort = sp.sort || "uploaded_at,desc";

  const initialData = await listDocuments(
    { page, size: Math.min(size, 100), status, q, sort },
    session.accessToken
  ).catch(() => null);

  return (
    <main className="min-h-screen bg-gray-50 dark:bg-gray-900">
      {/* 헤더 */}
      <header className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 shadow-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4 flex items-center gap-4">
          <a href="/" className="text-sm text-blue-600 dark:text-blue-400 hover:underline">
            ← 홈
          </a>
          <span className="text-xl font-bold text-gray-900 dark:text-white">
            문서 목록
          </span>
        </div>
      </header>

      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {initialData === null ? (
          <div
            role="alert"
            className="rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 p-6"
          >
            <p className="text-sm font-semibold text-red-800 dark:text-red-300">
              목록을 불러오지 못했습니다. 페이지를 새로고침해 주세요.
            </p>
          </div>
        ) : (
          <DocumentList
            initialData={initialData}
            initialPage={page}
            initialStatus={status ?? ""}
            initialQ={q ?? ""}
            initialSort={sort}
          />
        )}
      </div>
    </main>
  );
}
