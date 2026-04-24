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
import org.springframework.test.web.servlet.get
import org.springframework.test.web.servlet.multipart
import org.springframework.test.web.servlet.post
import org.springframework.test.web.servlet.put
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

    @Autowired
    private lateinit var ocrResultRepository: OcrResultRepository

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

    // ─────────────────────────────────────────
    // PUT /documents/{id}/items 테스트
    // ─────────────────────────────────────────

    /**
     * PUT 정상 케이스: OCR_DONE 문서의 items 교체 → 200, updateCount=1.
     * ocr_result 행을 직접 INSERT 해서 OCR_DONE 상태 시뮬레이션.
     */
    @Test
    fun `PUT items 정상 케이스 - OCR_DONE 문서 수정 시 200 반환`() {
        // 1. 문서 업로드
        val sampleBytes = "put-test-png".toByteArray()
        val file = MockMultipartFile("file", "put-test.png", "image/png", sampleBytes)

        val uploadResult = mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("put-owner") })
        }.andExpect { status { isCreated() } }.andReturn()

        val body = uploadResult.response.contentAsString
        val idStr = Regex(""""id"\s*:\s*"([^"]+)"""").find(body)!!.groupValues[1]
        val docId = java.util.UUID.fromString(idStr)

        // 2. DB에 OCR_DONE + ocr_result 직접 삽입
        documentRepository.updateStatusDone(docId)
        ocrResultRepository.insert(
            OcrResultRow(
                documentId = docId,
                engine = "EasyOCR 1.7.1",
                langs = "ko,en",
                itemsJson = """[{"text":"원본","confidence":0.99,"bbox":[[0,0],[100,0],[100,20],[0,20]]}]""",
            )
        )

        // 3. PUT /documents/{id}/items
        val putBody = """
            {"items":[{"text":"수정됨","confidence":0.95,"bbox":[[0,0],[100,0],[100,20],[0,20]]}]}
        """.trimIndent()

        mockMvc.put("/documents/$idStr/items") {
            contentType = MediaType.APPLICATION_JSON
            content = putBody
            with(jwt().jwt { it.subject("put-owner") })
        }.andExpect {
            status { isOk() }
            jsonPath("$.status") { value("OCR_DONE") }
            jsonPath("$.updateCount") { value(1) }
            jsonPath("$.updatedAt") { exists() }
            jsonPath("$.items[0].text") { value("수정됨") }
        }
    }

    @Test
    fun `PUT items - 타인 JWT 접근 시 403 반환`() {
        // 1. 업로드
        val file = MockMultipartFile("file", "403-test.png", "image/png", "data".toByteArray())
        val uploadResult = mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("real-owner-403") })
        }.andExpect { status { isCreated() } }.andReturn()

        val idStr = Regex(""""id"\s*:\s*"([^"]+)"""").find(uploadResult.response.contentAsString)!!.groupValues[1]
        val docId = java.util.UUID.fromString(idStr)

        documentRepository.updateStatusDone(docId)
        ocrResultRepository.insert(OcrResultRow(documentId = docId, engine = "E", langs = "ko", itemsJson = "[]"))

        // 2. 다른 유저로 PUT → 403
        mockMvc.put("/documents/$idStr/items") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"items":[]}"""
            with(jwt().jwt { it.subject("intruder") })
        }.andExpect {
            status { isForbidden() }
        }
    }

    @Test
    fun `PUT items - 존재하지 않는 문서 ID 시 404 반환`() {
        mockMvc.put("/documents/00000000-0000-0000-0000-000000000099/items") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"items":[]}"""
            with(jwt().jwt { it.subject("any-user") })
        }.andExpect {
            status { isNotFound() }
        }
    }

    @Test
    fun `PUT items - OCR_DONE 아닌 상태에서 편집 시 400 반환`() {
        // 1. 업로드 (status=UPLOADED)
        val file = MockMultipartFile("file", "400-test.png", "image/png", "data".toByteArray())
        val uploadResult = mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("status-owner") })
        }.andExpect { status { isCreated() } }.andReturn()

        val idStr = Regex(""""id"\s*:\s*"([^"]+)"""").find(uploadResult.response.contentAsString)!!.groupValues[1]

        // UPLOADED 상태 그대로 PUT → 400
        mockMvc.put("/documents/$idStr/items") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"items":[]}"""
            with(jwt().jwt { it.subject("status-owner") })
        }.andExpect {
            status { isBadRequest() }
        }
    }

    // ─────────────────────────────────────────
    // GET /documents 목록 조회 테스트
    // ─────────────────────────────────────────

    @Test
    fun `GET documents - 본인 문서만 반환된다`() {
        // owner-a 문서 2건, owner-b 문서 1건 업로드
        repeat(2) { i ->
            val file = MockMultipartFile("file", "list-a-$i.png", "image/png", "data$i".toByteArray())
            mockMvc.multipart("/documents") {
                file(file)
                with(jwt().jwt { it.subject("list-owner-a") })
            }.andExpect { status { isCreated() } }
        }
        val fileB = MockMultipartFile("file", "list-b.png", "image/png", "dataB".toByteArray())
        mockMvc.multipart("/documents") {
            file(fileB)
            with(jwt().jwt { it.subject("list-owner-b") })
        }.andExpect { status { isCreated() } }

        // owner-a로 목록 조회 → 2건
        mockMvc.get("/documents") {
            with(jwt().jwt { it.subject("list-owner-a") })
        }.andExpect {
            status { isOk() }
            jsonPath("$.totalElements") { value(2) }
            jsonPath("$.content.length()") { value(2) }
        }
    }

    @Test
    fun `GET documents - status 필터가 동작한다`() {
        // 문서 업로드 후 하나는 OCR_DONE으로 변경
        val file1 = MockMultipartFile("file", "status-filter-1.png", "image/png", "data1".toByteArray())
        val upload1 = mockMvc.multipart("/documents") {
            file(file1)
            with(jwt().jwt { it.subject("status-filter-owner") })
        }.andExpect { status { isCreated() } }.andReturn()
        val id1 = java.util.UUID.fromString(
            Regex(""""id"\s*:\s*"([^"]+)"""").find(upload1.response.contentAsString)!!.groupValues[1]
        )

        val file2 = MockMultipartFile("file", "status-filter-2.png", "image/png", "data2".toByteArray())
        mockMvc.multipart("/documents") {
            file(file2)
            with(jwt().jwt { it.subject("status-filter-owner") })
        }.andExpect { status { isCreated() } }

        documentRepository.updateStatusDone(id1)
        ocrResultRepository.insert(OcrResultRow(documentId = id1, engine = "E", langs = "ko", itemsJson = "[]"))

        // status=UPLOADED → 1건
        mockMvc.get("/documents?status=UPLOADED") {
            with(jwt().jwt { it.subject("status-filter-owner") })
        }.andExpect {
            status { isOk() }
            jsonPath("$.totalElements") { value(1) }
            jsonPath("$.content[0].status") { value("UPLOADED") }
        }

        // status=OCR_DONE → 1건
        mockMvc.get("/documents?status=OCR_DONE") {
            with(jwt().jwt { it.subject("status-filter-owner") })
        }.andExpect {
            status { isOk() }
            jsonPath("$.totalElements") { value(1) }
            jsonPath("$.content[0].status") { value("OCR_DONE") }
        }
    }

    @Test
    fun `GET documents - q 파일명 검색이 동작한다`() {
        val file1 = MockMultipartFile("file", "invoice-2024.png", "image/png", "d".toByteArray())
        val file2 = MockMultipartFile("file", "receipt-0001.png", "image/png", "d".toByteArray())
        for (f in listOf(file1, file2)) {
            mockMvc.multipart("/documents") {
                file(f)
                with(jwt().jwt { it.subject("q-search-owner") })
            }.andExpect { status { isCreated() } }
        }

        mockMvc.get("/documents?q=invoice") {
            with(jwt().jwt { it.subject("q-search-owner") })
        }.andExpect {
            status { isOk() }
            jsonPath("$.totalElements") { value(1) }
            jsonPath("$.content[0].filename") { value("invoice-2024.png") }
        }
    }

    @Test
    fun `GET documents - 페이지네이션이 동작한다`() {
        repeat(5) { i ->
            val file = MockMultipartFile("file", "page-doc-$i.png", "image/png", "d$i".toByteArray())
            mockMvc.multipart("/documents") {
                file(file)
                with(jwt().jwt { it.subject("page-owner") })
            }.andExpect { status { isCreated() } }
        }

        mockMvc.get("/documents?page=0&size=2") {
            with(jwt().jwt { it.subject("page-owner") })
        }.andExpect {
            status { isOk() }
            jsonPath("$.page") { value(0) }
            jsonPath("$.size") { value(2) }
            jsonPath("$.content.length()") { value(2) }
            jsonPath("$.totalElements") { value(5) }
            jsonPath("$.totalPages") { value(3) }
            jsonPath("$.hasNext") { value(true) }
        }

        mockMvc.get("/documents?page=2&size=2") {
            with(jwt().jwt { it.subject("page-owner") })
        }.andExpect {
            status { isOk() }
            jsonPath("$.content.length()") { value(1) }
            jsonPath("$.hasNext") { value(false) }
        }
    }

    @Test
    fun `GET documents - 비인증 요청은 401 반환`() {
        mockMvc.get("/documents").andExpect {
            status { isUnauthorized() }
        }
    }

    // ─────────────────────────────────────────
    // GET /documents/stats 테스트
    // ─────────────────────────────────────────

    @Test
    fun `GET stats - 인증된 사용자는 통계를 반환한다`() {
        // 문서 1건 업로드
        val file = MockMultipartFile("file", "stats-test.png", "image/png", "data".toByteArray())
        mockMvc.multipart("/documents") {
            file(file)
            with(jwt().jwt { it.subject("stats-owner") })
        }.andExpect { status { isCreated() } }

        // GET /documents/stats
        mockMvc.get("/documents/stats") {
            with(jwt().jwt { it.subject("stats-owner") })
        }.andExpect {
            status { isOk() }
            jsonPath("$.owner.total") { value(1) }
            jsonPath("$.owner.today") { value(1) }
            jsonPath("$.owner.byStatus.UPLOADED") { exists() }
            jsonPath("$.recent") { isArray() }
            jsonPath("$.engines.current") { value("PaddleOCR PP-OCRv5") }
            jsonPath("$.notImplemented") { isArray() }
            // POLICY-NI-01: Not Implemented 5건 이상
            jsonPath("$.notImplemented.length()") { value(5) }
        }
    }

    @Test
    fun `GET stats - 비인증 요청은 401 반환`() {
        mockMvc.get("/documents/stats").andExpect {
            status { isUnauthorized() }
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
