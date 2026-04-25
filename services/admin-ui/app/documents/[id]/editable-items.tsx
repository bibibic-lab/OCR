"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { useSession } from "next-auth/react";
import type { OcrItem } from "@/lib/api";
import { updateDocumentItems } from "@/lib/api";

// ──────────────────────────────────────────────────────────
// Props
// ──────────────────────────────────────────────────────────

interface Props {
  documentId: string;
  initialItems: OcrItem[];
  updatedAt?: string;
  updateCount?: number;
  /** FPE 토큰화 활성 여부 — true 일 때 RRN/카드/계좌 패턴 항목에 [FPE 토큰] 배지 노출. */
  tokenizationEnabled?: boolean;
}

// ──────────────────────────────────────────────────────────
// 민감 패턴 감지 (UI 표시용)
// ──────────────────────────────────────────────────────────

const RRN_PATTERN = /\b\d{6}-\d{7}\b/;
const CARD_PATTERN = /\b\d{4}-\d{4}-\d{4}-\d{4}\b/;
const ACCOUNT_PATTERN = /\b\d{10,14}\b/;

function sensitiveKind(text: string): string | null {
  if (RRN_PATTERN.test(text)) return "RRN";
  if (CARD_PATTERN.test(text)) return "카드";
  if (ACCOUNT_PATTERN.test(text)) return "계좌";
  return null;
}

// ──────────────────────────────────────────────────────────
// 컴포넌트
// ──────────────────────────────────────────────────────────

/**
 * EditableItems — OCR 결과 items 인라인 편집 UI.
 *
 * - "편집" 버튼 → 각 행이 <input>으로 전환 (text만 수정, confidence·bbox는 그대로 유지)
 * - "저장" → PUT /documents/{id}/items → router.refresh()
 * - "취소" → 원래 상태 복원
 * - loading 중 모든 버튼 disabled
 */
export function EditableItems({
  documentId,
  initialItems,
  updatedAt,
  updateCount = 0,
  tokenizationEnabled = true,
}: Props) {
  const { data: session } = useSession();
  const router = useRouter();

  const [isEditing, setIsEditing] = useState(false);
  const [editItems, setEditItems] = useState<OcrItem[]>(initialItems);
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleEdit = () => {
    setEditItems(initialItems.map((item) => ({ ...item })));
    setError(null);
    setIsEditing(true);
  };

  const handleCancel = () => {
    setEditItems(initialItems.map((item) => ({ ...item })));
    setError(null);
    setIsEditing(false);
  };

  const handleTextChange = (idx: number, text: string) => {
    setEditItems((prev) =>
      prev.map((item, i) => (i === idx ? { ...item, text } : item))
    );
  };

  const handleSave = async () => {
    if (!session?.accessToken) {
      setError("세션이 만료되었습니다. 다시 로그인해 주세요.");
      return;
    }

    setIsSaving(true);
    setError(null);

    try {
      await updateDocumentItems(documentId, editItems, session.accessToken);
      setIsEditing(false);
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "저장 중 오류가 발생했습니다.");
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <div className="space-y-4">
      {/* ── 헤더 + 버튼 ── */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">
            OCR 결과 items
          </h2>
          {updateCount > 0 && updatedAt && (
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
              수정 {updateCount}회 · 최종:{" "}
              {new Date(updatedAt).toLocaleString("ko-KR")}
            </p>
          )}
        </div>
        <div className="flex gap-2">
          {isEditing ? (
            <>
              <button
                onClick={handleCancel}
                disabled={isSaving}
                className="px-3 py-1.5 text-sm rounded-md border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                취소
              </button>
              <button
                onClick={handleSave}
                disabled={isSaving}
                className="px-3 py-1.5 text-sm rounded-md bg-blue-600 hover:bg-blue-700 text-white font-medium disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-1.5"
              >
                {isSaving && (
                  <span
                    className="inline-block h-3.5 w-3.5 rounded-full border-2 border-white border-t-transparent animate-spin"
                    aria-hidden="true"
                  />
                )}
                {isSaving ? "저장 중…" : "저장"}
              </button>
            </>
          ) : (
            <button
              onClick={handleEdit}
              className="px-3 py-1.5 text-sm rounded-md border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
            >
              편집
            </button>
          )}
        </div>
      </div>

      {/* ── 에러 배너 ── */}
      {error && (
        <div
          role="alert"
          className="rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 px-4 py-3"
        >
          <p className="text-sm text-red-700 dark:text-red-400">{error}</p>
        </div>
      )}

      {/* ── Items 테이블 ── */}
      <div className="rounded-xl border border-gray-200 dark:border-gray-700 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-gray-100 dark:bg-gray-800">
              <tr>
                <th className="px-4 py-2.5 text-left text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wider w-10">
                  #
                </th>
                <th className="px-4 py-2.5 text-left text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wider">
                  텍스트
                </th>
                <th className="px-4 py-2.5 text-left text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wider w-28">
                  신뢰도
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-700 bg-white dark:bg-gray-900">
              {(isEditing ? editItems : initialItems).map((item, i) => (
                <tr
                  key={i}
                  className="hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
                >
                  <td className="px-4 py-2 text-gray-400 font-mono text-xs">
                    {i + 1}
                  </td>
                  <td className="px-4 py-2 text-gray-900 dark:text-gray-100">
                    {isEditing ? (
                      <input
                        type="text"
                        value={item.text}
                        onChange={(e) => handleTextChange(i, e.target.value)}
                        disabled={isSaving}
                        className="w-full bg-white dark:bg-gray-800 border border-blue-300 dark:border-blue-600 rounded px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-60"
                        aria-label={`항목 ${i + 1} 텍스트`}
                      />
                    ) : (
                      <span className="flex items-center gap-2 max-w-[460px]">
                        <span className="truncate">{item.text}</span>
                        {tokenizationEnabled && sensitiveKind(item.text) && (
                          <span
                            title="이 값은 FPE 로 토큰화됨 — 원본은 PII vault 에 보관"
                            className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-800 text-[10px] font-semibold whitespace-nowrap"
                          >
                            🔒 FPE 토큰 ({sensitiveKind(item.text)})
                          </span>
                        )}
                        {!tokenizationEnabled && sensitiveKind(item.text) && (
                          <span
                            title="데모 모드 — 평문 노출"
                            className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded bg-red-100 text-red-800 text-[10px] font-semibold whitespace-nowrap"
                          >
                            ⚠️ 평문 ({sensitiveKind(item.text)})
                          </span>
                        )}
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-2">
                    <span
                      className={`inline-block px-2 py-0.5 rounded-full text-xs font-semibold ${
                        item.confidence >= 0.9
                          ? "bg-green-100 text-green-800"
                          : item.confidence >= 0.5
                          ? "bg-yellow-100 text-yellow-800"
                          : "bg-red-100 text-red-800"
                      }`}
                    >
                      {(item.confidence * 100).toFixed(1)}%
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
