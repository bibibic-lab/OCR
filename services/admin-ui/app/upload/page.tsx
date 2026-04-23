import { auth } from "@/auth";
import { redirect } from "next/navigation";
import { UploadForm } from "./upload-form";

/**
 * /upload — 서버 컴포넌트.
 * 세션을 서버에서 읽고 인증된 경우만 클라이언트 폼을 렌더링한다.
 * 미들웨어가 이미 미인증 요청을 redirect 하므로 여기서는 방어 코드 수준으로만 확인.
 */
export default async function UploadPage() {
  const session = await auth();

  if (!session) {
    redirect("/api/auth/signin");
  }

  return (
    <main className="min-h-screen bg-gray-50 dark:bg-gray-900">
      {/* Header */}
      <header className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 shadow-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4 flex items-center gap-4">
          <a
            href="/"
            className="text-sm text-blue-600 dark:text-blue-400 hover:underline"
          >
            ← 홈
          </a>
          <span className="text-2xl font-bold text-gray-900 dark:text-white">
            문서 업로드
          </span>
        </div>
      </header>

      <div className="max-w-2xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        <div className="bg-white dark:bg-gray-800 rounded-xl shadow-sm border border-gray-200 dark:border-gray-700 p-8">
          <h1 className="text-xl font-semibold text-gray-900 dark:text-white mb-6">
            OCR 처리할 문서를 업로드하세요
          </h1>
          {/* 클라이언트 컴포넌트: useSession으로 토큰 획득 후 API 호출 */}
          <UploadForm />
        </div>
      </div>
    </main>
  );
}
