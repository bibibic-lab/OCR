import type { DocumentStatus } from "@/lib/api";

const COLORS: Record<DocumentStatus, string> = {
  UPLOADED: "bg-gray-200 text-gray-800",
  OCR_RUNNING: "bg-blue-200 text-blue-900 animate-pulse",
  OCR_DONE: "bg-green-200 text-green-900",
  OCR_FAILED: "bg-red-200 text-red-900",
};

const LABELS: Record<DocumentStatus, string> = {
  UPLOADED: "업로드됨",
  OCR_RUNNING: "OCR 처리 중",
  OCR_DONE: "OCR 완료",
  OCR_FAILED: "OCR 실패",
};

export function StatusBadge({ status }: { status: DocumentStatus }) {
  return (
    <span
      className={`inline-block px-3 py-1 rounded-full text-sm font-medium ${COLORS[status]}`}
    >
      {LABELS[status]}
    </span>
  );
}
