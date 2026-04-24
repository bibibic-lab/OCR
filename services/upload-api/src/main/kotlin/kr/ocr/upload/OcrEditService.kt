package kr.ocr.upload

import com.fasterxml.jackson.databind.ObjectMapper
import org.slf4j.LoggerFactory
import org.springframework.stereotype.Service
import java.util.UUID

/**
 * OCR 결과 items 수정 비즈니스 로직.
 *
 * 책임:
 *  1. 문서 존재 검증 (404)
 *  2. 소유권 검증 — JWT subject == document.owner_sub (403)
 *  3. 상태 검증 — OCR_DONE 만 편집 가능 (400)
 *  4. RRN 재토큰화 — TokenizationService 재사용 (POLICY-NI-01 유지)
 *  5. DB 업데이트 — OcrResultRepository.update (updated_at, updated_by, update_count 포함)
 */
@Service
class OcrEditService(
    private val documentRepository: DocumentRepository,
    private val ocrResultRepository: OcrResultRepository,
    private val tokenizationService: TokenizationService,
    private val objectMapper: ObjectMapper,
) {

    private val log = LoggerFactory.getLogger(OcrEditService::class.java)

    /**
     * OCR 결과 items 전체 교체.
     *
     * @param documentId 대상 문서 UUID
     * @param ownerSub   요청 JWT subject
     * @param newItems   교체할 items (클라이언트 제공)
     * @return EditResult sealed class (성공/404/403/400)
     */
    fun updateItems(documentId: UUID, ownerSub: String, newItems: List<OcrItem>): EditResult {
        val doc = documentRepository.findById(documentId)
            ?: return EditResult.NotFound

        if (doc.ownerSub != ownerSub) {
            log.warn("OCR 결과 수정 접근 거부: documentId={}, requester={}, owner={}", documentId, ownerSub, doc.ownerSub)
            return EditResult.Forbidden
        }

        if (doc.status != "OCR_DONE") {
            log.warn("OCR 결과 수정 불가 상태: documentId={}, status={}", documentId, doc.status)
            return EditResult.InvalidStatus(doc.status)
        }

        // RRN 재토큰화 (POLICY 유지)
        val (tokenizedItems, tokenizedCount) = tokenizationService.tokenizeSensitiveFields(newItems)
        val sensitiveFieldsTokenized = tokenizedCount > 0

        val itemsJson = objectMapper.writeValueAsString(tokenizedItems)

        val updated = ocrResultRepository.update(
            documentId = documentId,
            itemsJson = itemsJson,
            sensitiveFieldsTokenized = sensitiveFieldsTokenized,
            tokenizedCount = tokenizedCount,
            updatedBy = ownerSub,
        )

        if (updated == 0) {
            log.error("OCR 결과 UPDATE 실패 — ocr_result 행 없음: documentId={}", documentId)
            return EditResult.NotFound
        }

        log.info("OCR 결과 수정 완료: documentId={}, owner={}, items={}, tokenizedCount={}", documentId, ownerSub, tokenizedItems.size, tokenizedCount)

        val updatedRow = ocrResultRepository.findByDocumentId(documentId)
            ?: return EditResult.NotFound

        return EditResult.Success(doc = doc, row = updatedRow)
    }
}

/** OCR 결과 수정 결과 타입 */
sealed class EditResult {
    object NotFound : EditResult()
    object Forbidden : EditResult()
    data class InvalidStatus(val currentStatus: String) : EditResult()
    data class Success(val doc: DocumentRow, val row: OcrResultRow) : EditResult()
}
