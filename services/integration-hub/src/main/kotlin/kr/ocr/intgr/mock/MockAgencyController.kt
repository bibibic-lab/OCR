package kr.ocr.intgr.mock

import org.slf4j.LoggerFactory
import org.springframework.context.annotation.Profile
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RestController
import java.time.Instant
import java.util.Base64
import java.util.UUID

/**
 * [NOT_IMPLEMENTED] Mock 외부 기관 컨트롤러 — dev/mock 프로파일 전용.
 *
 * POLICY-NI-01 Step 1 — 코드 마커:
 *   이 클래스는 POLICY-EXT-01에 따라 외부 기관 API를 전면 더미로 대체함.
 *   실 API 계약 체결 전까지 모든 응답은 결정론적 더미값.
 *
 * POLICY-EXT-01 — 외부연계 전면 더미:
 *   실 구현 가이드: docs/ops/integration-real-impl-guide.md
 *
 * 실제 외부 기관 API를 흉내내는 엔드포인트:
 *   - POST /mock/id-verify  : 행안부 주민등록 진위확인 모의
 *     → 실 전환: docs/ops/integration-real-impl-guide.md#행안부-주민등록-진위확인
 *   - POST /mock/tsa        : KISA TSA 타임스탬프 모의 (dummy DER blob)
 *     → 실 전환: docs/ops/integration-real-impl-guide.md#kisa-tsa-타임스탬프-rfc-3161
 *   - POST /mock/ocsp       : OCSP 검증 모의
 *     → 실 전환: docs/ops/integration-real-impl-guide.md#ocsp-인증서-검증
 *
 * 결정론적 동작:
 *   - id-verify: name 길이 짝수 → OK, 홀수 → FAIL
 *   - tsa: 항상 dummy DER blob 반환 (실 RFC 3161 서명 아님)
 *   - ocsp: 항상 "good" 반환
 *
 * 주의: production 프로파일("prod")에서는 이 컨트롤러가 로드되지 않음.
 */
@RestController
@Profile("mock")
class MockAgencyController {

    companion object {
        private val log = LoggerFactory.getLogger(MockAgencyController::class.java)
        const val GUIDE_BASE = "docs/ops/integration-real-impl-guide.md"
    }

    /**
     * [NOT_IMPLEMENTED] 행안부 주민등록 진위확인 Mock.
     *
     * POLICY-EXT-01: 이 응답은 더미값. 실 행안부 API 계약 체결 전까지 사용.
     * 실 전환 가이드: $GUIDE_BASE#행안부-주민등록-진위확인
     *
     * 입력: { name, rrn_prefix, issued_at }
     * 출력: { status, score, tx_id }
     */
    @PostMapping("/mock/id-verify")
    fun idVerifyMock(@RequestBody body: Map<String, Any>): Map<String, Any> {
        log.warn(
            "NOT_IMPLEMENTED: MockAgencyController#idVerifyMock — 행안부 진위확인 더미 응답. 가이드: {}#행안부-주민등록-진위확인",
            GUIDE_BASE
        )
        val name = body["name"] as? String ?: ""
        val ok = name.length % 2 == 0
        return mapOf(
            "status" to if (ok) "OK" else "FAIL",
            "score" to if (ok) 0.95 else 0.12,
            "tx_id" to UUID.randomUUID().toString(),
        )
    }

    /**
     * [NOT_IMPLEMENTED] KISA TSA 타임스탬프 Mock (RFC 3161 더미 응답).
     *
     * POLICY-EXT-01: 반환 token은 실 RFC 3161 서명이 아닌 dummy blob.
     * 실 전환 가이드: $GUIDE_BASE#kisa-tsa-타임스탬프-rfc-3161
     *
     * 입력: { sha256, nonce, req_cert_info }
     * 출력: { token (Base64 DER dummy), serial_number, gen_time, policy_oid }
     */
    @PostMapping("/mock/tsa")
    fun tsaMock(@RequestBody body: Map<String, Any>): Map<String, Any> {
        log.warn(
            "NOT_IMPLEMENTED: MockAgencyController#tsaMock — KISA TSA 더미 DER blob 반환. 실 RFC 3161 토큰 아님. 가이드: {}#kisa-tsa-타임스탬프-rfc-3161",
            GUIDE_BASE
        )
        val sha256 = body["sha256"] as? String ?: ""
        // Dummy DER: SEQUENCE tag + length + sha256 bytes + mock sig
        // Phase 2: BouncyCastle TimeStampRequestGenerator로 실 RFC 3161 DER 생성으로 교체
        val dummyDer = byteArrayOf(0x30, 0x16.toByte()) +
            sha256.toByteArray(Charsets.UTF_8).take(16).toByteArray() +
            "MOCK_TSA_SIG".toByteArray(Charsets.UTF_8)
        val tokenB64 = Base64.getEncoder().encodeToString(dummyDer)
        return mapOf(
            "token" to tokenB64,
            "serial_number" to UUID.randomUUID().toString().replace("-", "").take(16),
            "gen_time" to Instant.now().toString(),
            "policy_oid" to "1.2.410.200001.1",  // KISA TSA 정책 OID (mock)
        )
    }

    /**
     * [NOT_IMPLEMENTED] OCSP 인증서 유효성 검증 Mock.
     *
     * POLICY-EXT-01: 이 응답은 더미값. 실 KISA OCSP 서버 접근권 확보 전까지 사용.
     * 실 전환 가이드: $GUIDE_BASE#ocsp-인증서-검증
     *
     * 입력: { issuer_cn, serial }
     * 출력: { status, this_update, next_update }
     */
    @PostMapping("/mock/ocsp")
    fun ocspMock(@RequestBody body: Map<String, Any>): Map<String, Any> {
        log.warn(
            "NOT_IMPLEMENTED: MockAgencyController#ocspMock — OCSP 더미 응답(always good). 가이드: {}#ocsp-인증서-검증",
            GUIDE_BASE
        )
        return mapOf(
            "status" to "good",
            "this_update" to Instant.now().toString(),
            "next_update" to Instant.now().plusSeconds(3600).toString(),
        )
    }
}
