"use client";

import { useState } from "react";

/**
 * IntegrationTestPanel — 외부 기관 3 엔드포인트 호출 UI (클라이언트 컴포넌트).
 *
 * POLICY-NI-01 Step 3 — UI 배너:
 *   - 각 엔드포인트 호출 버튼 클릭 → /api/integration/[agency] fetch
 *   - 응답 X-Not-Implemented=true 또는 body.not_implemented=true 시 노란 배너 표시
 *   - 응답 body JSON은 [Dummy] 프리픽스로 표시
 *   - 결과 패널 각 응답 값 앞에 [Mock] 워터마크
 */

interface AgencyConfig {
  key: string;
  label: string;
  description: string;
  guideAnchor: string;
  color: "blue" | "green" | "purple";
}

const AGENCIES: AgencyConfig[] = [
  {
    key: "id-verify",
    label: "행안부 ID 검증 테스트",
    description: "주민등록 진위확인 (행안부 MOIS API 더미)",
    guideAnchor: "행안부-주민등록-진위확인",
    color: "blue",
  },
  {
    key: "tsa",
    label: "KISA TSA 타임스탬프 테스트",
    description: "RFC 3161 타임스탬프 발급 (KISA TSA 더미 DER blob)",
    guideAnchor: "kisa-tsa-타임스탬프-rfc-3161",
    color: "green",
  },
  {
    key: "ocsp",
    label: "OCSP 검증 테스트",
    description: "인증서 유효성 검증 (KISA OCSP 더미 응답)",
    guideAnchor: "ocsp-인증서-검증",
    color: "purple",
  },
];

interface AgencyResult {
  agency: string;
  status: number;
  body: Record<string, unknown> | null;
  notImplemented: boolean;
  agencyName: string;
  guideRef: string;
  eta: string;
  error?: string;
  timestamp: string;
}

const colorMap = {
  blue: {
    border: "border-blue-200 dark:border-blue-700",
    hover: "hover:border-blue-400 dark:hover:border-blue-500",
    heading: "group-hover:text-blue-600 dark:group-hover:text-blue-400",
    button: "bg-blue-600 hover:bg-blue-700 text-white disabled:opacity-50",
  },
  green: {
    border: "border-green-200 dark:border-green-700",
    hover: "hover:border-green-400 dark:hover:border-green-500",
    heading: "group-hover:text-green-600 dark:group-hover:text-green-400",
    button: "bg-green-600 hover:bg-green-700 text-white disabled:opacity-50",
  },
  purple: {
    border: "border-purple-200 dark:border-purple-700",
    hover: "hover:border-purple-400 dark:hover:border-purple-500",
    heading: "group-hover:text-purple-600 dark:group-hover:text-purple-400",
    button: "bg-purple-600 hover:bg-purple-700 text-white disabled:opacity-50",
  },
};

export function IntegrationTestPanel() {
  const [results, setResults] = useState<Record<string, AgencyResult>>({});
  const [loading, setLoading] = useState<Record<string, boolean>>({});

  const handleTest = async (agency: AgencyConfig) => {
    setLoading((prev) => ({ ...prev, [agency.key]: true }));

    try {
      const response = await fetch(`/api/integration/${agency.key}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
      });

      const body = (await response.json()) as Record<string, unknown>;

      const notImplemented =
        response.headers.get("X-Not-Implemented") === "true" ||
        body?.not_implemented === true;

      const result: AgencyResult = {
        agency: agency.key,
        status: response.status,
        body,
        notImplemented,
        agencyName: response.headers.get("X-Agency-Name") || agency.label,
        guideRef:
          response.headers.get("X-Guide-Ref") ||
          `docs/ops/integration-real-impl-guide.md#${agency.guideAnchor}`,
        eta:
          response.headers.get("X-Real-Implementation-ETA") ||
          "contract-pending",
        timestamp: new Date().toISOString(),
      };

      setResults((prev) => ({ ...prev, [agency.key]: result }));
    } catch (e) {
      const result: AgencyResult = {
        agency: agency.key,
        status: 0,
        body: null,
        notImplemented: true,
        agencyName: agency.label,
        guideRef: `docs/ops/integration-real-impl-guide.md#${agency.guideAnchor}`,
        eta: "contract-pending",
        error: e instanceof Error ? e.message : "호출 실패",
        timestamp: new Date().toISOString(),
      };
      setResults((prev) => ({ ...prev, [agency.key]: result }));
    } finally {
      setLoading((prev) => ({ ...prev, [agency.key]: false }));
    }
  };

  return (
    <div className="space-y-6">
      {/* 3 Agency 카드 */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        {AGENCIES.map((agency) => {
          const colors = colorMap[agency.color];
          const isLoading = loading[agency.key] ?? false;
          const result = results[agency.key];

          return (
            <div
              key={agency.key}
              className={`bg-white dark:bg-gray-800 rounded-xl border ${colors.border} ${colors.hover}
                hover:shadow-md transition-all p-5 flex flex-col gap-4 group`}
            >
              <div>
                <h3
                  className={`font-semibold text-gray-900 dark:text-white ${colors.heading} transition-colors`}
                >
                  {agency.label}
                </h3>
                <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
                  {agency.description}
                </p>
              </div>

              <button
                onClick={() => handleTest(agency)}
                disabled={isLoading}
                className={`w-full py-2 px-4 rounded-lg text-sm font-medium transition-colors ${colors.button} cursor-pointer`}
              >
                {isLoading ? "호출 중..." : "테스트 실행"}
              </button>

              {/* 결과 표시 */}
              {result && (
                <div className="space-y-2">
                  {/* Not Implemented 배너 */}
                  {result.notImplemented && (
                    <div className="rounded-md bg-yellow-50 border border-yellow-300 px-3 py-2 dark:bg-yellow-900/20 dark:border-yellow-700">
                      <p className="text-xs font-semibold text-yellow-800 dark:text-yellow-300">
                        ⚠️ Not Implemented — 모의 응답입니다 ({result.agencyName}{" "}
                        실 API 계약 대기)
                      </p>
                      <a
                        href={`#${agency.guideAnchor}`}
                        className="text-xs text-yellow-700 dark:text-yellow-400 underline hover:no-underline"
                      >
                        가이드 보기 →{" "}
                        {result.guideRef.split("/").pop() ?? "guide"}
                      </a>
                    </div>
                  )}

                  {/* 에러 */}
                  {result.error ? (
                    <div className="rounded-md bg-red-50 border border-red-300 px-3 py-2 dark:bg-red-900/20">
                      <p className="text-xs text-red-700 dark:text-red-400">
                        오류: {result.error}
                      </p>
                    </div>
                  ) : null}

                  {/* 상태 */}
                  <div className="flex items-center justify-between text-xs text-gray-500">
                    <span>HTTP {result.status || "—"}</span>
                    <span className="font-mono">
                      {result.timestamp.slice(11, 19)} KST
                    </span>
                  </div>

                  {/* 응답 body — [Dummy] 프리픽스 */}
                  {result.body && !result.error && (
                    <div className="rounded-md bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-700 p-2">
                      <p className="text-xs font-mono text-gray-400 dark:text-gray-500 mb-1">
                        [Dummy] 응답:
                      </p>
                      <pre className="text-xs text-gray-700 dark:text-gray-300 overflow-x-auto whitespace-pre-wrap break-all">
                        {renderBodyWithMockWatermark(result.body)}
                      </pre>
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* 전체 결과 요약 */}
      {Object.keys(results).length > 0 && (
        <div className="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-5">
          <h2 className="font-semibold text-gray-900 dark:text-white mb-3">
            전체 호출 결과 요약
          </h2>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-gray-500 dark:text-gray-400 border-b border-gray-200 dark:border-gray-700">
                  <th className="pb-2 font-medium">기관</th>
                  <th className="pb-2 font-medium">HTTP</th>
                  <th className="pb-2 font-medium">Not Implemented</th>
                  <th className="pb-2 font-medium">ETA</th>
                  <th className="pb-2 font-medium">시각</th>
                </tr>
              </thead>
              <tbody>
                {AGENCIES.map((agency) => {
                  const r = results[agency.key];
                  if (!r) return null;
                  return (
                    <tr
                      key={agency.key}
                      className="border-b border-gray-100 dark:border-gray-700 last:border-0"
                    >
                      <td className="py-2 font-medium text-gray-900 dark:text-white">
                        {r.agencyName}
                      </td>
                      <td className="py-2">
                        <span
                          className={`px-2 py-0.5 rounded-full text-xs font-medium ${
                            r.status >= 200 && r.status < 300
                              ? "bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300"
                              : "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300"
                          }`}
                        >
                          {r.status || "ERR"}
                        </span>
                      </td>
                      <td className="py-2">
                        {r.notImplemented ? (
                          <span className="px-2 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300">
                            [Mock] true
                          </span>
                        ) : (
                          <span className="text-green-600 dark:text-green-400 text-xs">
                            운영 중
                          </span>
                        )}
                      </td>
                      <td className="py-2 text-xs text-gray-500">
                        {r.eta || "—"}
                      </td>
                      <td className="py-2 text-xs font-mono text-gray-500">
                        {r.timestamp.slice(11, 19)}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}

/**
 * 응답 body를 [Mock] 워터마크와 함께 렌더링.
 * not_implemented 및 mock_reason 필드는 강조.
 */
function renderBodyWithMockWatermark(body: unknown): string {
  const json = JSON.stringify(body, null, 2);
  // not_implemented, mock_reason 줄에 [Mock] 프리픽스 추가
  return json
    .split("\n")
    .map((line) => {
      if (
        line.includes('"not_implemented"') ||
        line.includes('"mock_reason"') ||
        line.includes('"guide_ref"')
      ) {
        return `[Mock] ${line}`;
      }
      return line;
    })
    .join("\n");
}
