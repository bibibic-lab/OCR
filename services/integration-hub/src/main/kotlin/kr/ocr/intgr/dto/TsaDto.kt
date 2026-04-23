package kr.ocr.intgr.dto

import com.fasterxml.jackson.annotation.JsonProperty

/**
 * KISA TSA 타임스탬프 요청 DTO (RFC 3161 준거).
 *
 * - sha256: 타임스탬프 대상 데이터의 SHA-256 hex digest
 * - nonce: 재생 공격 방지용 임의값 (64-bit hex, optional)
 * - reqCertInfo: 인증서 정보 포함 여부
 *
 * Phase 2: BouncyCastle TimeStampRequest 빌더로 실 RFC 3161 바이너리 생성 예정.
 * 현재 mock 응답은 DER-encoded dummy blob 반환.
 */
data class TSARequest(
    @field:jakarta.validation.constraints.NotBlank
    val sha256: String,

    val nonce: String? = null,

    @JsonProperty("req_cert_info")
    val reqCertInfo: Boolean = false,
)

/**
 * KISA TSA 응답 DTO.
 *
 * - token: Base64-encoded TimeStampToken (DER)
 * - serialNumber: TSA 발급 일련번호
 * - genTime: 타임스탬프 생성 시각 (ISO-8601)
 * - policyOid: 적용 TSA 정책 OID
 */
data class TSAResponse(
    val token: String,
    @JsonProperty("serial_number")
    val serialNumber: String,
    @JsonProperty("gen_time")
    val genTime: String,
    @JsonProperty("policy_oid")
    val policyOid: String,
)
