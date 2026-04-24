/**
 * GET /api/stats — 서버사이드 프록시 라우트.
 *
 * 클라이언트 컴포넌트(stats-cards.tsx)의 30초 자동 갱신에서 호출.
 * auth() 세션에서 accessToken 을 추출해 upload-api GET /documents/stats 에 전달.
 */
export const dynamic = "force-dynamic";

import { auth } from "@/auth";
import { getStats } from "@/lib/api";

export async function GET() {
  const session = await auth();
  if (!session?.accessToken) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const stats = await getStats(session.accessToken);
    return Response.json(stats);
  } catch (e) {
    const message = e instanceof Error ? e.message : "통계 조회 실패";
    return new Response(JSON.stringify({ error: message }), {
      status: 502,
      headers: { "Content-Type": "application/json" },
    });
  }
}
