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

/**
 * 파일 업로드 비즈니스 로직.
 *
 * 책임:
 *  1. Content-Type 허용 목록 검증
 *  2. S3 키 계산 (sub 앞 4자 파티션 / yyyy/MM/dd / uuid.ext)
 *  3. DigestInputStream으로 S3 스트리밍 + SHA-256 동시 계산 (Option A)
 *  4. document 테이블 INSERT (status=UPLOADED)
 *  5. 신규 document id 반환
 */
@Service
class DocumentService(
    private val s3Client: S3Client,
    private val documentRepository: DocumentRepository,
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
        val ext = file.originalFilename?.substringAfterLast('.', "") ?: ""
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
        documentRepository.insert(row)
        log.info("문서 업로드 완료: id={}, owner={}, key={}", docId, ownerSub, s3Key)
        return docId
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
