package kr.ocr.upload

import org.slf4j.LoggerFactory
import org.springframework.stereotype.Service
import org.springframework.web.multipart.MultipartFile
import software.amazon.awssdk.core.sync.RequestBody
import software.amazon.awssdk.services.s3.S3Client
import software.amazon.awssdk.services.s3.model.PutObjectRequest
import java.security.DigestInputStream
import java.security.MessageDigest
import java.time.LocalDate
import java.time.OffsetDateTime
import java.util.UUID
import software.amazon.awssdk.services.s3.model.DeleteObjectRequest

/**
 * 파일 업로드 비즈니스 로직.
 *
 * 책임:
 *  1. Content-Type 허용 목록 검증
 *  2. S3 키 계산 (sub 앞 4자 파티션 / yyyy/MM/dd / uuid.ext)
 *  3. DigestInputStream으로 S3 스트리밍 + SHA-256 동시 계산 (Option A)
 *  4. document 테이블 INSERT (status=UPLOADED)
 *  5. 신규 document id 반환
 *  6. OCR 트리거 비동기 kick-off (OcrTriggerService.triggerAsync)
 *
 * 트리거 설계 선택: Option B (서비스가 업로드 라이프사이클 전체 소유)
 *  - uploadDocument() 내부에서 ocrTriggerService.triggerAsync(id) 를 fire-and-forget 호출.
 *  - @Async 는 OcrTriggerService(별도 빈) 에 적용 — self-invocation 프록시 우회 문제 없음.
 *  - 컨트롤러는 단순히 uploadDocument() 결과(UUID)를 받아 201 응답만 처리.
 */
@Service
class DocumentService(
    private val s3Client: S3Client,
    private val documentRepository: DocumentRepository,
    private val ocrTriggerService: OcrTriggerService,
    private val props: OcrProperties,
) {

    private val log = LoggerFactory.getLogger(DocumentService::class.java)

    companion object {
        private val ALLOWED_TYPES = setOf("image/png", "image/jpeg", "application/pdf")
    }

    /**
     * @return 생성된 document UUID
     * @throws UnsupportedMediaTypeException content-type 불허 시
     */
    fun uploadDocument(file: MultipartFile, ownerSub: String): UUID {
        val contentType = file.contentType
            ?: throw UnsupportedMediaTypeException("Content-Type 헤더가 없습니다.")
        if (contentType !in ALLOWED_TYPES) {
            throw UnsupportedMediaTypeException("허용되지 않는 Content-Type: $contentType")
        }

        val docId = UUID.randomUUID()
        // I-2: 확장자 sanitize — 경로 트래버설 문자·비알파숫자 제거, 최대 10자
        val ext = file.originalFilename
            ?.substringAfterLast('.', "")
            ?.lowercase()
            ?.filter { it.isLetterOrDigit() }
            ?.take(10)
            ?: ""
        val s3Key = buildS3Key(ownerSub, docId, ext)
        val bucket = props.s3.bucket

        // SHA-256 계산과 S3 업로드를 단일 스트림 패스로 처리 (Option A)
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream.use { raw ->
            val dis = DigestInputStream(raw, md)
            s3Client.putObject(
                PutObjectRequest.builder()
                    .bucket(bucket)
                    .key(s3Key)
                    .contentType(contentType)
                    .build(),
                RequestBody.fromInputStream(dis, file.size),
            )
        }
        val sha256Hex = md.digest().joinToString("") { "%02x".format(it) }

        val row = DocumentRow(
            id = docId,
            ownerSub = ownerSub,
            filename = file.originalFilename ?: "unknown",
            contentType = contentType,
            byteSize = file.size,
            sha256Hex = sha256Hex,
            s3Bucket = bucket,
            s3Key = s3Key,
            status = "UPLOADED",
            uploadedAt = OffsetDateTime.now(),
        )
        // I-1: DB insert 실패 시 S3 오브젝트 보상 삭제 (orphan 방지)
        try {
            documentRepository.insert(row)
        } catch (e: Exception) {
            log.warn("DB insert 실패 — S3 보상 삭제 시도: key={}", s3Key, e)
            runCatching {
                s3Client.deleteObject(
                    DeleteObjectRequest.builder().bucket(bucket).key(s3Key).build()
                )
            }.onFailure { log.error("S3 보상 삭제 실패: key={}", s3Key, it) }
            throw e
        }
        log.info("문서 업로드 완료: id={}, owner={}, key={}", docId, ownerSub, s3Key)

        // OCR 비동기 트리거 (fire-and-forget). 업로드 응답은 즉시 반환.
        // 큐 포화(TaskRejectedException) 시 업로드 성공은 유지하고 경고만 기록.
        try {
            ocrTriggerService.triggerAsync(docId)
        } catch (e: org.springframework.core.task.TaskRejectedException) {
            log.warn("OCR trigger queue saturated; upload succeeded but OCR deferred. docId={}", docId, e)
            // status 는 UPLOADED 로 유지. 추후 admin endpoint 에서 재시도 가능 (Phase 1).
        }

        return docId
    }

    /**
     * GET /documents — 소유자 기준 페이지네이션 목록 조회.
     *
     * @param ownerSub  JWT subject (본인 문서만)
     * @param page      0-based 페이지 번호
     * @param size      페이지 크기 (1~100)
     * @param status    상태 필터 (null=전체)
     * @param q         파일명 ILIKE 검색어 (null=필터 없음)
     * @param sortField "uploaded_at" | "ocr_finished_at"
     * @param sortDir   "asc" | "desc"
     */
    fun listByOwner(
        ownerSub: String,
        page: Int,
        size: Int,
        status: String?,
        q: String?,
        sortField: String,
        sortDir: String,
    ): DocumentPage {
        val clampedSize = size.coerceIn(1, 100)
        val offset = page.toLong() * clampedSize

        val total = documentRepository.countByOwnerFiltered(ownerSub, status, q)
        val rows = documentRepository.findByOwnerPaged(ownerSub, status, q, sortField, sortDir, clampedSize, offset)
        val totalPages = if (clampedSize == 0) 0 else ((total + clampedSize - 1) / clampedSize).toInt()

        return DocumentPage(
            content = rows,
            page = page,
            size = clampedSize,
            totalElements = total,
            totalPages = totalPages,
            hasNext = (page + 1) < totalPages,
        )
    }

    // ${sub 앞4자}/${yyyy/MM/dd}/${uuid}.${ext}
    private fun buildS3Key(ownerSub: String, docId: UUID, ext: String): String {
        val prefix = ownerSub.take(4).ifBlank { "anon" }
        val date = LocalDate.now().let { "${it.year}/${"%02d".format(it.monthValue)}/${"%02d".format(it.dayOfMonth)}" }
        val suffix = if (ext.isNotBlank()) "$docId.$ext" else docId.toString()
        return "$prefix/$date/$suffix"
    }
}

class UnsupportedMediaTypeException(message: String) : RuntimeException(message)

/** GET /documents 응답 페이지 */
data class DocumentPage(
    val content: List<DocumentListRow>,
    val page: Int,
    val size: Int,
    val totalElements: Long,
    val totalPages: Int,
    val hasNext: Boolean,
)
