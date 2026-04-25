"use client";

import { useState, useEffect, useCallback } from "react";
import type { StatsResponse, DocumentStatus } from "@/lib/api";
import { githubDocUrl } from "@/lib/guide-url";

// ──────────────────────────────────────────────────────────
// 헬퍼
// ──────────────────────────────────────────────────────────

const STATUS_LABELS: Record<DocumentStatus, string> = {
  UPLOADED: "대기",
  OCR_RUNNING: "처리중",
  OCR_DONE: "완료",
  OCR_FAILED: "실패",
};

const STATUS_COLORS: Record<DocumentStatus, string> = {
  UPLOADED: "bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-300",
  OCR_RUNNING:
    "bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300",
  OCR_DONE:
    "bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300",
  OCR_FAILED: "bg-red-100 text-red-700 dark:bg-red-900 dark:text-red-300",
};

function formatDateTime(iso: string): string {
  const d = new Date(iso);
  return d.toLocaleString("ko-KR", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

// ──────────────────────────────────────────────────────────
// 통계 카드 단위
// ──────────────────────────────────────────────────────────

interface StatCardProps {
  label: string;
  value: number | string;
  sub?: string;
  color?: string;
}

function StatCard({ label, value, sub, color = "border-gray-200 dark:border-gray-700" }: StatCardProps) {
  return (
    <div
      className={`bg-white dark:bg-gray-800 rounded-xl border ${color} p-5 shadow-sm`}
    >
      <p className="text-sm font-medium text-gray-500 dark:text-gray-400">
        {label}
      </p>
      <p className="mt-1 text-3xl font-bold text-gray-900 dark:text-white">
        {value}
      </p>
      {sub && (
        <p className="mt-1 text-xs text-gray-400 dark:text-gray-500">{sub}</p>
      )}
    </div>
  );
}

// ──────────────────────────────────────────────────────────
// 메인 컴포넌트
// ──────────────────────────────────────────────────────────

interface StatsCardsProps {
  stats: StatsResponse;
}

export function StatsCards({ stats: initialStats }: StatsCardsProps) {
  const [stats, setStats] = useState<StatsResponse>(initialStats);
  // 초기값은 null — SSR/Client 시각 불일치로 인한 hydration 오류 방지.
  // useEffect에서 클라이언트 시점에 Date 주입.
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  // 마운트 직후 클라이언트 현재 시각 1회 설정
  useEffect(() => {
    setLastUpdated(new Date());
  }, []);

  const refresh = useCallback(async () => {
    setRefreshing(true);
    try {
      // 클라이언트 사이드 /api/stats 프록시 라우트를 통해 갱신
      const res = await fetch("/api/stats");
      if (res.ok) {
        const fresh = await res.json();
        setStats(fresh);
        setLastUpdated(new Date());
      }
    } catch {
      // 갱신 실패 시 현재 데이터 유지
    } finally {
      setRefreshing(false);
    }
  }, []);

  // 30초 자동 갱신
  useEffect(() => {
    const id = setInterval(refresh, 30_000);
    return () => clearInterval(id);
  }, [refresh]);

  const pending =
    (stats.owner.byStatus["UPLOADED"] ?? 0) +
    (stats.owner.byStatus["OCR_RUNNING"] ?? 0);

  return (
    <div className="space-y-8">
      {/* 상단 요약 헤더 */}
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white">
          대시보드
        </h1>
        <div className="flex items-center gap-3">
          <span className="text-xs text-gray-400 dark:text-gray-500" suppressHydrationWarning>
            마지막 갱신: {lastUpdated ? lastUpdated.toLocaleTimeString("ko-KR") : "—"}
          </span>
          <button
            onClick={refresh}
            disabled={refreshing}
            className="px-3 py-1.5 text-xs font-medium rounded-lg bg-blue-600 text-white
              hover:bg-blue-700 disabled:opacity-50 transition-colors"
          >
            {refreshing ? "갱신 중..." : "새로고침"}
          </button>
        </div>
      </div>

      {/* ① 상단 카드 그리드 */}
      <section>
        <h2 className="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-3">
          문서 현황
        </h2>
        <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-4">
          <StatCard
            label="전체 문서"
            value={stats.owner.total}
            color="border-blue-200 dark:border-blue-800"
          />
          <StatCard
            label="오늘 업로드"
            value={stats.owner.today}
            color="border-indigo-200 dark:border-indigo-800"
          />
          <StatCard
            label="처리 중"
            value={pending}
            sub="UPLOADED + OCR_RUNNING"
            color="border-yellow-200 dark:border-yellow-800"
          />
          <StatCard
            label="처리 완료"
            value={stats.owner.byStatus["OCR_DONE"] ?? 0}
            color="border-green-200 dark:border-green-800"
          />
          <StatCard
            label="실패"
            value={stats.owner.byStatus["OCR_FAILED"] ?? 0}
            sub={`오늘 실패: ${stats.owner.todayFailed}`}
            color="border-red-200 dark:border-red-800"
          />
          <StatCard
            label="수정됨"
            value={stats.owner.totalEdited}
            sub="OCR 결과 수정 건"
            color="border-purple-200 dark:border-purple-800"
          />
        </div>
      </section>

      {/* ② 최근 업로드 리스트 */}
      <section>
        <h2 className="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-3">
          최근 업로드 (5건)
        </h2>
        <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 shadow-sm overflow-hidden">
          {stats.recent.length === 0 ? (
            <div className="px-6 py-8 text-center text-gray-400 dark:text-gray-500 text-sm">
              업로드된 문서가 없습니다.
            </div>
          ) : (
            <table className="min-w-full divide-y divide-gray-100 dark:divide-gray-700">
              <thead className="bg-gray-50 dark:bg-gray-900">
                <tr>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400">
                    파일명
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400">
                    상태
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400">
                    업로드 시각
                  </th>
                  <th className="px-4 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400">
                    항목 수
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
                {stats.recent.map((item) => (
                  <tr
                    key={item.id}
                    className="hover:bg-gray-50 dark:hover:bg-gray-750 transition-colors"
                  >
                    <td className="px-4 py-3">
                      <a
                        href={`/documents/${item.id}`}
                        className="text-sm font-medium text-blue-600 dark:text-blue-400 hover:underline truncate max-w-xs block"
                      >
                        {item.filename}
                      </a>
                    </td>
                    <td className="px-4 py-3">
                      <span
                        className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${STATUS_COLORS[item.status as DocumentStatus] ?? ""}`}
                      >
                        {STATUS_LABELS[item.status as DocumentStatus] ?? item.status}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-sm text-gray-500 dark:text-gray-400">
                      {formatDateTime(item.uploadedAt)}
                    </td>
                    <td className="px-4 py-3 text-sm text-right text-gray-700 dark:text-gray-300">
                      {item.itemCount}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </section>

      {/* ③ 현재 엔진 */}
      <section>
        <h2 className="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-3">
          OCR 엔진
        </h2>
        <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 shadow-sm p-5">
          <div className="flex flex-col sm:flex-row sm:items-center gap-4">
            <div>
              <p className="text-xs text-gray-500 dark:text-gray-400 mb-1">
                현재 엔진
              </p>
              <p className="text-base font-semibold text-gray-900 dark:text-white">
                {stats.engines.current}
              </p>
            </div>
            {stats.engines.alternatives.length > 0 && (
              <div className="sm:ml-8">
                <p className="text-xs text-gray-500 dark:text-gray-400 mb-1">
                  대체 엔진
                </p>
                <div className="flex flex-wrap gap-2">
                  {stats.engines.alternatives.map((alt) => (
                    <span
                      key={alt}
                      className="px-2 py-1 bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 rounded text-xs"
                    >
                      {alt}
                    </span>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      </section>

      {/* ④ Not Implemented 기능 목록 (POLICY-NI-01) */}
      <section>
        <div className="flex items-center gap-2 mb-3">
          <h2 className="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide">
            Not Implemented 기능
          </h2>
          <span className="px-2 py-0.5 rounded-full bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-300 text-xs font-bold">
            모의 응답 중: {stats.notImplemented.length}건
          </span>
        </div>
        <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-xl overflow-hidden">
          <div className="px-5 py-3 border-b border-yellow-200 dark:border-yellow-800">
            <p className="text-sm text-yellow-800 dark:text-yellow-300 font-medium">
              ⚠️ 아래 기능은 현재 더미(Mock) 응답으로 동작 중입니다. 실 외부 API 계약 또는 하드웨어 조달 완료 후 전환됩니다.
            </p>
          </div>
          <ul className="divide-y divide-yellow-100 dark:divide-yellow-800/50">
            {stats.notImplemented.map((ni) => (
              <li
                key={ni.feature}
                className="px-5 py-4 flex flex-col sm:flex-row sm:items-start sm:justify-between gap-2"
              >
                <div>
                  <p className="text-sm font-semibold text-yellow-900 dark:text-yellow-200">
                    {ni.feature}
                  </p>
                  <p className="text-xs text-yellow-700 dark:text-yellow-400 mt-0.5">
                    {ni.reason}
                  </p>
                </div>
                <a
                  href={githubDocUrl(ni.guideRef)}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="shrink-0 text-xs text-yellow-700 dark:text-yellow-400 underline hover:text-yellow-900 dark:hover:text-yellow-200"
                >
                  가이드 보기 (GitHub)
                </a>
              </li>
            ))}
          </ul>
        </div>
      </section>

      {/* ⑤ 퀵 액션 버튼 */}
      <section>
        <h2 className="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-3">
          퀵 액션
        </h2>
        <div className="flex flex-wrap gap-3">
          <a
            href="/upload"
            className="px-5 py-2.5 bg-blue-600 hover:bg-blue-700 text-white rounded-lg text-sm font-medium transition-colors"
          >
            새 문서 업로드
          </a>
          <a
            href="/documents"
            className="px-5 py-2.5 bg-white dark:bg-gray-800 hover:bg-gray-50 dark:hover:bg-gray-700
              text-gray-700 dark:text-gray-300 border border-gray-300 dark:border-gray-600
              rounded-lg text-sm font-medium transition-colors"
          >
            문서 목록
          </a>
        </div>
      </section>
    </div>
  );
}
