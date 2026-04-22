package kr.ocr.upload

import com.fasterxml.jackson.databind.ObjectMapper
import org.slf4j.LoggerFactory
import org.springframework.scheduling.annotation.Async
import org.springframework.stereotype.Service
import software.amazon.awssdk.services.s3.S3Client
import software.amazon.awssdk.services.s3.model.GetObjectRequest
import java.util.UUID

/**
 * OCR 트리거 비동기 서비스.
 *
 * 설계 선택: DocumentService 와 별도 빈으로 분리
 *  - @Async 는 Spring AOP 프록시를 통해야만 동작한다.
 *    동일 빈 내부 self-invocation(this.method()) 은 프록시를 우회하여 비동기가 적용되지 않음.
 *  - 따라서 DocumentService → OcrTriggerService 주입 후 triggerAsync() 호출 패턴 사용.
 *
 * 상태 전이:
 *  UPLOADED → OCR_RUNNING → OCR_DONE  (성공)
 *                          → OCR_FAILED (실패: 네트워크, 5xx, JSON 파싱 오류, S3 fetch 실패)
 *
 * 재시도: T4 스코프 외. T5 이후 추가 예정.
 */
@Service
class OcrTriggerService(
    private val documentRepository: DocumentRepository,
    private val ocrResultRepository: OcrResultRepository,
    private val s3Client: S3Client,
    private val ocrClient: OcrClient,
    private val objectMapper: ObjectMapper,
    private val props: OcrProperties,
) {

    private val log = LoggerFactory.getLogger(OcrTriggerService::class.java)

    /**
     * 비동기 OCR 처리. ocrTriggerExecutor 풀에서 실행.
     *
     * @param documentId 처리할 문서 UUID
     */
    @Async("ocrTriggerExecutor")
    fun triggerAsync(documentId: UUID) {
        log.info("OCR 트리거 시작: documentId={}", documentId)

        // 1. 상태 → OCR_RUNNING
        documentRepository.updateStatusRunning(documentId)

        // 2. 문서 row 조회 (S3 key, filename 추출)
        val doc = documentRepository.findById(documentId)
        if (doc == null) {
            log.error("OCR 트리거 실패: 문서를 찾을 수 없음 documentId={}", documentId)
            documentRepository.updateStatusFailed(documentId)
            return
        }

        // 3. S3에서 원본 파일 바이트 로드
        val fileBytes = try {
            s3Client.getObjectAsBytes(
                GetObjectRequest.builder()
                    .bucket(doc.s3Bucket)
                    .key(doc.s3Key)
                    .build()
            ).asByteArray()
        } catch (e: Exception) {
            log.error("OCR 트리거 실패: S3 조회 오류 documentId={} key={}", documentId, doc.s3Key, e)
            documentRepository.updateStatusFailed(documentId)
            return
        }

        // 4. OCR worker 호출
        val ocrResponse = try {
            ocrClient.callOcr(fileBytes, doc.filename)
        } catch (e: OcrCallException) {
            log.error("OCR 트리거 실패: worker 오류 documentId={}", documentId, e)
            documentRepository.updateStatusFailed(documentId)
            return
        } catch (e: Exception) {
            log.error("OCR 트리거 실패: 예상치 못한 오류 documentId={}", documentId, e)
            documentRepository.updateStatusFailed(documentId)
            return
        }

        // 5. ocr_result 삽입 + document 상태 → OCR_DONE
        try {
            val itemsJson = objectMapper.writeValueAsString(ocrResponse.items)
            val resultRow = OcrResultRow(
                documentId = documentId,
                engine = ocrResponse.engine,
                langs = ocrResponse.langs.joinToString(","),
                itemsJson = itemsJson,
            )
            ocrResultRepository.insert(resultRow)
            documentRepository.updateStatusDone(documentId)
            log.info("OCR 완료: documentId={}, engine={}, items={}", documentId, ocrResponse.engine, ocrResponse.count)
        } catch (e: Exception) {
            log.error("OCR 트리거 실패: DB 저장 오류 documentId={}", documentId, e)
            documentRepository.updateStatusFailed(documentId)
        }
    }
}
