package kr.ocr.intgr.routes

import kr.ocr.intgr.dto.OcspRequest
import kr.ocr.intgr.dto.OcspResponse
import org.apache.camel.LoggingLevel
import org.apache.camel.builder.RouteBuilder
import org.apache.camel.model.dataformat.JsonLibrary
import org.slf4j.LoggerFactory
import org.springframework.stereotype.Component

/**
 * [NOT_IMPLEMENTED] OCSP 인증서 유효성 검증 Camel Route.
 *
 * POLICY-NI-01 Step 1 — 코드 마커:
 *   NOT_IMPLEMENTED = true 플래그가 설정되어 있는 동안 이 Route는 더미 응답을 반환.
 *   실 KISA OCSP 서버 접근권 확보 후 전환 체크리스트 실행.
 *
 * POLICY-EXT-01 — 외부연계 전면 더미:
 *   현재 모든 호출은 MockAgencyController(/mock/ocsp)로 라우팅됨.
 *   실 구현 가이드: docs/ops/integration-real-impl-guide.md#ocsp-인증서-검증
 *
 * 전환 트리거: KISA OCSP 서버 접근권 및 클라이언트 인증서 발급 후
 * 전환 체크리스트:
 *   1. BouncyCastle OCSPReqBuilder 코드 활성화
 *   2. OpenBao에 클라이언트 인증서 저장
 *   3. application.yml ocsp.url → 실 KISA OCSP 서버
 *   4. NOT_IMPLEMENTED = false
 *   5. OcspResponse.notImplemented 기본값 false 변경
 *
 * 흐름:
 *   direct:ocsp
 *     → NOT_IMPLEMENTED warn 로그
 *     → request transform (OcspRequest → JSON Map)
 *     → Circuit Breaker
 *     → HTTP POST to {{ocr.integration.agencies.ocsp.url}} [현재: mock]
 *     → response transform (Map → OcspResponse)
 *     → onFallback: unknown 상태 응답
 *
 * 소스 매핑:
 *   - DTO: kr.ocr.intgr.dto.OcspRequest / OcspResponse
 *   - Mock: kr.ocr.intgr.mock.MockAgencyController#ocspMock
 *   - URL: application.yml#ocr.integration.agencies.ocsp.url
 */
@Component
class OcspRoute : RouteBuilder() {

    companion object {
        /** POLICY-NI-01: 실 구현 전까지 true. 전환 시 false로 변경. */
        const val NOT_IMPLEMENTED = true
        const val AGENCY_NAME = "KISA OCSP"
        const val GUIDE_ANCHOR = "ocsp-인증서-검증"
        const val GUIDE_REF = "docs/ops/integration-real-impl-guide.md#$GUIDE_ANCHOR"

        private val log = LoggerFactory.getLogger(OcspRoute::class.java)
    }

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
            // POLICY-NI-01 Step 1: NOT_IMPLEMENTED warn 로그 (Camel DSL — Exchange body 미변경)
            .log(LoggingLevel.WARN, "NOT_IMPLEMENTED: $AGENCY_NAME/ocsp — 더미 응답 반환 중. 실 OCSP 서버 연결 대기. 가이드: $GUIDE_REF")
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
