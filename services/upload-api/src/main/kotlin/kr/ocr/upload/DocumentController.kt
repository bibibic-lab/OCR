package kr.ocr.upload

import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.http.ResponseEntity
import org.springframework.security.core.annotation.AuthenticationPrincipal
import org.springframework.security.oauth2.jwt.Jwt
import org.springframework.web.bind.annotation.ExceptionHandler
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.multipart.MultipartFile

/**
 * POST /documents — 파일 업로드 엔드포인트.
 *
 * - multipart/form-data, 필드명: file
 * - 최대 50 MB (application.yml spring.servlet.multipart.max-file-size=50MB)
 * - JWT sub 클레임으로 owner 식별
 * - 201 Created: {"id":"<uuid>","status":"UPLOADED"}
 */
@RestController
@RequestMapping("/documents")
class DocumentController(private val documentService: DocumentService) {

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

    @ExceptionHandler(UnsupportedMediaTypeException::class)
    fun handleUnsupportedMediaType(ex: UnsupportedMediaTypeException): ResponseEntity<ErrorResponse> =
        ResponseEntity.status(HttpStatus.UNSUPPORTED_MEDIA_TYPE)
            .body(ErrorResponse(ex.message ?: "Unsupported media type"))
}

data class UploadResponse(val id: String, val status: String)

data class ErrorResponse(val message: String)
