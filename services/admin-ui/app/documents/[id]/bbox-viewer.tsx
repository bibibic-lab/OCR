"use client";

import { useEffect, useState } from "react";
import type { OcrItem } from "@/lib/api";
import { bboxToPointsStr, confidenceColor, bboxRect } from "@/lib/bbox";

// ──────────────────────────────────────────────────────────
// 타입
// ──────────────────────────────────────────────────────────

interface Props {
  documentId: string;
  items: OcrItem[];
  engine?: string;
  ocrFinishedAt?: string;
}

interface ImgDim {
  w: number;
  h: number;
}

// ──────────────────────────────────────────────────────────
// 헬퍼
// ──────────────────────────────────────────────────────────

function parseDim(raw: string | null): ImgDim | null {
  if (!raw) return null;
  const [w, h] = raw.split("x").map(Number);
  if (!w || !h || isNaN(w) || isNaN(h)) return null;
  return { w, h };
}

function confidenceLabel(conf: number): string {
  return `${(conf * 100).toFixed(1)}%`;
}

function confidenceBadgeCls(conf: number): string {
  if (conf >= 0.9) return "bg-green-100 text-green-800";
  if (conf >= 0.5) return "bg-yellow-100 text-yellow-800";
  return "bg-red-100 text-red-800";
}

// ──────────────────────────────────────────────────────────
// 메인 컴포넌트
// ──────────────────────────────────────────────────────────

export function BboxViewer({ documentId, items, engine, ocrFinishedAt }: Props) {
  const [dataUrl, setDataUrl] = useState<string | null>(null);
  const [dim, setDim] = useState<ImgDim | null>(null);
  const [activeIdx, setActiveIdx] = useState<number | null>(null);

  // sessionStorage에서 원본 이미지 dataURL + 크기 복원
  useEffect(() => {
    const url = sessionStorage.getItem(`doc:${documentId}:original`);
    const rawDim = sessionStorage.getItem(`doc:${documentId}:dim`);
    setDataUrl(url);
    setDim(parseDim(rawDim));
  }, [documentId]);

  const hasImage = !!dataUrl;

  // bbox가 없는 경우 early return
  if (!items || items.length === 0) {
    return (
      <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-6">
        <p className="text-gray-500 dark:text-gray-400 text-sm">
          인식된 텍스트 항목이 없습니다.
        </p>
      </div>
    );
  }

  const imgW = dim?.w ?? 800;
  const imgH = dim?.h ?? 600;

  return (
    <div className="space-y-6">
      {/* ── 메타 정보 ── */}
      <div className="flex flex-wrap gap-4 text-sm text-gray-600 dark:text-gray-400">
        {engine && (
          <span>
            엔진:{" "}
            <span className="font-mono font-medium text-gray-900 dark:text-gray-100">
              {engine}
            </span>
          </span>
        )}
        {ocrFinishedAt && (
          <span>
            완료:{" "}
            <span className="font-medium text-gray-900 dark:text-gray-100">
              {new Date(ocrFinishedAt).toLocaleString("ko-KR")}
            </span>
          </span>
        )}
        <span>
          인식 항목:{" "}
          <span className="font-medium text-gray-900 dark:text-gray-100">
            {items.length}건
          </span>
        </span>
      </div>

      {/* ── 이미지 + SVG 오버레이 ── */}
      <div className="rounded-xl border border-gray-200 dark:border-gray-700 overflow-auto bg-gray-50 dark:bg-gray-900 p-4">
        {hasImage ? (
          <div className="relative inline-block">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={dataUrl!}
              alt="원본 문서 이미지"
              style={{ display: "block", maxWidth: "100%" }}
              onLoad={(e) => {
                const el = e.currentTarget;
                if (!dim) setDim({ w: el.naturalWidth, h: el.naturalHeight });
              }}
            />
            <svg
              className="absolute inset-0 w-full h-full"
              viewBox={`0 0 ${imgW} ${imgH}`}
              aria-label="OCR 인식 영역 오버레이"
            >
              {items.map((item, i) => {
                const color = confidenceColor(item.confidence);
                const isActive = activeIdx === i;
                const rect = bboxRect(item.bbox);
                return (
                  <g
                    key={i}
                    className="cursor-pointer"
                    onClick={() => setActiveIdx(isActive ? null : i)}
                  >
                    <polygon
                      points={bboxToPointsStr(item.bbox)}
                      fill={isActive ? `${color}33` : "transparent"}
                      stroke={color}
                      strokeWidth={isActive ? 3 : 2}
                      strokeLinejoin="round"
                    />
                    {/* 신뢰도 낮은 항목 표시 라벨 */}
                    {item.confidence < 0.5 && (
                      <text
                        x={rect.x + rect.w / 2}
                        y={rect.y - 4}
                        textAnchor="middle"
                        fontSize="10"
                        fill={color}
                        fontWeight="bold"
                      >
                        !
                      </text>
                    )}
                    <title>
                      {item.text} ({confidenceLabel(item.confidence)})
                    </title>
                  </g>
                );
              })}
            </svg>
          </div>
        ) : (
          /* 이미지 없음 — bbox만 그리기 */
          <div>
            <p className="text-sm text-amber-600 dark:text-amber-400 mb-3">
              원본 이미지 없음 — 같은 세션에서 업로드한 경우에만 이미지가 표시됩니다.
            </p>
            <svg
              viewBox={`0 0 ${imgW} ${imgH}`}
              style={{ width: "100%", maxWidth: "800px", border: "1px solid #e5e7eb" }}
              className="rounded bg-white dark:bg-gray-800"
              aria-label="OCR 인식 영역 (이미지 없음)"
            >
              {items.map((item, i) => {
                const color = confidenceColor(item.confidence);
                const isActive = activeIdx === i;
                const center = {
                  x: bboxRect(item.bbox).x + bboxRect(item.bbox).w / 2,
                  y: bboxRect(item.bbox).y + bboxRect(item.bbox).h / 2,
                };
                return (
                  <g
                    key={i}
                    className="cursor-pointer"
                    onClick={() => setActiveIdx(isActive ? null : i)}
                  >
                    <polygon
                      points={bboxToPointsStr(item.bbox)}
                      fill={`${color}22`}
                      stroke={color}
                      strokeWidth={2}
                      strokeLinejoin="round"
                    />
                    <text
                      x={center.x}
                      y={center.y}
                      textAnchor="middle"
                      dominantBaseline="middle"
                      fontSize="12"
                      fill={color}
                    >
                      {item.text.slice(0, 20)}
                    </text>
                    <title>
                      {item.text} ({confidenceLabel(item.confidence)})
                    </title>
                  </g>
                );
              })}
            </svg>
          </div>
        )}
      </div>

      {/* ── 선택된 항목 상세 ── */}
      {activeIdx !== null && items[activeIdx] && (
        <div className="rounded-lg border border-blue-200 dark:border-blue-700 bg-blue-50 dark:bg-blue-900/20 p-4">
          <p className="text-sm font-semibold text-blue-800 dark:text-blue-200 mb-1">
            선택된 항목 #{activeIdx + 1}
          </p>
          <p className="text-base text-gray-900 dark:text-gray-100 font-medium mb-2">
            &ldquo;{items[activeIdx].text}&rdquo;
          </p>
          <span
            className={`inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold ${confidenceBadgeCls(items[activeIdx].confidence)}`}
          >
            신뢰도 {confidenceLabel(items[activeIdx].confidence)}
          </span>
        </div>
      )}

      {/* ── 접근성 테이블 ── */}
      <div className="rounded-xl border border-gray-200 dark:border-gray-700 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-gray-100 dark:bg-gray-800">
              <tr>
                <th className="px-4 py-2.5 text-left text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wider">
                  #
                </th>
                <th className="px-4 py-2.5 text-left text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wider">
                  텍스트
                </th>
                <th className="px-4 py-2.5 text-left text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wider">
                  신뢰도
                </th>
                <th className="px-4 py-2.5 text-left text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wider">
                  좌표 (x1,y1)
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-700 bg-white dark:bg-gray-900">
              {items.map((item, i) => (
                <tr
                  key={i}
                  className={`cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors ${activeIdx === i ? "bg-blue-50 dark:bg-blue-900/20" : ""}`}
                  onClick={() => setActiveIdx(activeIdx === i ? null : i)}
                  aria-selected={activeIdx === i}
                >
                  <td className="px-4 py-2 text-gray-400 font-mono text-xs">
                    {i + 1}
                  </td>
                  <td className="px-4 py-2 text-gray-900 dark:text-gray-100 max-w-[300px] truncate">
                    {item.text}
                  </td>
                  <td className="px-4 py-2">
                    <span
                      className={`inline-block px-2 py-0.5 rounded-full text-xs font-semibold ${confidenceBadgeCls(item.confidence)}`}
                    >
                      {confidenceLabel(item.confidence)}
                    </span>
                  </td>
                  <td className="px-4 py-2 text-gray-500 dark:text-gray-400 font-mono text-xs">
                    ({item.bbox[0]?.[0] ?? 0},{item.bbox[0]?.[1] ?? 0})
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
