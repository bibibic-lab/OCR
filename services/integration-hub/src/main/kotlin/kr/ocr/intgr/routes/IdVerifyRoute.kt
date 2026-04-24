package kr.ocr.intgr.routes

import kr.ocr.intgr.dto.IDVerifyRequest
import kr.ocr.intgr.dto.IDVerifyResponse
import org.apache.camel.LoggingLevel
import org.apache.camel.builder.RouteBuilder
import org.apache.camel.model.dataformat.JsonLibrary
import org.slf4j.LoggerFactory
import org.springframework.stereotype.Component

/**
 * [NOT_IMPLEMENTED] 행안부 주민등록 진위확인 Camel Route.
 *
 * POLICY-NI-01 Step 1 — 코드 마커:
 *   NOT_IMPLEMENTED = true 플래그가 설정되어 있는 동안 이 Route는 더미 응답을 반환.
 *   실 행안부 API 계약 체결 후 전환 체크리스트 실행.
 *
 * POLICY-EXT-01 — 외부연계 전면 더미:
 *   현재 모든 호출은 MockAgencyController(/mock/id-verify)로 라우팅됨.
 *   실 구현 가이드: docs/ops/integration-real-impl-guide.md#행안부-주민등록-진위확인
 *
 * 전환 트리거: 행안부 test API 계정 발급 후
 * 전환 체크리스트:
 *   1. OpenBao에 클라이언트 인증서·키 저장
 *   2. application.yml id-verify.url → 실 엔드포인트
 *   3. NOT_IMPLEMENTED = false
 *   4. IDVerifyResponse.notImplemented 기본값 false 변경
 *   5. admin-ui 배너 자동 제거 확인
 *
 * 흐름:
 *   direct:verify-id-card
 *     → NOT_IMPLEMENTED warn 로그
 *     → request transform (OCR DTO → agency format)
 *     → Circuit Breaker (Resilience4j: 10 슬라이딩 윈도우, 50% 실패율로 OPEN)
 *     → HTTP POST to {{ocr.integration.agencies.id-verify.url}} [현재: mock]
 *     → JSON unmarshal (agency response → Map)
 *     → response transform (Map → IDVerifyResponse)
 *     → onFallback: CIRCUIT_OPEN 기본 응답
 *
 * 소스 매핑:
 *   - DTO: kr.ocr.intgr.dto.IDVerifyRequest / IDVerifyResponse
 *   - Mock: kr.ocr.intgr.mock.MockAgencyController#idVerifyMock
 *   - URL: application.yml#ocr.integration.agencies.id-verify.url
 */
@Component
class IdVerifyRoute : RouteBuilder() {

    companion object {
        /** POLICY-NI-01: 실 구현 전까지 true. 전환 시 false로 변경. */
        const val NOT_IMPLEMENTED = true
        const val AGENCY_NAME = "행안부"
        const val GUIDE_ANCHOR = "행안부-주민등록-진위확인"
        const val GUIDE_REF = "docs/ops/integration-real-impl-guide.md#$GUIDE_ANCHOR"

        private val log = LoggerFactory.getLogger(IdVerifyRoute::class.java)
    }

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
            // POLICY-NI-01 Step 1: NOT_IMPLEMENTED warn 로그 (Camel DSL — Exchange body 미변경)
            .log(LoggingLevel.WARN, "NOT_IMPLEMENTED: $AGENCY_NAME/verify-id-card — 더미 응답 반환 중. 실 API 계약 대기. 가이드: $GUIDE_REF")
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
