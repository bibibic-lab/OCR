/**
 * upload-api 타입 정의 및 fetch 클라이언트.
 * 서버 컴포넌트 / 클라이언트 컴포넌트 양쪽에서 사용 가능.
 *
 * 개발: kubectl -n dmz port-forward svc/upload-api 18080:80
 *       → NEXT_PUBLIC_UPLOAD_API_BASE=http://localhost:18080
 */

const API_BASE =
  process.env.NEXT_PUBLIC_UPLOAD_API_BASE || "http://localhost:18080";

// ──────────────────────────────────────────────────────────
// 타입
// ──────────────────────────────────────────────────────────

export type DocumentStatus =
  | "UPLOADED"
  | "OCR_RUNNING"
  | "OCR_DONE"
  | "OCR_FAILED";

export interface OcrItem {
  text: string;
  confidence: number;
  /** 4개 꼭짓점: [[x,y],[x,y],[x,y],[x,y]] */
  bbox: number[][];
}

export interface DocumentResult {
  id: string;
  status: DocumentStatus;
  engine?: string;
  langs?: string[];
  items?: OcrItem[];
  ocrFinishedAt?: string;
}

// ──────────────────────────────────────────────────────────
// API 함수
// ──────────────────────────────────────────────────────────

/**
 * 문서를 upload-api 로 업로드한다.
 * @returns `{ id, status }` — status 는 초기값("UPLOADED")
 */
export async function uploadDocument(
  file: File,
  token: string
): Promise<{ id: string; status: string }> {
  const fd = new FormData();
  fd.append("file", file);

  const res = await fetch(`${API_BASE}/documents`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: fd,
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`업로드 실패: HTTP ${res.status} ${body}`);
  }

  return res.json();
}

/**
 * 단건 문서 상태 조회.
 */
export async function getDocument(
  id: string,
  token: string
): Promise<DocumentResult> {
  const res = await fetch(`${API_BASE}/documents/${id}`, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    throw new Error(`조회 실패: HTTP ${res.status}`);
  }

  return res.json();
}

/**
 * OCR 완료(OCR_DONE / OCR_FAILED)까지 폴링한다.
 *
 * @param intervalMs 폴링 간격 (기본 1500ms)
 * @param timeoutMs  타임아웃 (기본 60000ms)
 */
export async function pollDocument(
  id: string,
  token: string,
  opts: { intervalMs?: number; timeoutMs?: number } = {}
): Promise<DocumentResult> {
  const intervalMs = opts.intervalMs ?? 1500;
  const timeoutMs = opts.timeoutMs ?? 60000;
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const doc = await getDocument(id, token);
    if (doc.status === "OCR_DONE" || doc.status === "OCR_FAILED") {
      return doc;
    }
    await new Promise<void>((r) => setTimeout(r, intervalMs));
  }

  throw new Error(`폴링 타임아웃: ${timeoutMs}ms 초과`);
}
