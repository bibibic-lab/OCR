/**
 * GET|POST /api/integration/[agency] — integration-hub 프록시 라우트.
 *
 * POLICY-NI-01 Step 3 — UI 배너:
 *   admin-ui → integration-hub 직접 호출 프록시.
 *   클라이언트는 이 API route를 통해 integration-hub 3 엔드포인트를 호출.
 *
 * agency 파라미터 → integration-hub 경로 매핑:
 *   id-verify  → POST /verify/id-card
 *   tsa        → POST /timestamp
 *   ocsp       → POST /ocsp
 *
 * integration-hub 응답의 X-Not-Implemented, X-Agency-Name, X-Guide-Ref 헤더를
 * 클라이언트까지 그대로 전달 (배너 렌더링에 사용).
 *
 * 네트워크 경로:
 *   브라우저 → /api/integration/[agency] (Next.js API route)
 *             → INTEGRATION_HUB_URL (클러스터 내부: integration-hub.processing.svc.cluster.local:8080)
 *
 * 인증: dev 모드에서 integration-hub은 JWT 검증 없음 (open).
 *       프로덕션 전환 시 Authorization 헤더 전달 필요 (TODO Phase 2).
 */
export const dynamic = "force-dynamic";

import { auth } from "@/auth";
import { NextRequest } from "next/server";

const INTEGRATION_HUB_BASE =
  process.env.INTEGRATION_HUB_URL ||
  "http://integration-hub.processing.svc.cluster.local:8080";

/** agency 파라미터 → integration-hub 엔드포인트 매핑 */
const AGENCY_PATH_MAP: Record<string, string> = {
  "id-verify": "/verify/id-card",
  tsa: "/timestamp",
  ocsp: "/ocsp",
};

/** agency 파라미터 → 더미 요청 body (테스트용 최솟값) */
const AGENCY_DUMMY_BODY: Record<string, object> = {
  "id-verify": { name: "홍길동", rrn: "9001011234567", issue_date: "20200315" },
  tsa: { sha256: "a".repeat(64) },
  ocsp: { issuer_cn: "KISA-RootCA-G1", serial: "0123456789abcdef" },
};

export async function POST(
  request: NextRequest,
  { params }: { params: { agency: string } }
) {
  // 세션 인증 검사
  const session = await auth();
  if (!session?.accessToken) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const agency = params.agency;
  const hubPath = AGENCY_PATH_MAP[agency];
  if (!hubPath) {
    return new Response(JSON.stringify({ error: `Unknown agency: ${agency}` }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  // 요청 body: 클라이언트가 보내거나 없으면 더미 body 사용
  let reqBody: object;
  try {
    const text = await request.text();
    reqBody = text ? JSON.parse(text) : (AGENCY_DUMMY_BODY[agency] ?? {});
  } catch {
    reqBody = AGENCY_DUMMY_BODY[agency] ?? {};
  }

  const hubUrl = `${INTEGRATION_HUB_BASE}${hubPath}`;

  let hubResponse: Response;
  try {
    hubResponse = await fetch(hubUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(reqBody),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : "integration-hub 연결 실패";
    return new Response(
      JSON.stringify({ error: msg, agency, hubUrl }),
      {
        status: 502,
        headers: { "Content-Type": "application/json" },
      }
    );
  }

  // integration-hub 응답 body + POLICY-NI-01 헤더 전달
  const body = await hubResponse.text();

  // 클라이언트에 전달할 헤더 목록 (X-Not-Implemented 등)
  const responseHeaders: Record<string, string> = {
    "Content-Type": "application/json",
  };
  const policyHeaders = [
    "X-Not-Implemented",
    "X-Agency-Name",
    "X-Real-Implementation-ETA",
    "X-Guide-Ref",
  ];
  for (const h of policyHeaders) {
    const val = hubResponse.headers.get(h);
    if (val) responseHeaders[h] = val;
  }

  return new Response(body, {
    status: hubResponse.status,
    headers: responseHeaders,
  });
}
