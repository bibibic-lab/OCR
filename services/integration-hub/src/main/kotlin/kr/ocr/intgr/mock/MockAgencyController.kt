package kr.ocr.intgr.mock

import org.springframework.context.annotation.Profile
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RestController
import java.time.Instant
import java.util.Base64
import java.util.UUID

/**
 * Mock 외부 기관 컨트롤러 — dev/mock 프로파일 전용.
 *
 * 실제 외부 기관 API를 흉내내는 엔드포인트:
 *   - POST /mock/id-verify  : 행안부 주민등록 진위확인 모의
 *   - POST /mock/tsa        : KISA TSA 타임스탬프 모의
 *   - POST /mock/ocsp       : OCSP 검증 모의
 *
 * 결정론적 동작:
 *   - id-verify: name 길이 짝수 → OK, 홀수 → FAIL
 *   - tsa: 항상 dummy DER blob 반환
 *   - ocsp: 항상 "good" 반환
 *
 * 주의: production 프로파일("prod")에서는 이 컨트롤러가 로드되지 않음.
 */
@RestController
@Profile("mock")
class MockAgencyController {

    /**
     * 행안부 주민등록 진위확인 Mock.
     * 입력: { name, rrn_prefix, issued_at }
     * 출력: { status, score, tx_id }
     */
    @PostMapping("/mock/id-verify")
    fun idVerifyMock(@RequestBody body: Map<String, Any>): Map<String, Any> {
        val name = body["name"] as? String ?: ""
        val ok = name.length % 2 == 0
        return mapOf(
            "status" to if (ok) "OK" else "FAIL",
            "score" to if (ok) 0.95 else 0.12,
            "tx_id" to UUID.randomUUID().toString(),
        )
    }

    /**
     * KISA TSA 타임스탬프 Mock (RFC 3161 더미 응답).
     * 입력: { sha256, nonce, req_cert_info }
     * 출력: { token (Base64 DER), serial_number, gen_time, policy_oid }
     *
     * 주의: 반환 token은 실 RFC 3161 서명이 아닌 dummy blob.
     * Phase 2에서 BouncyCastle TimeStampResponse로 교체 예정.
     */
    @PostMapping("/mock/tsa")
    fun tsaMock(@RequestBody body: Map<String, Any>): Map<String, Any> {
        val sha256 = body["sha256"] as? String ?: ""
        // Dummy DER: SEQUENCE tag + length + sha256 bytes + mock sig
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
     * OCSP 인증서 유효성 검증 Mock.
     * 입력: { issuer_cn, serial }
     * 출력: { status, this_update, next_update }
     */
    @PostMapping("/mock/ocsp")
    fun ocspMock(@RequestBody body: Map<String, Any>): Map<String, Any> {
        return mapOf(
            "status" to "good",
            "this_update" to Instant.now().toString(),
            "next_update" to Instant.now().plusSeconds(3600).toString(),
        )
    }
}
