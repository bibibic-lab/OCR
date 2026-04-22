package kr.ocr.upload

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.mock.mockito.MockBean
import org.springframework.http.MediaType
import org.springframework.mock.web.MockMultipartFile
import org.springframework.security.oauth2.jwt.JwtDecoder
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.context.DynamicPropertyRegistry
import org.springframework.test.context.DynamicPropertySource
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.multipart
import org.springframework.test.web.servlet.post
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
import software.amazon.awssdk.services.s3.model.HeadObjectRequest
import java.security.MessageDigest

/**
 * POST /documents 통합 테스트.
 *
 * 인프라: PostgreSQL 16 (Testcontainers) + LocalStack S3 (Testcontainers)
 * 인증:  MockMvc SecurityMockMvcRequestPostProcessors.jwt() — 실 Keycloak 불필요
 *
 * 검증 항목:
 *  1. 유효 JWT + PNG 업로드 → 201, 응답 body에 id/status
 *  2. DB에 document 행 존재 + sha256_hex 정확
 *  3. S3에 오브젝트 존재
 *  4. 비인증 요청 → 401
 *  5. 허용되지 않는 Content-Type → 415
 */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers
@ActiveProfiles("test-int")
class DocumentControllerTest {

    companion object {
        @Container
        val postgres: PostgreSQLContainer<*> = PostgreSQLContainer("postgres:16-alpine")

        @Container
        val localstack: LocalStackContainer = LocalStackContainer(
            DockerImageName.parse("localstack/localstack:3.4")
        ).withServices(Service.S3)

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
        }
    }

    @Autowired
    private lateinit var mockMvc: MockMvc

    @Autowired
    private lateinit var documentRepository: DocumentRepository

    // 실 Keycloak JWKS 호출 차단 — SecurityMockMvcRequestPostProcessors.jwt()가 토큰 주입
    @MockBean
    private lateinit var jwtDecoder: JwtDecoder

    /**
     * OCR 트리거를 no-op으로 교체.
     * DocumentControllerTest는 업로드/S3/DB 저장만 검증하며 OCR 흐름은 OcrFlowTest에서 담당.
     * triggerAsync 를 no-op으로 막아 status 가 UPLOADED에서 변경되지 않도록 함.
     */
    @MockBean
    private lateinit var ocrTriggerService: OcrTriggerService

    /** 각 테스트 전 LocalStack에 bucket 생성 (ApplicationReadyEvent는 MockMvc 환경에서 발화 안 될 수 있음) */
    @BeforeEach
    fun createBucket() {
        val s3 = buildLocalStackS3Client()
        try {
            s3.createBucket { it.bucket("uploads") }
        } catch (_: Exception) { /* 이미 존재 */ }
    }

    @Test
    fun `유효 JWT와 PNG 파일 업로드 시 201 반환`() {
        val sampleBytes = "fake-png-content".toByteArray()
        val file = MockMultipartFile("file", "sample.png", "image/png", sampleBytes)

        val result = mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("test-user-sub") })
        }.andExpect {
            status { isCreated() }
            jsonPath("$.id") { isNotEmpty() }
            jsonPath("$.status") { value("UPLOADED") }
        }.andReturn()

        // 응답에서 id 추출
        val body = result.response.contentAsString
        val id = Regex(""""id"\s*:\s*"([^"]+)"""").find(body)?.groupValues?.get(1)
        assertThat(id).isNotNull()
    }

    @Test
    fun `업로드 후 DB에 올바른 sha256_hex 를 가진 document 행이 존재한다`() {
        val sampleBytes = "sha256-test-content".toByteArray()
        val expectedSha256 = MessageDigest.getInstance("SHA-256").digest(sampleBytes)
            .joinToString("") { "%02x".format(it) }

        val file = MockMultipartFile("file", "test.png", "image/png", sampleBytes)

        val result = mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("test-user-sub") })
        }.andExpect {
            status { isCreated() }
        }.andReturn()

        val body = result.response.contentAsString
        val idStr = Regex(""""id"\s*:\s*"([^"]+)"""").find(body)!!.groupValues[1]
        val docId = java.util.UUID.fromString(idStr)

        val row = documentRepository.findById(docId)
        assertThat(row).isNotNull
        assertThat(row!!.sha256Hex).isEqualTo(expectedSha256)
        assertThat(row.ownerSub).isEqualTo("test-user-sub")
        assertThat(row.status).isEqualTo("UPLOADED")
    }

    @Test
    fun `업로드 후 S3 에 오브젝트가 존재한다`() {
        val sampleBytes = "s3-object-check".toByteArray()
        val file = MockMultipartFile("file", "check.png", "image/png", sampleBytes)

        val result = mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("s3-check-user") })
        }.andExpect {
            status { isCreated() }
        }.andReturn()

        val body = result.response.contentAsString
        val idStr = Regex(""""id"\s*:\s*"([^"]+)"""").find(body)!!.groupValues[1]
        val docId = java.util.UUID.fromString(idStr)

        val row = documentRepository.findById(docId)!!
        val s3 = buildLocalStackS3Client()
        // HeadObject 가 예외 없이 반환되면 오브젝트 존재
        val head = s3.headObject(HeadObjectRequest.builder().bucket(row.s3Bucket).key(row.s3Key).build())
        assertThat(head.contentLength()).isEqualTo(sampleBytes.size.toLong())
    }

    @Test
    fun `비인증 요청은 401 을 반환한다`() {
        val file = MockMultipartFile("file", "unauth.png", "image/png", "data".toByteArray())
        mockMvc.multipart("/documents") {
            file(file)
        }.andExpect {
            status { isUnauthorized() }
        }
    }

    @Test
    fun `허용되지 않는 Content-Type 은 415 를 반환한다`() {
        val file = MockMultipartFile("file", "doc.txt", "text/plain", "hello".toByteArray())
        mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("test-user-sub") })
        }.andExpect {
            status { isUnsupportedMediaType() }
        }
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
