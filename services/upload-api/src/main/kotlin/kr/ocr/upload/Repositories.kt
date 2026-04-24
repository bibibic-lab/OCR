package kr.ocr.upload

import org.postgresql.util.PGobject
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Repository
import java.time.Instant
import java.time.OffsetDateTime
import java.util.UUID

/**
 * document 테이블에 대한 CRUD 레포지터리.
 *
 * jOOQ 코드 생성 없이 JdbcTemplate 사용 (T3 Walking Skeleton 수준).
 * T4/T5에서 jOOQ 코드 생성 파이프라인 추가 시 교체 가능.
 */
@Repository
class DocumentRepository(private val jdbc: JdbcTemplate) {

    fun insert(doc: DocumentRow): Int = jdbc.update(
        """
        INSERT INTO document
          (id, owner_sub, filename, content_type, byte_size, sha256_hex,
           s3_bucket, s3_key, status, uploaded_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """.trimIndent(),
        doc.id,
        doc.ownerSub,
        doc.filename,
        doc.contentType,
        doc.byteSize,
        doc.sha256Hex,
        doc.s3Bucket,
        doc.s3Key,
        doc.status,
        doc.uploadedAt,
    )

    fun findById(id: UUID): DocumentRow? = jdbc.query(
        "SELECT * FROM document WHERE id = ?",
        { rs, _ ->
            DocumentRow(
                id = UUID.fromString(rs.getString("id")),
                ownerSub = rs.getString("owner_sub"),
                filename = rs.getString("filename"),
                contentType = rs.getString("content_type"),
                byteSize = rs.getLong("byte_size"),
                sha256Hex = rs.getString("sha256_hex"),
                s3Bucket = rs.getString("s3_bucket"),
                s3Key = rs.getString("s3_key"),
                status = rs.getString("status"),
                uploadedAt = rs.getObject("uploaded_at", OffsetDateTime::class.java),
                ocrFinishedAt = rs.getObject("ocr_finished_at", OffsetDateTime::class.java),
            )
        },
        id,
    ).firstOrNull()

    /** OCR 처리 시작 시 status → OCR_RUNNING */
    fun updateStatusRunning(id: UUID): Int = jdbc.update(
        "UPDATE document SET status = 'OCR_RUNNING' WHERE id = ?",
        id,
    )

    /** OCR 완료 시 status → OCR_DONE + ocr_finished_at 갱신 */
    fun updateStatusDone(id: UUID): Int = jdbc.update(
        "UPDATE document SET status = 'OCR_DONE', ocr_finished_at = NOW() WHERE id = ?",
        id,
    )

    /** OCR 실패 시 status → OCR_FAILED */
    fun updateStatusFailed(id: UUID): Int = jdbc.update(
        "UPDATE document SET status = 'OCR_FAILED' WHERE id = ?",
        id,
    )
}

data class DocumentRow(
    val id: UUID,
    val ownerSub: String,
    val filename: String,
    val contentType: String,
    val byteSize: Long,
    val sha256Hex: String,
    val s3Bucket: String,
    val s3Key: String,
    val status: String,
    val uploadedAt: OffsetDateTime = OffsetDateTime.now(),
    val ocrFinishedAt: OffsetDateTime? = null,
)

/**
 * ocr_result 테이블에 대한 레포지터리.
 *
 * JSONB 컬럼(items_json)은 PGobject 로 삽입하고, 조회 시 getString() 으로 반환.
 */
@Repository
class OcrResultRepository(private val jdbc: JdbcTemplate) {

    fun insert(result: OcrResultRow): Int {
        val jsonbValue = PGobject().apply {
            type = "jsonb"
            value = result.itemsJson
        }
        return jdbc.update(
            """
            INSERT INTO ocr_result
              (document_id, engine, langs, items_json, sensitive_fields_tokenized, tokenized_count)
            VALUES (?, ?, ?, ?, ?, ?)
            """.trimIndent(),
            result.documentId,
            result.engine,
            result.langs,
            jsonbValue,
            result.sensitiveFieldsTokenized,
            result.tokenizedCount,
        )
    }

    fun findByDocumentId(documentId: UUID): OcrResultRow? = jdbc.query(
        "SELECT * FROM ocr_result WHERE document_id = ?",
        { rs, _ ->
            OcrResultRow(
                documentId = UUID.fromString(rs.getString("document_id")),
                engine = rs.getString("engine"),
                langs = rs.getString("langs"),
                itemsJson = rs.getString("items_json"),
                sensitiveFieldsTokenized = rs.getBoolean("sensitive_fields_tokenized"),
                tokenizedCount = rs.getInt("tokenized_count"),
                createdAt = rs.getObject("created_at", OffsetDateTime::class.java).toInstant(),
                updatedAt = rs.getObject("updated_at", OffsetDateTime::class.java),
                updatedBy = rs.getString("updated_by"),
                updateCount = rs.getInt("update_count"),
            )
        },
        documentId,
    ).firstOrNull()

    /**
     * OCR 결과 items 를 교체한다.
     *
     * @param documentId     대상 문서 UUID
     * @param itemsJson      직렬화된 JSONB 문자열 (재토큰화 완료)
     * @param sensitiveFieldsTokenized 재토큰화 적용 여부
     * @param tokenizedCount           토큰화된 고유 RRN 수
     * @param updatedBy      수정한 JWT subject
     * @return 영향받은 행 수 (0이면 row 없음)
     */
    fun update(
        documentId: UUID,
        itemsJson: String,
        sensitiveFieldsTokenized: Boolean,
        tokenizedCount: Int,
        updatedBy: String,
    ): Int {
        val jsonbValue = PGobject().apply {
            type = "jsonb"
            value = itemsJson
        }
        return jdbc.update(
            """
            UPDATE ocr_result
               SET items_json                = ?,
                   sensitive_fields_tokenized = ?,
                   tokenized_count            = ?,
                   updated_at                 = NOW(),
                   updated_by                 = ?,
                   update_count               = update_count + 1
             WHERE document_id = ?
            """.trimIndent(),
            jsonbValue,
            sensitiveFieldsTokenized,
            tokenizedCount,
            updatedBy,
            documentId,
        )
    }
}

data class OcrResultRow(
    val documentId: UUID,
    val engine: String,
    val langs: String,                         // comma-joined "ko,en"
    val itemsJson: String,                     // raw JSON string
    val sensitiveFieldsTokenized: Boolean = false,
    val tokenizedCount: Int = 0,
    val createdAt: Instant = Instant.now(),
    val updatedAt: OffsetDateTime? = null,
    val updatedBy: String? = null,
    val updateCount: Int = 0,
)
