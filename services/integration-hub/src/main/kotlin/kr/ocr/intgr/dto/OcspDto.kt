package kr.ocr.intgr.dto

import com.fasterxml.jackson.annotation.JsonProperty

/**
 * OCSP 인증서 유효성 검증 요청 DTO.
 *
 * - issuerCn: 발급 CA의 Common Name
 * - serial: 검증 대상 인증서 일련번호 (hex)
 *
 * Phase 2: BouncyCastle OCSPReqBuilder로 실 OCSP 바이너리 요청 생성 예정.
 */
data class OcspRequest(
    @JsonProperty("issuer_cn")
    @field:jakarta.validation.constraints.NotBlank
    val issuerCn: String,

    @field:jakarta.validation.constraints.NotBlank
    val serial: String,
)

/**
 * OCSP 응답 DTO.
 *
 * - status: "good" | "revoked" | "unknown"
 * - thisUpdate: OCSP 응답 생성 시각 (ISO-8601)
 * - nextUpdate: 다음 갱신 권장 시각 (ISO-8601, nullable)
 * - revokedAt: 폐기 시각 (status=="revoked" 일 때만)
 */
data class OcspResponse(
    val status: String,
    @JsonProperty("this_update")
    val thisUpdate: String,
    @JsonProperty("next_update")
    val nextUpdate: String? = null,
    @JsonProperty("revoked_at")
    val revokedAt: String? = null,
)
