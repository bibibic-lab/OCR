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
  updatedAt?: string;
  updateCount?: number;
}

/** GET /documents 목록 항목 */
export interface DocumentListItem {
  id: string;
  filename: string;
  contentType: string;
  byteSize: number;
  status: DocumentStatus;
  uploadedAt: string;
  ocrFinishedAt?: string;
  updateCount: number;
  itemCount: number;
}

/** GET /documents 페이지 응답 */
export interface DocumentPage {
  content: DocumentListItem[];
  page: number;
  size: number;
  totalElements: number;
  totalPages: number;
  hasNext: boolean;
}

export interface ListDocumentsParams {
  page?: number;
  size?: number;
  status?: DocumentStatus | "";
  q?: string;
  sort?: string;
}

// ──────────────────────────────────────────────────────────
// API 함수
// ──────────────────────────────────────────────────────────

/**
 * 문서 목록 조회 (GET /documents).
 * 본인 소유 문서만 반환 (Phase 2에서 admin Role 타인 조회 지원 예정).
 */
export async function listDocuments(
  params: ListDocumentsParams,
  token: string
): Promise<DocumentPage> {
  const qs = new URLSearchParams();
  if (params.page !== undefined) qs.set("page", String(params.page));
  if (params.size !== undefined) qs.set("size", String(params.size));
  if (params.status) qs.set("status", params.status);
  if (params.q) qs.set("q", params.q);
  if (params.sort) qs.set("sort", params.sort);

  const url = `${API_BASE}/documents${qs.toString() ? "?" + qs.toString() : ""}`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });

  if (!res.ok) {
    throw new Error(`목록 조회 실패: HTTP ${res.status}`);
  }

  return res.json();
}

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
 * OCR 결과 items 전체 교체 (PUT /documents/{id}/items).
 *
 * @returns 업데이트된 DocumentResult (updatedAt, updateCount 포함)
 * @throws Error HTTP 비-200 시
 */
export async function updateDocumentItems(
  id: string,
  items: OcrItem[],
  token: string
): Promise<DocumentResult> {
  const res = await fetch(`${API_BASE}/documents/${id}/items`, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ items }),
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`수정 실패: HTTP ${res.status} ${body}`);
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
