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
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.multipart.MultipartFile
import java.util.UUID

/**
 * POST /documents  — 파일 업로드 엔드포인트.
 * GET  /documents/{id} — 문서 상태 + OCR 결과 조회.
 *
 * POST /documents:
 *  - multipart/form-data, 필드명: file
 *  - 최대 50 MB (application.yml spring.servlet.multipart.max-file-size=50MB)
 *  - JWT sub 클레임으로 owner 식별
 *  - 201 Created: {"id":"<uuid>","status":"UPLOADED"}
 *
 * GET /documents/{id}:
 *  - owner check: JWT sub 가 document.owner_sub 와 일치해야 함
 *  - 404: 문서 없음
 *  - 403: 다른 유저의 문서
 *  - 200 (OCR_RUNNING/UPLOADED/OCR_FAILED): {"id":"...","status":"..."}
 *  - 200 (OCR_DONE): {"id":"...","status":"OCR_DONE","engine":"...","langs":[...],"items":[...]}
 */
@RestController
@RequestMapping("/documents")
class DocumentController(
    private val documentService: DocumentService,
    private val documentRepository: DocumentRepository,
    private val ocrResultRepository: OcrResultRepository,
    private val objectMapper: ObjectMapper,
) {

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
                    )
                )
            }
        }

        return ResponseEntity.ok(
            DocumentStatusResponse(id = id.toString(), status = doc.status)
        )
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
)

data class ErrorResponse(val message: String)
