package kr.ocr.intgr.controller

import jakarta.validation.Valid
import kr.ocr.intgr.dto.IDVerifyRequest
import kr.ocr.intgr.dto.IDVerifyResponse
import kr.ocr.intgr.dto.OcspRequest
import kr.ocr.intgr.dto.OcspResponse
import kr.ocr.intgr.dto.TSARequest
import kr.ocr.intgr.dto.TSAResponse
import org.apache.camel.ProducerTemplate
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
     * 응답: IDVerifyResponse (valid, match_score, agency_tx_id)
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
        return ResponseEntity.ok(result)
    }

    /**
     * POST /timestamp
     *
     * KISA TSA 타임스탬프 발급 (RFC 3161).
     * 요청: TSARequest (sha256, nonce?, req_cert_info?)
     * 응답: TSAResponse (token, serial_number, gen_time, policy_oid)
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
        return ResponseEntity.ok(result)
    }

    /**
     * POST /ocsp
     *
     * 인증서 OCSP 유효성 검증.
     * 요청: OcspRequest (issuer_cn, serial)
     * 응답: OcspResponse (status, this_update, next_update?, revoked_at?)
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
        return ResponseEntity.ok(result)
    }
}
