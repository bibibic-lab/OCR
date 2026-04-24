package kr.ocr.upload

import com.fasterxml.jackson.databind.ObjectMapper
import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.http.ResponseEntity
import org.springframework.security.core.annotation.AuthenticationPrincipal
import org.springframework.security.oauth2.jwt.Jwt
import org.springframework.web.bind.annotation.ExceptionHandler
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.PutMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.multipart.MultipartFile
import java.util.UUID

/**
 * POST /documents          — 파일 업로드.
 * GET  /documents/{id}     — 문서 상태 + OCR 결과 조회.
 * PUT  /documents/{id}/items — OCR 결과 items 전체 교체 (수정).
 *
 * POST /documents:
 *  - multipart/form-data, 필드명: file
 *  - 최대 50 MB
 *  - JWT sub 클레임으로 owner 식별
 *  - 201 Created: {"id":"<uuid>","status":"UPLOADED"}
 *
 * GET /documents/{id}:
 *  - owner check: JWT sub 가 document.owner_sub 와 일치해야 함
 *  - 404: 문서 없음 | 403: 타인 문서
 *  - 200 (OCR_DONE): DocumentDoneResponse (updatedAt, updateCount 포함)
 *
 * PUT /documents/{id}/items:
 *  - 상태가 OCR_DONE 인 문서의 items 배열을 전체 교체.
 *  - 소유자 본인만 수정 가능 (403).
 *  - RRN 자동 재토큰화 적용.
 *  - 400: 상태가 OCR_DONE 이 아닌 경우.
 */
@RestController
@RequestMapping("/documents")
class DocumentController(
    private val documentService: DocumentService,
    private val documentRepository: DocumentRepository,
    private val ocrResultRepository: OcrResultRepository,
    private val objectMapper: ObjectMapper,
    private val editService: OcrEditService,
) {
    // documentService 는 생성자 주입으로 stats() 에서도 사용


    /**
     * GET /documents/stats — 소유자 기준 대시보드 통계.
     *
     * POLICY-NI-01: Not Implemented 기능 목록 포함.
     * 401: 비인증 요청.
     */
    @GetMapping("/stats")
    fun stats(
        @AuthenticationPrincipal jwt: Jwt,
    ): ResponseEntity<StatsResponse> {
        val stats = documentService.getStats(jwt.subject)
        return ResponseEntity.ok(stats)
    }

    /**
     * GET /documents — 소유자 문서 목록 페이지네이션 조회.
     *
     * Query params:
     *  - page   (default 0)
     *  - size   (default 20, max 100)
     *  - status (optional): UPLOADED | OCR_RUNNING | OCR_DONE | OCR_FAILED
     *  - q      (optional): filename ILIKE '%q%'
     *  - sort   (default "uploaded_at,desc"): field,direction
     *
     * Phase 2 이월: admin Role 타인 문서 조회 (owner_sub 필터 제거 예정)
     */
    @GetMapping
    fun listDocuments(
        @AuthenticationPrincipal jwt: Jwt,
        @RequestParam(defaultValue = "0") page: Int,
        @RequestParam(defaultValue = "20") size: Int,
        @RequestParam(required = false) status: String?,
        @RequestParam(required = false) q: String?,
        @RequestParam(defaultValue = "uploaded_at,desc") sort: String,
    ): ResponseEntity<DocumentPageResponse> {
        val allowedStatuses = setOf("UPLOADED", "OCR_RUNNING", "OCR_DONE", "OCR_FAILED")
        if (status != null && status !in allowedStatuses) {
            return ResponseEntity.badRequest().build()
        }
        if (page < 0) return ResponseEntity.badRequest().build()

        val parts = sort.split(",")
        val sortField = parts.getOrNull(0)?.trim() ?: "uploaded_at"
        val sortDir = parts.getOrNull(1)?.trim() ?: "desc"
        val allowedFields = setOf("uploaded_at", "ocr_finished_at")
        if (sortField !in allowedFields) return ResponseEntity.badRequest().build()

        val docPage = documentService.listByOwner(
            ownerSub = jwt.subject,
            page = page,
            size = size.coerceIn(1, 100),
            status = status,
            q = q?.takeIf { it.isNotBlank() },
            sortField = sortField,
            sortDir = sortDir,
        )

        val response = DocumentPageResponse(
            content = docPage.content.map { row ->
                DocumentListItem(
                    id = row.id.toString(),
                    filename = row.filename,
                    contentType = row.contentType,
                    byteSize = row.byteSize,
                    status = row.status,
                    uploadedAt = row.uploadedAt,
                    ocrFinishedAt = row.ocrFinishedAt,
                    updateCount = row.updateCount,
                    itemCount = row.itemCount,
                )
            },
            page = docPage.page,
            size = docPage.size,
            totalElements = docPage.totalElements,
            totalPages = docPage.totalPages,
            hasNext = docPage.hasNext,
        )
        return ResponseEntity.ok(response)
    }

    @PostMapping(consumes = [MediaType.MULTIPART_FORM_DATA_VALUE])
    fun upload(
        @RequestParam("file") file: MultipartFile,
        @AuthenticationPrincipal jwt: Jwt,
    ): ResponseEntity<UploadResponse> {
        val ownerSub = jwt.subject
        val id = documentService.uploadDocument(file, ownerSub)
        return ResponseEntity.status(HttpStatus.CREATED).body(
            UploadResponse(id = id.toString(), status = "UPLOADED")
        )
    }

    @GetMapping("/{id}")
    fun getDocument(
        @PathVariable("id") idStr: String,
        @AuthenticationPrincipal jwt: Jwt,
    ): ResponseEntity<Any> {
        val id = try {
            UUID.fromString(idStr)
        } catch (e: IllegalArgumentException) {
            return ResponseEntity.notFound().build()
        }

        val doc = documentRepository.findById(id)
            ?: return ResponseEntity.notFound().build()

        if (doc.ownerSub != jwt.subject) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN)
                .body(ErrorResponse("접근 권한이 없습니다."))
        }

        if (doc.status == "OCR_DONE") {
            val ocrResult = ocrResultRepository.findByDocumentId(id)
            if (ocrResult != null) {
                val items: List<OcrItem> = objectMapper.readValue(
                    ocrResult.itemsJson,
                    objectMapper.typeFactory.constructCollectionType(List::class.java, OcrItem::class.java)
                )
                return ResponseEntity.ok(
                    DocumentDoneResponse(
                        id = id.toString(),
                        status = "OCR_DONE",
                        engine = ocrResult.engine,
                        langs = ocrResult.langs.split(",").filter { it.isNotBlank() },
                        items = items,
                        ocrFinishedAt = doc.ocrFinishedAt,
                        updatedAt = ocrResult.updatedAt,
                        updateCount = ocrResult.updateCount,
                    )
                )
            }
        }

        return ResponseEntity.ok(
            DocumentStatusResponse(id = id.toString(), status = doc.status)
        )
    }

    /**
     * PUT /documents/{id}/items
     *
     * OCR 결과 items 전체 교체.
     *  - 200: 업데이트 성공 → DocumentDoneResponse (updatedAt, updateCount 포함)
     *  - 400: 문서 상태가 OCR_DONE 이 아님 (편집 불가 상태)
     *  - 403: 본인 소유 문서가 아님
     *  - 404: 문서 없음
     */
    @PutMapping("/{id}/items")
    fun updateItems(
        @PathVariable("id") idStr: String,
        @RequestBody request: UpdateItemsRequest,
        @AuthenticationPrincipal jwt: Jwt,
    ): ResponseEntity<Any> {
        val id = try {
            UUID.fromString(idStr)
        } catch (e: IllegalArgumentException) {
            return ResponseEntity.notFound().build()
        }

        return when (val result = editService.updateItems(id, jwt.subject, request.items)) {
            is EditResult.NotFound -> ResponseEntity.notFound().build()
            is EditResult.Forbidden -> ResponseEntity.status(HttpStatus.FORBIDDEN)
                .body(ErrorResponse("접근 권한이 없습니다."))
            is EditResult.InvalidStatus -> ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(ErrorResponse("OCR_DONE 상태의 문서만 편집할 수 있습니다. 현재 상태: ${result.currentStatus}"))
            is EditResult.Success -> {
                val row = result.row
                val items: List<OcrItem> = objectMapper.readValue(
                    row.itemsJson,
                    objectMapper.typeFactory.constructCollectionType(List::class.java, OcrItem::class.java)
                )
                ResponseEntity.ok(
                    DocumentDoneResponse(
                        id = id.toString(),
                        status = "OCR_DONE",
                        engine = row.engine,
                        langs = row.langs.split(",").filter { it.isNotBlank() },
                        items = items,
                        ocrFinishedAt = result.doc.ocrFinishedAt,
                        updatedAt = row.updatedAt,
                        updateCount = row.updateCount,
                    )
                )
            }
        }
    }

    @ExceptionHandler(UnsupportedMediaTypeException::class)
    fun handleUnsupportedMediaType(ex: UnsupportedMediaTypeException): ResponseEntity<ErrorResponse> =
        ResponseEntity.status(HttpStatus.UNSUPPORTED_MEDIA_TYPE)
            .body(ErrorResponse(ex.message ?: "Unsupported media type"))
}

data class UploadResponse(val id: String, val status: String)

data class DocumentStatusResponse(val id: String, val status: String)

data class DocumentDoneResponse(
    val id: String,
    val status: String,
    val engine: String,
    val langs: List<String>,
    val items: List<OcrItem>,
    val ocrFinishedAt: java.time.OffsetDateTime? = null,
    val updatedAt: java.time.OffsetDateTime? = null,
    val updateCount: Int = 0,
)

/** PUT /documents/{id}/items 요청 본문 */
data class UpdateItemsRequest(val items: List<OcrItem>)

data class ErrorResponse(val message: String)

/** GET /documents 목록 항목 */
data class DocumentListItem(
    val id: String,
    val filename: String,
    val contentType: String,
    val byteSize: Long,
    val status: String,
    val uploadedAt: java.time.OffsetDateTime,
    val ocrFinishedAt: java.time.OffsetDateTime? = null,
    val updateCount: Int = 0,
    val itemCount: Int = 0,
)

/** GET /documents 페이지 응답 */
data class DocumentPageResponse(
    val content: List<DocumentListItem>,
    val page: Int,
    val size: Int,
    val totalElements: Long,
    val totalPages: Int,
    val hasNext: Boolean,
)

/** GET /stats 응답 */
data class StatsResponse(
    val owner: OwnerStats,
    val recent: List<RecentItem>,
    val engines: EnginesInfo,
    /** POLICY-NI-01: 관리 대시보드에 표시할 Not Implemented 기능 목록 */
    val notImplemented: List<NotImplementedItem>,
) {
    data class OwnerStats(
        val total: Long,
        val today: Long,
        val byStatus: Map<String, Long>,
        val todayFailed: Long,
        val totalEdited: Long,
    )

    data class RecentItem(
        val id: String,
        val filename: String,
        val status: String,
        val uploadedAt: java.time.OffsetDateTime,
        val ocrFinishedAt: java.time.OffsetDateTime? = null,
        val itemCount: Int = 0,
    )

    data class EnginesInfo(
        val current: String,
        val alternatives: List<String>,
    )

    data class NotImplementedItem(
        val feature: String,
        val reason: String,
        val guideRef: String,
    )
}
