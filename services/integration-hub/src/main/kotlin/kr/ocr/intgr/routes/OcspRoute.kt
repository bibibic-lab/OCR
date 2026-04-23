package kr.ocr.intgr.routes

import kr.ocr.intgr.dto.OcspRequest
import kr.ocr.intgr.dto.OcspResponse
import org.apache.camel.builder.RouteBuilder
import org.apache.camel.model.dataformat.JsonLibrary
import org.springframework.stereotype.Component

/**
 * OCSP 인증서 유효성 검증 Camel Route.
 *
 * 흐름:
 *   direct:ocsp
 *     → request transform (OcspRequest → JSON Map)
 *     → Circuit Breaker
 *     → HTTP POST to {{ocr.integration.agencies.ocsp.url}}
 *     → response transform (Map → OcspResponse)
 *     → onFallback: unknown 상태 응답
 *
 * Phase 2:
 *   - BouncyCastle OCSPReqBuilder로 실 OCSP 바이너리 요청 생성
 *   - KISA OCSP 서버 URL 적용 (egress proxy 통과)
 *   - mTLS 클라이언트 인증서 설정
 */
@Component
class OcspRoute : RouteBuilder() {

    override fun configure() {
        onException(Exception::class.java)
            .handled(true)
            .log("OCSP 오류: \${exception.message}")
            .process { ex ->
                ex.`in`.body = OcspResponse(
                    status = "unknown",
                    thisUpdate = java.time.Instant.now().toString(),
                )
            }

        from("direct:ocsp")
            .routeId("ocsp-validate")
            .log("OCSP 검증 요청: issuer=\${body.issuerCn}, serial=\${body.serial}")
            .process { ex ->
                val req = ex.`in`.getBody(OcspRequest::class.java)
                ex.`in`.body = mapOf(
                    "issuer_cn" to req.issuerCn,
                    "serial" to req.serial,
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
                .to("{{ocr.integration.agencies.ocsp.url}}?bridgeEndpoint=true&httpMethod=POST")
                .unmarshal().json(JsonLibrary.Jackson, Map::class.java)
                .process { ex ->
                    @Suppress("UNCHECKED_CAST")
                    val resp = ex.`in`.getBody(Map::class.java) as Map<String, Any?>
                    ex.`in`.body = OcspResponse(
                        status = resp["status"] as? String ?: "unknown",
                        thisUpdate = resp["this_update"] as? String ?: java.time.Instant.now().toString(),
                        nextUpdate = resp["next_update"] as? String,
                        revokedAt = resp["revoked_at"] as? String,
                    )
                }
            .onFallback()
                .log("OCSP Circuit Open — unknown 상태 반환")
                .process { ex ->
                    ex.`in`.body = OcspResponse(
                        status = "unknown",
                        thisUpdate = java.time.Instant.now().toString(),
                    )
                }
            .end()
    }
}
