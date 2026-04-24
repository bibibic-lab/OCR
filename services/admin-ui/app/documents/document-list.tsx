"use client";

import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { useState, useTransition, useCallback } from "react";
import Link from "next/link";
import { listDocuments } from "@/lib/api";
import { StatusBadge } from "@/components/status-badge";
import { useSession } from "next-auth/react";
import type { DocumentPage, DocumentListItem, DocumentStatus } from "@/lib/api";

interface DocumentListProps {
  initialData: DocumentPage;
  initialPage: number;
  initialStatus: string;
  initialQ: string;
  initialSort: string;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString("ko-KR", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function DocumentList({
  initialData,
  initialPage,
  initialStatus,
  initialQ,
  initialSort,
}: DocumentListProps) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const { data: session } = useSession();
  const [isPending, startTransition] = useTransition();

  const [data, setData] = useState<DocumentPage>(initialData);
  const [page, setPage] = useState(initialPage);
  const [status, setStatus] = useState(initialStatus);
  const [q, setQ] = useState(initialQ);
  const [sort, setSort] = useState(initialSort);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const buildUrl = useCallback(
    (overrides: Partial<{ page: number; status: string; q: string; sort: string }>) => {
      const params = new URLSearchParams(searchParams.toString());
      const merged = { page, status, q, sort, ...overrides };
      params.set("page", String(merged.page));
      if (merged.status) params.set("status", merged.status);
      else params.delete("status");
      if (merged.q) params.set("q", merged.q);
      else params.delete("q");
      params.set("sort", merged.sort);
      return `${pathname}?${params.toString()}`;
    },
    [pathname, searchParams, page, status, q, sort]
  );

  const fetchData = useCallback(
    async (overrides: Partial<{ page: number; status: string; q: string; sort: string }>) => {
      if (!session?.accessToken) return;
      const merged = { page, status, q, sort, ...overrides };
      setLoading(true);
      setError(null);
      try {
        const result = await listDocuments(
          {
            page: merged.page,
            size: 20,
            status: (merged.status as DocumentStatus) || undefined,
            q: merged.q || undefined,
            sort: merged.sort,
          },
          session.accessToken
        );
        setData(result);
        setPage(merged.page);
        setStatus(merged.status);
        setQ(merged.q);
        setSort(merged.sort);
        startTransition(() => {
          router.push(buildUrl(overrides), { scroll: false });
        });
      } catch (e) {
        setError(e instanceof Error ? e.message : "조회 실패");
      } finally {
        setLoading(false);
      }
    },
    [session, page, status, q, sort, router, buildUrl]
  );

  const handleStatusChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    fetchData({ status: e.target.value, page: 0 });
  };

  const handleSortChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    fetchData({ sort: e.target.value, page: 0 });
  };

  const handleSearch = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    fetchData({ q, page: 0 });
  };

  const handlePageChange = (newPage: number) => {
    fetchData({ page: newPage });
  };

  return (
    <div className="space-y-4">
      {/* 필터 바 */}
      <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-4">
        <div className="flex flex-wrap gap-3 items-end">
          {/* 검색 */}
          <form onSubmit={handleSearch} className="flex gap-2">
            <input
              type="text"
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="파일명 검색..."
              className="px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg
                bg-white dark:bg-gray-700 text-gray-900 dark:text-white
                focus:outline-none focus:ring-2 focus:ring-blue-500 w-56"
            />
            <button
              type="submit"
              className="px-4 py-2 text-sm font-medium bg-blue-600 text-white rounded-lg
                hover:bg-blue-700 transition-colors disabled:opacity-50"
              disabled={loading}
            >
              검색
            </button>
          </form>

          {/* 상태 필터 */}
          <select
            value={status}
            onChange={handleStatusChange}
            disabled={loading}
            className="px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg
              bg-white dark:bg-gray-700 text-gray-900 dark:text-white
              focus:outline-none focus:ring-2 focus:ring-blue-500"
          >
            <option value="">전체 상태</option>
            <option value="UPLOADED">업로드됨</option>
            <option value="OCR_RUNNING">OCR 처리 중</option>
            <option value="OCR_DONE">OCR 완료</option>
            <option value="OCR_FAILED">OCR 실패</option>
          </select>

          {/* 정렬 */}
          <select
            value={sort}
            onChange={handleSortChange}
            disabled={loading}
            className="px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg
              bg-white dark:bg-gray-700 text-gray-900 dark:text-white
              focus:outline-none focus:ring-2 focus:ring-blue-500"
          >
            <option value="uploaded_at,desc">최신 업로드순</option>
            <option value="uploaded_at,asc">오래된 업로드순</option>
            <option value="ocr_finished_at,desc">최신 OCR 완료순</option>
            <option value="ocr_finished_at,asc">오래된 OCR 완료순</option>
          </select>

          <div className="ml-auto">
            <Link
              href="/upload"
              className="inline-flex items-center gap-2 px-4 py-2 text-sm font-medium
                bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
            >
              + 업로드
            </Link>
          </div>
        </div>
      </div>

      {/* 오류 */}
      {error && (
        <div role="alert" className="rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 p-4">
          <p className="text-sm text-red-700 dark:text-red-400">{error}</p>
        </div>
      )}

      {/* 통계 */}
      <div className="text-sm text-gray-500 dark:text-gray-400">
        {loading ? (
          <span>불러오는 중...</span>
        ) : (
          <span>
            총 <span className="font-semibold text-gray-900 dark:text-white">{data.totalElements.toLocaleString()}</span>건
            {data.totalPages > 1 && ` (${data.page + 1} / ${data.totalPages} 페이지)`}
          </span>
        )}
      </div>

      {/* 테이블 */}
      <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 overflow-hidden">
        {data.content.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-20 text-gray-400 dark:text-gray-500">
            <p className="text-lg font-medium mb-1">문서가 없습니다</p>
            <p className="text-sm">업로드 버튼으로 첫 문서를 추가해보세요.</p>
          </div>
        ) : (
          <div className={`overflow-x-auto transition-opacity ${loading || isPending ? "opacity-50" : ""}`}>
            <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
              <thead className="bg-gray-50 dark:bg-gray-700/50">
                <tr>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    파일명
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    상태
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    크기
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    업로드 시각
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    OCR 완료
                  </th>
                  <th className="px-4 py-3 text-center text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    항목 수
                  </th>
                  <th className="px-4 py-3 text-center text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    수정
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
                {data.content.map((doc: DocumentListItem) => (
                  <tr
                    key={doc.id}
                    className="hover:bg-gray-50 dark:hover:bg-gray-700/30 transition-colors"
                  >
                    <td className="px-4 py-3 max-w-xs">
                      <Link
                        href={`/documents/${doc.id}`}
                        className="text-sm font-medium text-blue-600 dark:text-blue-400 hover:underline truncate block"
                        title={doc.filename}
                      >
                        {doc.filename}
                      </Link>
                      <span className="text-xs text-gray-400 font-mono">{doc.id.slice(0, 8)}…</span>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap">
                      <StatusBadge status={doc.status} />
                    </td>
                    <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300 whitespace-nowrap">
                      {formatBytes(doc.byteSize)}
                    </td>
                    <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300 whitespace-nowrap">
                      {formatDateTime(doc.uploadedAt)}
                    </td>
                    <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300 whitespace-nowrap">
                      {doc.ocrFinishedAt ? formatDateTime(doc.ocrFinishedAt) : "—"}
                    </td>
                    <td className="px-4 py-3 text-sm text-center text-gray-600 dark:text-gray-300">
                      {doc.status === "OCR_DONE" ? doc.itemCount : "—"}
                    </td>
                    <td className="px-4 py-3 text-center">
                      {doc.updateCount > 0 ? (
                        <span className="inline-block px-2 py-0.5 text-xs bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300 rounded-full">
                          {doc.updateCount}회
                        </span>
                      ) : (
                        <span className="text-sm text-gray-400">—</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* 페이지네이션 */}
      {data.totalPages > 1 && (
        <div className="flex items-center justify-center gap-2">
          <button
            onClick={() => handlePageChange(page - 1)}
            disabled={page === 0 || loading}
            className="px-3 py-1.5 text-sm border border-gray-300 dark:border-gray-600 rounded-lg
              hover:bg-gray-50 dark:hover:bg-gray-700 disabled:opacity-40 disabled:cursor-not-allowed
              text-gray-700 dark:text-gray-300 transition-colors"
          >
            ← 이전
          </button>

          <span className="text-sm text-gray-600 dark:text-gray-400 px-2">
            {page + 1} / {data.totalPages}
          </span>

          <button
            onClick={() => handlePageChange(page + 1)}
            disabled={!data.hasNext || loading}
            className="px-3 py-1.5 text-sm border border-gray-300 dark:border-gray-600 rounded-lg
              hover:bg-gray-50 dark:hover:bg-gray-700 disabled:opacity-40 disabled:cursor-not-allowed
              text-gray-700 dark:text-gray-300 transition-colors"
          >
            다음 →
          </button>
        </div>
      )}
    </div>
  );
}
