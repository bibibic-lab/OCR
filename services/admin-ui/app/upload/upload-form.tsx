"use client";

import { useSession } from "next-auth/react";
import { useRef, useState } from "react";
import { uploadDocument, pollDocument, type DocumentResult } from "@/lib/api";

// ──────────────────────────────────────────────────────────
// 상태 타입
// ──────────────────────────────────────────────────────────

type Phase = "idle" | "uploading" | "processing" | "done" | "failed";

interface UploadState {
  phase: Phase;
  message: string;
  docId?: string;
  result?: DocumentResult;
}

// ──────────────────────────────────────────────────────────
// 허용 MIME / 확장자
// ──────────────────────────────────────────────────────────

const ALLOWED_TYPES = ["image/png", "image/jpeg", "application/pdf"];
const MAX_BYTES = 50 * 1024 * 1024; // 50 MB

// ──────────────────────────────────────────────────────────
// 헬퍼
// ──────────────────────────────────────────────────────────

function statusLabel(status: string): string {
  switch (status) {
    case "UPLOADED":
      return "업로드됨";
    case "OCR_RUNNING":
      return "OCR 처리 중";
    case "OCR_DONE":
      return "OCR 완료";
    case "OCR_FAILED":
      return "OCR 실패";
    default:
      return status;
  }
}

function StatusBadge({ status }: { status: string }) {
  const colorMap: Record<string, string> = {
    UPLOADED: "bg-gray-100 text-gray-700",
    OCR_RUNNING: "bg-yellow-100 text-yellow-800",
    OCR_DONE: "bg-green-100 text-green-800",
    OCR_FAILED: "bg-red-100 text-red-800",
  };
  const cls = colorMap[status] ?? "bg-gray-100 text-gray-700";
  return (
    <span
      className={`inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold ${cls}`}
    >
      {statusLabel(status)}
    </span>
  );
}

// ──────────────────────────────────────────────────────────
// 메인 컴포넌트
// ──────────────────────────────────────────────────────────

export function UploadForm() {
  const { data: session, status: sessionStatus } = useSession();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [uploadState, setUploadState] = useState<UploadState>({
    phase: "idle",
    message: "",
  });

  // ── 세션 로딩 처리 ──
  if (sessionStatus === "loading") {
    return (
      <div
        className="text-sm text-gray-500 dark:text-gray-400"
        aria-live="polite"
      >
        로딩 중…
      </div>
    );
  }

  if (!session?.accessToken) {
    return (
      <div className="text-sm text-red-600 dark:text-red-400" role="alert">
        인증 정보를 찾을 수 없습니다. 다시 로그인해 주세요.
      </div>
    );
  }

  const token = session.accessToken;
  const isIdle = uploadState.phase === "idle";
  const isSubmitting =
    uploadState.phase === "uploading" || uploadState.phase === "processing";

  // ── 파일 선택 검증 ──
  function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0] ?? null;
    if (!file) {
      setSelectedFile(null);
      return;
    }

    if (!ALLOWED_TYPES.includes(file.type)) {
      setUploadState({
        phase: "failed",
        message: "허용되지 않는 파일 형식입니다. PNG, JPG, PDF만 가능합니다.",
      });
      setSelectedFile(null);
      e.target.value = "";
      return;
    }

    if (file.size > MAX_BYTES) {
      setUploadState({
        phase: "failed",
        message: `파일 크기가 50 MB를 초과합니다. (현재: ${(file.size / 1024 / 1024).toFixed(1)} MB)`,
      });
      setSelectedFile(null);
      e.target.value = "";
      return;
    }

    setSelectedFile(file);
    setUploadState({ phase: "idle", message: "" });
  }

  // ── 업로드 + 폴링 ──
  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!selectedFile || isSubmitting) return;

    setUploadState({ phase: "uploading", message: "파일을 업로드하는 중…" });

    let docId: string;
    try {
      const created = await uploadDocument(selectedFile, token);
      docId = created.id;

      // 결과 페이지에서 원본 이미지를 오버레이할 수 있도록
      // sessionStorage에 data URL + 크기를 저장한다.
      // (같은 세션에서 업로드 → 결과 보기 흐름에서만 동작; 크로스-세션은 허용 범위 외)
      const reader = new FileReader();
      reader.onload = (ev) => {
        const dataUrl = ev.target?.result as string;
        if (!dataUrl) return;
        sessionStorage.setItem(`doc:${docId}:original`, dataUrl);
        // 실제 픽셀 크기도 저장해 SVG viewBox 계산에 활용
        const img = new Image();
        img.onload = () => {
          sessionStorage.setItem(`doc:${docId}:dim`, `${img.width}x${img.height}`);
        };
        img.src = dataUrl;
      };
      reader.readAsDataURL(selectedFile);
    } catch (err) {
      setUploadState({
        phase: "failed",
        message:
          err instanceof Error ? err.message : "업로드 중 오류가 발생했습니다.",
      });
      return;
    }

    setUploadState({
      phase: "processing",
      message: "OCR 처리 중… (최대 60초 소요)",
      docId,
    });

    try {
      const result = await pollDocument(docId, token, {
        intervalMs: 1500,
        timeoutMs: 60000,
      });
      setUploadState({
        phase: "done",
        message: result.status === "OCR_DONE" ? "처리 완료!" : "OCR 처리 실패",
        docId,
        result,
      });
    } catch (err) {
      setUploadState({
        phase: "failed",
        message:
          err instanceof Error
            ? err.message
            : "폴링 중 오류가 발생했습니다.",
        docId,
      });
    }
  }

  // ── 초기화 ──
  function handleReset() {
    setSelectedFile(null);
    setUploadState({ phase: "idle", message: "" });
    if (fileInputRef.current) fileInputRef.current.value = "";
  }

  return (
    <form onSubmit={handleSubmit} noValidate>
      {/* 파일 선택 */}
      <div className="mb-6">
        <label
          htmlFor="file-input"
          className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2"
        >
          파일 선택
          <span className="ml-2 text-xs text-gray-400 font-normal">
            (PNG · JPG · PDF, 최대 50 MB)
          </span>
        </label>
        <input
          id="file-input"
          ref={fileInputRef}
          type="file"
          accept=".png,.jpg,.jpeg,.pdf"
          disabled={isSubmitting}
          onChange={handleFileChange}
          className="block w-full text-sm text-gray-700 dark:text-gray-300
            file:mr-4 file:py-2 file:px-4
            file:rounded-lg file:border-0
            file:text-sm file:font-medium
            file:bg-blue-50 file:text-blue-700
            hover:file:bg-blue-100
            dark:file:bg-blue-900 dark:file:text-blue-200
            disabled:opacity-50 disabled:cursor-not-allowed"
          aria-describedby="file-hint"
        />
        {selectedFile && (
          <p
            id="file-hint"
            className="mt-1.5 text-xs text-gray-500 dark:text-gray-400"
          >
            선택됨: {selectedFile.name} (
            {(selectedFile.size / 1024).toFixed(0)} KB)
          </p>
        )}
      </div>

      {/* 제출 버튼 */}
      <div className="flex gap-3">
        <button
          type="submit"
          disabled={!selectedFile || isSubmitting}
          className="px-5 py-2.5 rounded-lg bg-blue-600 text-white text-sm font-medium
            hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2
            disabled:opacity-50 disabled:cursor-not-allowed
            transition-colors"
        >
          {uploadState.phase === "uploading"
            ? "업로드 중…"
            : uploadState.phase === "processing"
              ? "처리 중…"
              : "업로드"}
        </button>

        {!isIdle && !isSubmitting && (
          <button
            type="button"
            onClick={handleReset}
            className="px-5 py-2.5 rounded-lg bg-gray-100 text-gray-700 text-sm font-medium
              hover:bg-gray-200 focus:outline-none focus:ring-2 focus:ring-gray-400 focus:ring-offset-2
              dark:bg-gray-700 dark:text-gray-200 dark:hover:bg-gray-600
              transition-colors"
          >
            초기화
          </button>
        )}
      </div>

      {/* 상태 메시지 — aria-live로 스크린리더에 알림 */}
      <div aria-live="polite" aria-atomic="true" className="mt-6">
        {/* 처리 중 스피너 */}
        {isSubmitting && (
          <div className="flex items-center gap-3 text-sm text-gray-600 dark:text-gray-300">
            <span
              className="inline-block h-4 w-4 rounded-full border-2 border-blue-500 border-t-transparent animate-spin"
              aria-hidden="true"
            />
            {uploadState.message}
          </div>
        )}

        {/* 오류 */}
        {uploadState.phase === "failed" && (
          <div
            role="alert"
            className="rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 p-4"
          >
            <p className="text-sm font-medium text-red-800 dark:text-red-300">
              오류
            </p>
            <p className="mt-1 text-sm text-red-700 dark:text-red-400">
              {uploadState.message}
            </p>
            {uploadState.docId && (
              <p className="mt-2 text-xs text-red-500 font-mono">
                문서 ID: {uploadState.docId}
              </p>
            )}
          </div>
        )}

        {/* 완료 */}
        {uploadState.phase === "done" && uploadState.result && (
          <div className="rounded-lg bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 p-4 space-y-3">
            <div className="flex items-center gap-3">
              <StatusBadge status={uploadState.result.status} />
              <span className="text-sm font-medium text-green-800 dark:text-green-300">
                {uploadState.message}
              </span>
            </div>

            <dl className="text-sm space-y-1">
              <div className="flex gap-2">
                <dt className="text-gray-500 dark:text-gray-400 min-w-[80px]">
                  문서 ID
                </dt>
                <dd className="font-mono text-gray-800 dark:text-gray-200 break-all">
                  {uploadState.result.id}
                </dd>
              </div>
              {uploadState.result.engine && (
                <div className="flex gap-2">
                  <dt className="text-gray-500 dark:text-gray-400 min-w-[80px]">
                    엔진
                  </dt>
                  <dd className="text-gray-800 dark:text-gray-200">
                    {uploadState.result.engine}
                  </dd>
                </div>
              )}
              {uploadState.result.langs && (
                <div className="flex gap-2">
                  <dt className="text-gray-500 dark:text-gray-400 min-w-[80px]">
                    언어
                  </dt>
                  <dd className="text-gray-800 dark:text-gray-200">
                    {uploadState.result.langs.join(", ")}
                  </dd>
                </div>
              )}
              {uploadState.result.items && (
                <div className="flex gap-2">
                  <dt className="text-gray-500 dark:text-gray-400 min-w-[80px]">
                    인식 항목
                  </dt>
                  <dd className="text-gray-800 dark:text-gray-200">
                    {uploadState.result.items.length}건
                  </dd>
                </div>
              )}
            </dl>

            {/* 결과 보기 링크 */}
            <a
              href={`/documents/${uploadState.result.id}`}
              className="inline-block mt-1 px-4 py-2 rounded-lg bg-green-600 text-white text-sm font-medium
                hover:bg-green-700 focus:outline-none focus:ring-2 focus:ring-green-500 focus:ring-offset-2
                transition-colors"
            >
              결과 보기 →
            </a>
          </div>
        )}
      </div>
    </form>
  );
}
