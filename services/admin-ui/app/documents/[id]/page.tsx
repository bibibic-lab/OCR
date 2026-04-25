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
  const { id } = await params;

  // 진단 로그 (서버 콘솔). 미들웨어가 이미 인증 체크하므로 여기서는 redirect 대신
  // 명시적 안내 페이지를 보여 디버깅을 쉽게 한다.
  console.log(
    `[DocumentPage] id=${id} session=${session ? "yes" : "no"} ` +
    `accessToken=${session?.accessToken ? `len=${session.accessToken.length}` : "null"} ` +
    `error=${session?.error ?? "none"}`
  );

  // accessToken 없으면 명시적 메시지 (redirect 루프 방지)
  if (!session?.accessToken) {
    return (
      <main className="min-h-screen p-8 bg-gray-50">
        <div className="max-w-2xl mx-auto bg-white rounded-lg p-6 shadow">
          <h1 className="text-xl font-bold text-red-700 mb-2">세션 문제</h1>
          <p className="text-gray-700 mb-4">
            세션은 있으나 accessToken이 비어있습니다. 다시 로그인해 주세요.
          </p>
          <p className="text-sm text-gray-500 font-mono mb-4">
            session: {session ? "exists" : "null"} · error: {session?.error ?? "none"}
          </p>
          <a href="/api/auth/signin" className="inline-block px-4 py-2 bg-blue-600 text-white rounded">
            다시 로그인
          </a>
        </div>
      </main>
    );
  }

  const doc = await getDocument(id, session.accessToken).catch((err: unknown) => ({
    error: err instanceof Error ? err.message : "문서 조회 중 오류가 발생했습니다.",
  }));

  return (
    <main className="min-h-screen bg-gray-50 dark:bg-gray-900">
      {/* ── 헤더 ── */}
      <header className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 shadow-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4 flex items-center gap-4">
          <a
            href="/documents"
            className="text-sm text-blue-600 dark:text-blue-400 hover:underline"
          >
            ← 문서 목록
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
              <div className="space-y-6">
                {/* 데모 모드 경고: 토큰화 OFF 일 때 빨간 배너 */}
                {doc.tokenizationEnabled === false && (
                  <div
                    role="alert"
                    className="rounded-lg bg-red-50 dark:bg-red-900/20 border-2 border-red-300 dark:border-red-700 p-4"
                  >
                    <div className="flex items-start gap-3">
                      <span className="text-2xl">⚠️</span>
                      <div>
                        <p className="font-bold text-red-800 dark:text-red-300">
                          데모 모드 — 실제 민감정보가 평문으로 노출됩니다
                        </p>
                        <p className="text-sm text-red-700 dark:text-red-400 mt-1">
                          현재 FPE 토큰화가 비활성화된 상태입니다 (FPE_TOKENIZATION_ENABLED=false).
                          실 운영 환경에서는 RRN·카드·계좌 등 민감 필드가 자동 토큰화되며 원본은 PII vault 에만 저장됩니다.
                          데모 종료 후 반드시 다시 활성화해 주세요.
                        </p>
                      </div>
                    </div>
                  </div>
                )}
                {/* 토큰화 ON 안내 (옅은 정보 박스) */}
                {doc.tokenizationEnabled !== false && (
                  <div className="rounded-lg bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 px-4 py-2 flex items-center gap-2 text-sm text-green-800 dark:text-green-300">
                    <span aria-hidden>🔒</span>
                    <span>
                      FPE 토큰화 활성. RRN·카드·계좌 등 민감 패턴은 자동 토큰화되어 원본은
                      PII vault 에만 저장됩니다. 표시된 토큰 값은 원본이 아닙니다.
                    </span>
                  </div>
                )}
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
                  tokenizationEnabled={doc.tokenizationEnabled !== false}
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
