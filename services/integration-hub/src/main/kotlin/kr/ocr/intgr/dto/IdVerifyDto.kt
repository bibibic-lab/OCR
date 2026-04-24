package kr.ocr.intgr.dto

import com.fasterxml.jackson.annotation.JsonProperty
import jakarta.validation.constraints.NotBlank

/**
 * 행안부 주민등록 진위확인 요청 DTO.
 *
 * 실제 MOIS API spec (행안부 API 표준 v2.3) 기준:
 *   - name: 성명 (최대 50자)
 *   - rrn: 주민등록번호 13자리 (전송 구간 암호화 필수 — Phase 2 HSM 구간에서 적용)
 *   - issueDate: 발급일자 (YYYYMMDD)
 */
data class IDVerifyRequest(
    @field:NotBlank
    val name: String,

    @field:NotBlank
    val rrn: String,

    @JsonProperty("issue_date")
    @field:NotBlank
    val issueDate: String,
)

/**
 * 행안부 주민등록 진위확인 응답 DTO.
 *
 * - valid: 진위확인 결과
 * - matchScore: 유사도 점수 (0.0~1.0)
 * - agencyTxId: 행안부 트랜잭션 ID (감사 로그용)
 *
 * POLICY-NI-01 / POLICY-EXT-01: 실 API 계약 대기. 모든 응답은 더미.
 * - notImplemented: 항상 true (실 API 연결 전까지)
 * - mockReason: 미구현 사유
 * - guideRef: 전환 가이드 참조 anchor
 *
 * 전환 시: notImplemented=false 기본값 변경 + IdVerifyRoute.NOT_IMPLEMENTED=false
 */
data class IDVerifyResponse(
    val valid: Boolean,
    val matchScore: Double,
    @JsonProperty("agency_tx_id")
    val agencyTxId: String,
    // ── POLICY-NI-01 Step 2: Not Implemented body 필드 ──────────────────────
    @JsonProperty("not_implemented")
    val notImplemented: Boolean = true,
    @JsonProperty("mock_reason")
    val mockReason: String = "실 기관 API 계약 대기",
    @JsonProperty("guide_ref")
    val guideRef: String = "docs/ops/integration-real-impl-guide.md#행안부-주민등록-진위확인",
)
