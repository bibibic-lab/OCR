package kr.ocr.intgr.routes

import kr.ocr.intgr.dto.TSARequest
import kr.ocr.intgr.dto.TSAResponse
import org.apache.camel.builder.RouteBuilder
import org.apache.camel.model.dataformat.JsonLibrary
import org.springframework.stereotype.Component
import java.util.Base64

/**
 * KISA TSA 타임스탬프 Camel Route (RFC 3161 준거).
 *
 * 흐름:
 *   direct:timestamp
 *     → request transform (TSARequest → JSON Map)
 *     → Circuit Breaker
 *     → HTTP POST to {{ocr.integration.agencies.tsa.url}}
 *     → response transform (Map → TSAResponse)
 *     → onFallback: 빈 타임스탬프 응답
 *
 * Mock 응답:
 *   MockAgencyController가 dummy DER blob 반환.
 *   실 KISA TSA 연결 시 (Phase 2):
 *     - BouncyCastle TimeStampRequestGenerator로 RFC 3161 DER 요청 생성
 *     - 응답 TimeStampResponse 파싱 후 token 추출
 *     - Egress proxy 통과 필요
 */
@Component
class TsaRoute : RouteBuilder() {

    override fun configure() {
        onException(Exception::class.java)
            .handled(true)
            .log("TSA 오류: \${exception.message}")
            .process { ex ->
                ex.`in`.body = TSAResponse(
                    token = "",
                    serialNumber = "ERROR",
                    genTime = java.time.Instant.now().toString(),
                    policyOid = "",
                )
            }

        from("direct:timestamp")
            .routeId("tsa-timestamp")
            .log("KISA TSA 타임스탬프 요청: sha256=\${body.sha256}")
            .process { ex ->
                val req = ex.`in`.getBody(TSARequest::class.java)
                ex.`in`.body = mapOf(
                    "sha256" to req.sha256,
                    "nonce" to (req.nonce ?: ""),
                    "req_cert_info" to req.reqCertInfo,
                )
                ex.`in`.setHeader("Content-Type", "application/json")
            }
            .marshal().json(JsonLibrary.Jackson)
            .circuitBreaker()
                .resilience4jConfiguration()
                    .failureRateThreshold(50.0f)
                    .slidingWindowSize(10)
                    .waitDurationInOpenState(30)
                .end()
                .to("{{ocr.integration.agencies.tsa.url}}?bridgeEndpoint=true&httpMethod=POST")
                .unmarshal().json(JsonLibrary.Jackson, Map::class.java)
                .process { ex ->
                    @Suppress("UNCHECKED_CAST")
                    val resp = ex.`in`.getBody(Map::class.java) as Map<String, Any?>
                    ex.`in`.body = TSAResponse(
                        token = resp["token"] as? String ?: "",
                        serialNumber = resp["serial_number"] as? String ?: "",
                        genTime = resp["gen_time"] as? String ?: java.time.Instant.now().toString(),
                        policyOid = resp["policy_oid"] as? String ?: "",
                    )
                }
            .onFallback()
                .log("TSA Circuit Open — 빈 타임스탬프 응답 반환")
                .process { ex ->
                    ex.`in`.body = TSAResponse(
                        token = "",
                        serialNumber = "CIRCUIT_OPEN",
                        genTime = java.time.Instant.now().toString(),
                        policyOid = "",
                    )
                }
            .end()
    }
}
