package kr.ocr.intgr.routes

import kr.ocr.intgr.dto.IDVerifyRequest
import kr.ocr.intgr.dto.IDVerifyResponse
import org.apache.camel.builder.RouteBuilder
import org.apache.camel.model.dataformat.JsonLibrary
import org.springframework.stereotype.Component

/**
 * 행안부 주민등록 진위확인 Camel Route.
 *
 * 흐름:
 *   direct:verify-id-card
 *     → request transform (OCR DTO → agency format)
 *     → Circuit Breaker (Resilience4j: 10 슬라이딩 윈도우, 50% 실패율로 OPEN)
 *     → HTTP POST to {{ocr.integration.agencies.id-verify.url}}
 *     → JSON unmarshal (agency response → Map)
 *     → response transform (Map → IDVerifyResponse)
 *     → onFallback: CIRCUIT_OPEN 기본 응답
 *
 * 운영 참고:
 *   - 실 행안부 API 연결 시 egress proxy URL로 교체 (Phase 2)
 *   - RRN은 HSM 암호화 후 전송 필요 (Phase 2)
 */
@Component
class IdVerifyRoute : RouteBuilder() {

    override fun configure() {
        // 글로벌 예외 처리 — 예기치 못한 오류 시 회로 차단 응답과 동일 포맷 반환
        onException(Exception::class.java)
            .handled(true)
            .log("IdVerify 오류: \${exception.message}")
            .process { ex ->
                ex.`in`.body = IDVerifyResponse(
                    valid = false,
                    matchScore = 0.0,
                    agencyTxId = "ERROR:${ex.exception?.javaClass?.simpleName ?: "UNKNOWN"}",
                )
            }

        from("direct:verify-id-card")
            .routeId("verify-id-card")
            .log("행안부 주민등록 진위확인 요청: name=\${body.name}")
            // OCR DTO → agency JSON Map
            .process { ex ->
                val req = ex.`in`.getBody(IDVerifyRequest::class.java)
                // RRN prefix only — suffix must not be logged (PII)
                val rrnPrefix = if (req.rrn.length >= 6) req.rrn.substring(0, 6) else req.rrn
                ex.`in`.body = mapOf(
                    "name" to req.name,
                    "rrn_prefix" to rrnPrefix,
                    "issued_at" to req.issueDate,
                )
                ex.`in`.setHeader("Content-Type", "application/json")
            }
            .marshal().json(JsonLibrary.Jackson)
            // Circuit Breaker (Resilience4j)
            .circuitBreaker()
                .resilience4jConfiguration()
                    .failureRateThreshold(50.0f)
                    .slidingWindowSize(10)
                    .waitDurationInOpenState(30)
                .end()
                .to("{{ocr.integration.agencies.id-verify.url}}?bridgeEndpoint=true&httpMethod=POST")
                .unmarshal().json(JsonLibrary.Jackson, Map::class.java)
                .process { ex ->
                    @Suppress("UNCHECKED_CAST")
                    val agencyResp = ex.`in`.getBody(Map::class.java) as Map<String, Any?>
                    ex.`in`.body = IDVerifyResponse(
                        valid = agencyResp["status"] == "OK",
                        matchScore = (agencyResp["score"] as? Number)?.toDouble() ?: 0.0,
                        agencyTxId = agencyResp["tx_id"] as? String ?: "",
                    )
                }
            .onFallback()
                .log("IdVerify Circuit Open — 기본 응답 반환")
                .process { ex ->
                    ex.`in`.body = IDVerifyResponse(
                        valid = false,
                        matchScore = 0.0,
                        agencyTxId = "CIRCUIT_OPEN",
                    )
                }
            .end()
    }
}
