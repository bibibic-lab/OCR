package kr.ocr.upload

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.QueueDispatcher
import org.assertj.core.api.Assertions.assertThat
import org.assertj.core.api.Assertions.fail
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.mock.mockito.MockBean
import org.springframework.mock.web.MockMultipartFile
import org.springframework.security.oauth2.jwt.JwtDecoder
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.context.DynamicPropertyRegistry
import org.springframework.test.context.DynamicPropertySource
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import org.springframework.test.web.servlet.multipart
import org.testcontainers.containers.PostgreSQLContainer
import org.testcontainers.containers.localstack.LocalStackContainer
import org.testcontainers.containers.localstack.LocalStackContainer.Service
import org.testcontainers.junit.jupiter.Container
import org.testcontainers.junit.jupiter.Testcontainers
import org.testcontainers.utility.DockerImageName
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider
import software.amazon.awssdk.regions.Region
import software.amazon.awssdk.services.s3.S3Client

/**
 * OCR 전체 흐름 통합 테스트.
 *
 * 인프라:
 *  - PostgreSQL 16 (Testcontainers)
 *  - LocalStack S3 (Testcontainers)
 *  - MockWebServer (OkHttp) — ocr-worker stub
 *
 * 검증 항목:
 *  1. 업로드 → 폴링 → OCR_DONE (최대 30초) + items 5개 확인
 *  2. 다른 유저 JWT → GET /documents/{id} → 403
 *  3. 없는 UUID → GET /documents/{id} → 404
 *  4. ocr-worker 500 응답 → OCR_FAILED
 */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers
@ActiveProfiles("test-int")
class OcrFlowTest {

    companion object {
        @Container
        val postgres: PostgreSQLContainer<*> = PostgreSQLContainer("postgres:16-alpine")

        @Container
        val localstack: LocalStackContainer = LocalStackContainer(
            DockerImageName.parse("localstack/localstack:3.4")
        ).withServices(Service.S3)

        /** MockWebServer — ocr-worker 스텁 */
        lateinit var mockOcrServer: MockWebServer

        @BeforeAll
        @JvmStatic
        fun startMockServer() {
            mockOcrServer = MockWebServer()
            mockOcrServer.start()
        }

        @AfterAll
        @JvmStatic
        fun stopMockServer() {
            mockOcrServer.shutdown()
        }

        /** OCR worker 정상 응답 fixture */
        val OCR_SUCCESS_JSON = """
            {
              "filename": "sample.png",
              "engine": "EasyOCR 1.7.1",
              "langs": ["ko","en"],
              "count": 5,
              "items": [
                {"text": "안녕하세요", "confidence": 0.9998, "bbox": [[0,0],[100,0],[100,20],[0,20]]},
                {"text": "Hello", "confidence": 0.9990, "bbox": [[0,25],[80,25],[80,45],[0,45]]},
                {"text": "테스트", "confidence": 0.9985, "bbox": [[0,50],[90,50],[90,70],[0,70]]},
                {"text": "OCR", "confidence": 0.9995, "bbox": [[0,75],[60,75],[60,95],[0,95]]},
                {"text": "문서", "confidence": 0.9992, "bbox": [[0,100],[70,100],[70,120],[0,120]]}
              ]
            }
        """.trimIndent()

        @JvmStatic
        @DynamicPropertySource
        fun props(registry: DynamicPropertyRegistry) {
            // PostgreSQL
            registry.add("spring.datasource.url", postgres::getJdbcUrl)
            registry.add("spring.datasource.username", postgres::getUsername)
            registry.add("spring.datasource.password", postgres::getPassword)

            // LocalStack S3
            registry.add("ocr.s3.endpoint") { localstack.getEndpointOverride(Service.S3).toString() }
            registry.add("ocr.s3.access-key") { localstack.accessKey }
            registry.add("ocr.s3.secret-key") { localstack.secretKey }
            registry.add("ocr.s3.region") { localstack.region }

            // OCR worker → MockWebServer (포트는 startMockServer 후 확정)
            registry.add("ocr.ocr-worker.base-url") { "http://localhost:${mockOcrServer.port}" }
            registry.add("ocr.ocr-worker.timeout-ms") { "10000" }
        }

        private fun buildLocalStackS3Client(): S3Client =
            S3Client.builder()
                .endpointOverride(localstack.getEndpointOverride(Service.S3))
                .credentialsProvider(
                    StaticCredentialsProvider.create(
                        AwsBasicCredentials.create(localstack.accessKey, localstack.secretKey)
                    )
                )
                .region(Region.of(localstack.region))
                .forcePathStyle(true)
                .build()
    }

    @Autowired
    private lateinit var mockMvc: MockMvc

    // 실 Keycloak JWKS 호출 차단
    @MockBean
    private lateinit var jwtDecoder: JwtDecoder

    @BeforeEach
    fun setUp() {
        // MockWebServer 큐 초기화 — 이전 테스트의 잔류 응답 제거
        mockOcrServer.dispatcher = QueueDispatcher()
        // S3 버킷 생성 (이미 존재하면 무시)
        val s3 = buildLocalStackS3Client()
        try {
            s3.createBucket { it.bucket("uploads") }
        } catch (_: Exception) { /* already exists */ }
    }

    // ─────────────────────────────────────────
    // Test 1: 업로드 → 폴링 → OCR_DONE + items 5개
    // ─────────────────────────────────────────
    @Test
    fun `업로드 후 OCR_DONE 상태와 5개 아이템을 확인한다`() {
        // MockWebServer에 성공 응답 등록
        mockOcrServer.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody(OCR_SUCCESS_JSON)
        )

        val file = MockMultipartFile("file", "sample.png", "image/png", "fake-png-bytes".toByteArray())

        val uploadResult = mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("ocr-user") })
        }.andExpect {
            status { isCreated() }
        }.andReturn()

        val body = uploadResult.response.contentAsString
        val docId = Regex(""""id"\s*:\s*"([^"]+)"""").find(body)!!.groupValues[1]

        // 30초 폴링 → OCR_DONE 대기
        awaitStatus(docId, "OCR_DONE", ownerSub = "ocr-user", timeoutMs = 30_000)

        // GET /documents/{id} → OCR_DONE 상세 검증
        val getResult = mockMvc.get("/documents/$docId") {
            with(jwt().jwt { it.subject("ocr-user") })
        }.andExpect {
            status { isOk() }
            jsonPath("$.status") { value("OCR_DONE") }
            jsonPath("$.engine") { value("EasyOCR 1.7.1") }
            jsonPath("$.langs[0]") { value("ko") }
            jsonPath("$.langs[1]") { value("en") }
            jsonPath("$.items.length()") { value(5) }
            jsonPath("$.ocrFinishedAt") { exists() }
        }.andReturn()

        assertThat(getResult.response.getContentAsString(Charsets.UTF_8)).contains("안녕하세요")
    }

    // ─────────────────────────────────────────
    // Test 2: 다른 owner JWT → 403
    // ─────────────────────────────────────────
    @Test
    fun `다른 유저의 JWT로 문서 조회 시 403을 반환한다`() {
        // 업로드 시 OCR 트리거 발생 → MockWebServer 응답 필요
        mockOcrServer.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody(OCR_SUCCESS_JSON)
        )

        val file = MockMultipartFile("file", "owner-test.png", "image/png", "data".toByteArray())

        val uploadResult = mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("real-owner") })
        }.andExpect {
            status { isCreated() }
        }.andReturn()

        val body = uploadResult.response.contentAsString
        val docId = Regex(""""id"\s*:\s*"([^"]+)"""").find(body)!!.groupValues[1]

        // 다른 유저로 조회 → 403
        mockMvc.get("/documents/$docId") {
            with(jwt().jwt { it.subject("other-user") })
        }.andExpect {
            status { isForbidden() }
        }
    }

    // ─────────────────────────────────────────
    // Test 3: 없는 UUID → 404
    // ─────────────────────────────────────────
    @Test
    fun `존재하지 않는 문서 ID 조회 시 404를 반환한다`() {
        val nonExistentId = "00000000-0000-0000-0000-000000000000"

        mockMvc.get("/documents/$nonExistentId") {
            with(jwt().jwt { it.subject("any-user") })
        }.andExpect {
            status { isNotFound() }
        }
    }

    // ─────────────────────────────────────────
    // Test 4: ocr-worker 500 → OCR_FAILED
    // ─────────────────────────────────────────
    @Test
    fun `OCR worker 500 응답 시 OCR_FAILED 상태가 된다`() {
        // MockWebServer에 실패 응답 등록
        mockOcrServer.enqueue(
            MockResponse()
                .setResponseCode(500)
                .setBody("Internal Server Error")
        )

        val file = MockMultipartFile("file", "fail-test.png", "image/png", "fail-data".toByteArray())

        val uploadResult = mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("fail-user") })
        }.andExpect {
            status { isCreated() }
        }.andReturn()

        val body = uploadResult.response.contentAsString
        val docId = Regex(""""id"\s*:\s*"([^"]+)"""").find(body)!!.groupValues[1]

        // 10초 내 OCR_FAILED 도달 확인
        awaitStatus(docId, "OCR_FAILED", ownerSub = "fail-user", timeoutMs = 10_000)
    }

    // ─────────────────────────────────────────
    // Helper: 상태 폴링
    // ─────────────────────────────────────────
    private fun awaitStatus(
        id: String,
        expected: String,
        ownerSub: String,
        timeoutMs: Long = 30_000,
    ) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val responseBody = mockMvc.get("/documents/$id") {
                with(jwt().jwt { it.subject(ownerSub) })
            }.andReturn().response.contentAsString

            if (responseBody.contains("\"status\":\"$expected\"")) return
            Thread.sleep(500)
        }
        fail<Nothing>("timed out waiting for status=$expected on documentId=$id")
    }
}
