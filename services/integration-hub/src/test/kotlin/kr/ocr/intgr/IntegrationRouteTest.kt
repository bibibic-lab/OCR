package kr.ocr.intgr

import com.fasterxml.jackson.databind.ObjectMapper
import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.WireMock
import com.github.tomakehurst.wiremock.core.WireMockConfiguration
import kr.ocr.intgr.dto.IDVerifyRequest
import kr.ocr.intgr.dto.IDVerifyResponse
import kr.ocr.intgr.dto.OcspRequest
import kr.ocr.intgr.dto.OcspResponse
import kr.ocr.intgr.dto.TSARequest
import kr.ocr.intgr.dto.TSAResponse
import org.apache.camel.CamelContext
import org.apache.camel.ProducerTemplate
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.web.client.TestRestTemplate
import org.springframework.http.HttpEntity
import org.springframework.http.HttpMethod
import org.springframework.http.MediaType
import org.springframework.http.HttpHeaders
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.context.DynamicPropertyRegistry
import org.springframework.test.context.DynamicPropertySource

/**
 * Integration Hub Camel Route 통합 테스트.
 *
 * WireMock을 companion object init 블록에서 시작하여
 * @DynamicPropertySource 호출 시점에 port가 확정되도록 보장.
 *
 * 테스트 시나리오:
 *   1. IdVerify OK → valid=true
 *   2. IdVerify FAIL → valid=false
 *   3. IdVerify 서버 오류 → onException fallback
 *   4. TSA 정상 → token/serialNumber 검증
 *   5. OCSP good → status="good"
 *   6. OCSP revoked → status="revoked" + revokedAt
 *   7. Camel Route 등록 확인
 *   8. POLICY-NI-01 Step 2: 응답 헤더 X-Not-Implemented=true 검증 (3 엔드포인트)
 *   9. POLICY-NI-01 Step 2: 응답 body notImplemented=true 검증 (3 엔드포인트)
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ActiveProfiles("test")
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class IntegrationRouteTest {

    @Autowired
    private lateinit var restTemplate: TestRestTemplate

    @Autowired
    private lateinit var objectMapper: ObjectMapper

    companion object {
        // WireMock을 companion object 초기화 시점에 시작 → DynamicPropertySource 전에 port 확정
        val wireMockServer: WireMockServer = WireMockServer(
            WireMockConfiguration.wireMockConfig().dynamicPort()
        ).also { it.start() }

        @JvmStatic
        @AfterAll
        fun stopWireMock() {
            wireMockServer.stop()
        }

        @JvmStatic
        @DynamicPropertySource
        fun wireMockProperties(registry: DynamicPropertyRegistry) {
            registry.add("ocr.integration.agencies.id-verify.url") {
                "http://localhost:${wireMockServer.port()}/stub/id-verify"
            }
            registry.add("ocr.integration.agencies.tsa.url") {
                "http://localhost:${wireMockServer.port()}/stub/tsa"
            }
            registry.add("ocr.integration.agencies.ocsp.url") {
                "http://localhost:${wireMockServer.port()}/stub/ocsp"
            }
        }
    }

    @Autowired
    private lateinit var producerTemplate: ProducerTemplate

    @Autowired
    private lateinit var camelContext: CamelContext

    // ── IdVerify ──────────────────────────────────────────────────────────────

    @Test
    fun `IdVerify - 정상 응답 (agency OK)`() {
        wireMockServer.stubFor(
            WireMock.post(WireMock.urlEqualTo("/stub/id-verify"))
                .willReturn(
                    WireMock.aResponse()
                        .withHeader("Content-Type", "application/json")
                        .withBody("""{"status":"OK","score":0.95,"tx_id":"test-tx-001"}""")
                )
        )

        val req = IDVerifyRequest(name = "홍길동", rrn = "9001011234567", issueDate = "20200315")
        val resp = producerTemplate.requestBody("direct:verify-id-card", req, IDVerifyResponse::class.java)

        assertTrue(resp.valid, "valid should be true when agency returns OK")
        assertEquals(0.95, resp.matchScore, 0.001)
        assertEquals("test-tx-001", resp.agencyTxId)
    }

    @Test
    fun `IdVerify - 기관 응답 FAIL → valid=false`() {
        wireMockServer.stubFor(
            WireMock.post(WireMock.urlEqualTo("/stub/id-verify"))
                .willReturn(
                    WireMock.aResponse()
                        .withHeader("Content-Type", "application/json")
                        .withBody("""{"status":"FAIL","score":0.12,"tx_id":"test-tx-002"}""")
                )
        )

        val req = IDVerifyRequest(name = "테스트", rrn = "9001011234567", issueDate = "20200315")
        val resp = producerTemplate.requestBody("direct:verify-id-card", req, IDVerifyResponse::class.java)

        assertFalse(resp.valid, "valid should be false when agency returns FAIL")
        assertEquals(0.12, resp.matchScore, 0.001)
    }

    @Test
    fun `IdVerify - 기관 서버 오류 → fallback 응답`() {
        wireMockServer.stubFor(
            WireMock.post(WireMock.urlEqualTo("/stub/id-verify"))
                .willReturn(WireMock.aResponse().withStatus(500).withBody("Internal Server Error"))
        )

        val req = IDVerifyRequest(name = "오류테스트", rrn = "9001011234567", issueDate = "20200315")
        val resp = producerTemplate.requestBody("direct:verify-id-card", req, IDVerifyResponse::class.java)

        assertFalse(resp.valid, "On error, valid should be false")
    }

    // ── TSA ───────────────────────────────────────────────────────────────────

    @Test
    fun `TSA - 정상 응답 (dummy token 반환)`() {
        wireMockServer.stubFor(
            WireMock.post(WireMock.urlEqualTo("/stub/tsa"))
                .willReturn(
                    WireMock.aResponse()
                        .withHeader("Content-Type", "application/json")
                        .withBody(
                            """{"token":"dGVzdA==","serial_number":"ABC123","gen_time":"2026-04-22T00:00:00Z","policy_oid":"1.2.410.200001.1"}"""
                        )
                )
        )

        val req = TSARequest(sha256 = "a".repeat(64))
        val resp = producerTemplate.requestBody("direct:timestamp", req, TSAResponse::class.java)

        assertEquals("dGVzdA==", resp.token)
        assertEquals("ABC123", resp.serialNumber)
        assertEquals("1.2.410.200001.1", resp.policyOid)
    }

    // ── OCSP ──────────────────────────────────────────────────────────────────

    @Test
    fun `OCSP - 정상 응답 (good status)`() {
        wireMockServer.stubFor(
            WireMock.post(WireMock.urlEqualTo("/stub/ocsp"))
                .willReturn(
                    WireMock.aResponse()
                        .withHeader("Content-Type", "application/json")
                        .withBody("""{"status":"good","this_update":"2026-04-22T00:00:00Z","next_update":"2026-04-22T01:00:00Z"}""")
                )
        )

        val req = OcspRequest(issuerCn = "KISA-RootCA-G1", serial = "0123456789abcdef")
        val resp = producerTemplate.requestBody("direct:ocsp", req, OcspResponse::class.java)

        assertEquals("good", resp.status)
    }

    @Test
    fun `OCSP - 폐기 인증서 응답 (revoked status)`() {
        wireMockServer.stubFor(
            WireMock.post(WireMock.urlEqualTo("/stub/ocsp"))
                .willReturn(
                    WireMock.aResponse()
                        .withHeader("Content-Type", "application/json")
                        .withBody("""{"status":"revoked","this_update":"2026-04-22T00:00:00Z","revoked_at":"2026-01-01T00:00:00Z"}""")
                )
        )

        val req = OcspRequest(issuerCn = "TestCA", serial = "deadbeef")
        val resp = producerTemplate.requestBody("direct:ocsp", req, OcspResponse::class.java)

        assertEquals("revoked", resp.status)
        assertEquals("2026-01-01T00:00:00Z", resp.revokedAt)
    }

    // ── Route Registration ────────────────────────────────────────────────────

    @Test
    fun `Camel Routes - 3개 라우트 등록 확인`() {
        val routeIds = camelContext.routes.map { it.routeId }
        assertTrue(routeIds.contains("verify-id-card"), "verify-id-card route should be registered. Found: $routeIds")
        assertTrue(routeIds.contains("tsa-timestamp"), "tsa-timestamp route should be registered. Found: $routeIds")
        assertTrue(routeIds.contains("ocsp-validate"), "ocsp-validate route should be registered. Found: $routeIds")
    }

    // ── POLICY-NI-01 Step 2: 응답 헤더 + body notImplemented 검증 ─────────────

    @Test
    fun `POLICY-NI-01 - IdVerify 응답 헤더 X-Not-Implemented = true`() {
        wireMockServer.stubFor(
            WireMock.post(WireMock.urlEqualTo("/stub/id-verify"))
                .willReturn(
                    WireMock.aResponse()
                        .withHeader("Content-Type", "application/json")
                        .withBody("""{"status":"OK","score":0.95,"tx_id":"hdr-test-001"}""")
                )
        )

        val reqHeaders = HttpHeaders().apply { contentType = MediaType.APPLICATION_JSON }
        val body = mapOf("name" to "헤더검증", "rrn" to "9001011234567", "issue_date" to "20200315")
        val entity = HttpEntity(objectMapper.writeValueAsString(body), reqHeaders)

        val response = restTemplate.exchange("/verify/id-card", HttpMethod.POST, entity, String::class.java)

        assertEquals("true", response.headers["X-Not-Implemented"]?.firstOrNull(),
            "X-Not-Implemented 헤더가 'true'이어야 함 (POLICY-NI-01)")
        // X-Agency-Name은 URL-encoded (Tomcat RFC 7230 — 비ASCII 헤더 불허)
        // "행안부" → "%ED%96%89%EC%95%88%EB%B6%80" 인코딩됨 → 존재 여부만 검증
        assertTrue(response.headers["X-Agency-Name"]?.firstOrNull()?.isNotBlank() == true,
            "X-Agency-Name 헤더가 존재해야 함")
        assertEquals("contract-pending", response.headers["X-Real-Implementation-ETA"]?.firstOrNull(),
            "X-Real-Implementation-ETA 헤더가 'contract-pending'이어야 함")
        // X-Guide-Ref도 URL-encoded (한글 anchor 포함). "integration-real-impl-guide" ASCII 부분이 포함되어 있어야 함
        assertTrue(response.headers["X-Guide-Ref"]?.firstOrNull()?.contains("integration-real-impl-guide") == true,
            "X-Guide-Ref 헤더에 가이드 문서 경로가 포함되어야 함")

        // body notImplemented=true 검증
        val respMap = objectMapper.readValue(response.body, Map::class.java)
        assertEquals(true, respMap["not_implemented"], "응답 body not_implemented 가 true이어야 함 (POLICY-NI-01)")
        assertTrue((respMap["mock_reason"] as? String)?.isNotBlank() == true, "mock_reason 필드가 있어야 함")
        assertTrue((respMap["guide_ref"] as? String)?.contains("integration-real-impl-guide") == true, "guide_ref 필드가 있어야 함")
    }

    @Test
    fun `POLICY-NI-01 - TSA 응답 헤더 X-Not-Implemented = true`() {
        wireMockServer.stubFor(
            WireMock.post(WireMock.urlEqualTo("/stub/tsa"))
                .willReturn(
                    WireMock.aResponse()
                        .withHeader("Content-Type", "application/json")
                        .withBody("""{"token":"dGVzdA==","serial_number":"HDR001","gen_time":"2026-04-22T00:00:00Z","policy_oid":"1.2.410.200001.1"}""")
                )
        )

        val reqHeaders = HttpHeaders().apply { contentType = MediaType.APPLICATION_JSON }
        val body = mapOf("sha256" to "a".repeat(64))
        val entity = HttpEntity(objectMapper.writeValueAsString(body), reqHeaders)

        val response = restTemplate.exchange("/timestamp", HttpMethod.POST, entity, String::class.java)

        assertEquals("true", response.headers["X-Not-Implemented"]?.firstOrNull(),
            "X-Not-Implemented 헤더가 'true'이어야 함 (POLICY-NI-01 TSA)")
        assertEquals("KISA TSA", response.headers["X-Agency-Name"]?.firstOrNull(),
            "X-Agency-Name 헤더가 'KISA TSA'이어야 함")

        val respMap = objectMapper.readValue(response.body, Map::class.java)
        assertEquals(true, respMap["not_implemented"], "TSA 응답 body not_implemented 가 true이어야 함 (POLICY-NI-01)")
    }

    @Test
    fun `POLICY-NI-01 - OCSP 응답 헤더 X-Not-Implemented = true`() {
        wireMockServer.stubFor(
            WireMock.post(WireMock.urlEqualTo("/stub/ocsp"))
                .willReturn(
                    WireMock.aResponse()
                        .withHeader("Content-Type", "application/json")
                        .withBody("""{"status":"good","this_update":"2026-04-22T00:00:00Z"}""")
                )
        )

        val reqHeaders = HttpHeaders().apply { contentType = MediaType.APPLICATION_JSON }
        val body = mapOf("issuer_cn" to "KISA-RootCA-G1", "serial" to "hdrtest01")
        val entity = HttpEntity(objectMapper.writeValueAsString(body), reqHeaders)

        val response = restTemplate.exchange("/ocsp", HttpMethod.POST, entity, String::class.java)

        assertEquals("true", response.headers["X-Not-Implemented"]?.firstOrNull(),
            "X-Not-Implemented 헤더가 'true'이어야 함 (POLICY-NI-01 OCSP)")
        assertEquals("KISA OCSP", response.headers["X-Agency-Name"]?.firstOrNull(),
            "X-Agency-Name 헤더가 'KISA OCSP'이어야 함")

        val respMap = objectMapper.readValue(response.body, Map::class.java)
        assertEquals(true, respMap["not_implemented"], "OCSP 응답 body not_implemented 가 true이어야 함 (POLICY-NI-01)")
    }
}
