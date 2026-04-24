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
 *
 * POLICY-NI-01 / POLICY-EXT-01: 실 KISA OCSP 서버 계약 대기. 모든 응답은 더미.
 * - notImplemented: 항상 true (실 OCSP 서버 연결 전까지)
 * - mockReason: 미구현 사유
 * - guideRef: 전환 가이드 참조 anchor
 *
 * 전환 시: notImplemented=false 기본값 변경 + OcspRoute.NOT_IMPLEMENTED=false
 */
data class OcspResponse(
    val status: String,
    @JsonProperty("this_update")
    val thisUpdate: String,
    @JsonProperty("next_update")
    val nextUpdate: String? = null,
    @JsonProperty("revoked_at")
    val revokedAt: String? = null,
    // ── POLICY-NI-01 Step 2: Not Implemented body 필드 ──────────────────────
    @JsonProperty("not_implemented")
    val notImplemented: Boolean = true,
    @JsonProperty("mock_reason")
    val mockReason: String = "실 기관 API 계약 대기 — KISA OCSP 서버 접근권 확보 후 전환",
    @JsonProperty("guide_ref")
    val guideRef: String = "docs/ops/integration-real-impl-guide.md#ocsp-인증서-검증",
)
