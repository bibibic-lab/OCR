package kr.ocr.intgr.controller

import jakarta.validation.Valid
import kr.ocr.intgr.dto.IDVerifyRequest
import kr.ocr.intgr.dto.IDVerifyResponse
import kr.ocr.intgr.dto.OcspRequest
import kr.ocr.intgr.dto.OcspResponse
import kr.ocr.intgr.dto.TSARequest
import kr.ocr.intgr.dto.TSAResponse
import kr.ocr.intgr.routes.IdVerifyRoute
import kr.ocr.intgr.routes.OcspRoute
import kr.ocr.intgr.routes.TsaRoute
import org.apache.camel.ProducerTemplate
import org.springframework.http.HttpHeaders
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

/**
 * Integration Hub REST 진입점.
 *
 * 모든 요청은 Apache Camel ProducerTemplate을 통해 direct: 채널로 위임.
 * 실제 외부 기관 호출 로직은 각 RouteBuilder에서 처리.
 *
 * POLICY-NI-01 Step 2 — API 응답 헤더:
 *   각 응답에 다음 헤더를 항상 포함:
 *     X-Not-Implemented: true
 *     X-Agency-Name: <기관명>
 *     X-Real-Implementation-ETA: contract-pending
 *     X-Guide-Ref: docs/ops/integration-real-impl-guide.md#<anchor>
 *   실 구현 전환 시 NOT_IMPLEMENTED 플래그 기반으로 헤더를 조건부로 제거.
 *
 * 보안 주의:
 *   - /verify/id-card: RRN은 로그에 절대 출력하지 않음 (routes에서도 prefix만)
 *   - Phase 2: JWT 인증 (upload-api 발급 서비스 토큰) 필요
 */
@RestController
@RequestMapping("/")
class IntegrationController(
    private val producerTemplate: ProducerTemplate,
) {

    /**
     * POST /verify/id-card
     *
     * 행안부 주민등록 진위확인 (MOIS 연계).
     * 요청: IDVerifyRequest (name, rrn, issue_date)
     * 응답: IDVerifyResponse (valid, match_score, agency_tx_id, not_implemented, mock_reason, guide_ref)
     *
     * POLICY-NI-01: X-Not-Implemented, X-Agency-Name, X-Guide-Ref 헤더 포함.
     */
    @PostMapping("/verify/id-card")
    fun verifyIdCard(
        @Valid @RequestBody request: IDVerifyRequest,
    ): ResponseEntity<IDVerifyResponse> {
        val result = producerTemplate.requestBody(
            "direct:verify-id-card",
            request,
            IDVerifyResponse::class.java,
        )
        val headers = notImplementedHeaders(
            agencyName = IdVerifyRoute.AGENCY_NAME,
            guideRef = IdVerifyRoute.GUIDE_REF,
            isNotImplemented = IdVerifyRoute.NOT_IMPLEMENTED,
        )
        return ResponseEntity.ok().headers(headers).body(result)
    }

    /**
     * POST /timestamp
     *
     * KISA TSA 타임스탬프 발급 (RFC 3161).
     * 요청: TSARequest (sha256, nonce?, req_cert_info?)
     * 응답: TSAResponse (token, serial_number, gen_time, policy_oid, not_implemented, mock_reason, guide_ref)
     *
     * POLICY-NI-01: X-Not-Implemented, X-Agency-Name, X-Guide-Ref 헤더 포함.
     */
    @PostMapping("/timestamp")
    fun timestamp(
        @Valid @RequestBody request: TSARequest,
    ): ResponseEntity<TSAResponse> {
        val result = producerTemplate.requestBody(
            "direct:timestamp",
            request,
            TSAResponse::class.java,
        )
        val headers = notImplementedHeaders(
            agencyName = TsaRoute.AGENCY_NAME,
            guideRef = TsaRoute.GUIDE_REF,
            isNotImplemented = TsaRoute.NOT_IMPLEMENTED,
        )
        return ResponseEntity.ok().headers(headers).body(result)
    }

    /**
     * POST /ocsp
     *
     * 인증서 OCSP 유효성 검증.
     * 요청: OcspRequest (issuer_cn, serial)
     * 응답: OcspResponse (status, this_update, next_update?, revoked_at?, not_implemented, mock_reason, guide_ref)
     *
     * POLICY-NI-01: X-Not-Implemented, X-Agency-Name, X-Guide-Ref 헤더 포함.
     */
    @PostMapping("/ocsp")
    fun ocsp(
        @Valid @RequestBody request: OcspRequest,
    ): ResponseEntity<OcspResponse> {
        val result = producerTemplate.requestBody(
            "direct:ocsp",
            request,
            OcspResponse::class.java,
        )
        val headers = notImplementedHeaders(
            agencyName = OcspRoute.AGENCY_NAME,
            guideRef = OcspRoute.GUIDE_REF,
            isNotImplemented = OcspRoute.NOT_IMPLEMENTED,
        )
        return ResponseEntity.ok().headers(headers).body(result)
    }

    /**
     * POLICY-NI-01 Step 2 헬퍼: Not Implemented HTTP 응답 헤더 생성.
     *
     * isNotImplemented=false 시 헤더를 추가하지 않아 배너 자동 제거.
     *
     * 주의: HTTP 헤더 값은 ASCII printable 문자(0x20~0x7E)만 허용 (RFC 7230).
     *   한글 등 비ASCII 문자는 percent-encode. ASCII 공백(0x20)은 그대로 유지.
     *   클라이언트는 X-Agency-Name, X-Guide-Ref를 URL-decode 후 표시.
     */
    private fun encodeNonAscii(value: String): String =
        value.toCharArray().joinToString("") { c ->
            if (c.code in 0x20..0x7E) c.toString()
            else java.net.URLEncoder.encode(c.toString(), "UTF-8")
        }

    private fun notImplementedHeaders(
        agencyName: String,
        guideRef: String,
        isNotImplemented: Boolean,
    ): HttpHeaders {
        val headers = HttpHeaders()
        if (isNotImplemented) {
            headers["X-Not-Implemented"] = "true"
            // 비ASCII 문자(한글 등)만 percent-encode (ASCII 공백 허용)
            headers["X-Agency-Name"] = encodeNonAscii(agencyName)
            headers["X-Real-Implementation-ETA"] = "contract-pending"
            headers["X-Guide-Ref"] = encodeNonAscii(guideRef)
        }
        return headers
    }
}
