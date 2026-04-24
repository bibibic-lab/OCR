package kr.ocr.intgr.routes

import kr.ocr.intgr.dto.TSARequest
import kr.ocr.intgr.dto.TSAResponse
import org.apache.camel.LoggingLevel
import org.apache.camel.builder.RouteBuilder
import org.apache.camel.model.dataformat.JsonLibrary
import org.slf4j.LoggerFactory
import org.springframework.stereotype.Component
import java.util.Base64

/**
 * [NOT_IMPLEMENTED] KISA TSA 타임스탬프 Camel Route (RFC 3161 준거).
 *
 * POLICY-NI-01 Step 1 — 코드 마커:
 *   NOT_IMPLEMENTED = true 플래그가 설정되어 있는 동안 이 Route는 더미 DER blob을 반환.
 *   실 KISA TSA 계정 발급 후 전환 체크리스트 실행.
 *
 * POLICY-EXT-01 — 외부연계 전면 더미:
 *   현재 반환 token은 실 RFC 3161 서명이 아닌 dummy blob.
 *   실 구현 가이드: docs/ops/integration-real-impl-guide.md#kisa-tsa-타임스탬프-rfc-3161
 *
 * 전환 트리거: KISA TSA test API 계정 발급 후
 * 전환 체크리스트:
 *   1. BouncyCastle TimeStampRequestGenerator로 실 RFC 3161 DER 요청 생성 코드 활성화
 *   2. OpenBao에 클라이언트 인증서 저장
 *   3. application.yml tsa.url → 실 KISA TSA 엔드포인트
 *   4. NOT_IMPLEMENTED = false
 *   5. TSAResponse.notImplemented 기본값 false 변경
 *
 * 흐름:
 *   direct:timestamp
 *     → NOT_IMPLEMENTED warn 로그
 *     → request transform (TSARequest → JSON Map)
 *     → Circuit Breaker
 *     → HTTP POST to {{ocr.integration.agencies.tsa.url}} [현재: mock]
 *     → response transform (Map → TSAResponse)
 *     → onFallback: 빈 타임스탬프 응답
 *
 * 소스 매핑:
 *   - DTO: kr.ocr.intgr.dto.TSARequest / TSAResponse
 *   - Mock: kr.ocr.intgr.mock.MockAgencyController#tsaMock
 *   - URL: application.yml#ocr.integration.agencies.tsa.url
 */
@Component
class TsaRoute : RouteBuilder() {

    companion object {
        /** POLICY-NI-01: 실 구현 전까지 true. 전환 시 false로 변경. */
        const val NOT_IMPLEMENTED = true
        const val AGENCY_NAME = "KISA TSA"
        const val GUIDE_ANCHOR = "kisa-tsa-타임스탬프-rfc-3161"
        const val GUIDE_REF = "docs/ops/integration-real-impl-guide.md#$GUIDE_ANCHOR"

        private val log = LoggerFactory.getLogger(TsaRoute::class.java)
    }

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
            // POLICY-NI-01 Step 1: NOT_IMPLEMENTED warn 로그 (Camel DSL — Exchange body 미변경)
            .log(LoggingLevel.WARN, "NOT_IMPLEMENTED: $AGENCY_NAME/timestamp — 더미 DER blob 반환 중. 실 RFC 3161 토큰 아님. 가이드: $GUIDE_REF")
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
