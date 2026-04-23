package kr.ocr.upload

import org.slf4j.LoggerFactory
import org.springframework.stereotype.Service

/**
 * OCR 결과 items 에서 민감 패턴(RRN)을 탐지하고 fpe-service 로 토큰화하는 서비스.
 *
 * 설계 결정:
 *  - RRN 패턴: \b\d{6}-\d{7}\b — 13자리 하이픈 포함 형식만 매칭.
 *    전화번호·카드번호 오탐 방지를 위해 보수적 패턴 사용.
 *  - 실패 시 데이터 저장 금지 정책: FpeCallException 을 그대로 전파하여
 *    호출자(OcrTriggerService)가 OCR_FAILED 로 상태를 전이하도록 위임.
 *  - FPE_TOKENIZATION_ENABLED=false 시 items 원본 + count=0 반환 (no-op).
 *
 * @param fpeClient fpe-service HTTP 클라이언트
 * @param props     ocr.fpe.* 설정
 */
@Service
class TokenizationService(
    private val fpeClient: FpeClient,
    private val props: OcrProperties,
) {

    private val log = LoggerFactory.getLogger(TokenizationService::class.java)

    companion object {
        /** 주민등록번호 패턴: 앞 6자리 - 뒤 7자리 */
        private val RRN_PATTERN = Regex("""\b(\d{6})-(\d{7})\b""")
    }

    /**
     * OCR items 의 민감 필드를 토큰으로 교체한다.
     *
     * @param items OCR 결과 항목 목록
     * @return Pair<토큰화된 items, 토큰화된 고유 값 수>
     * @throws FpeCallException fpe-service 호출 실패 시 (호출자가 OCR_FAILED 처리)
     */
    fun tokenizeSensitiveFields(items: List<OcrItem>): Pair<List<OcrItem>, Int> {
        if (!props.fpe.enabled) {
            log.debug("FPE 토큰화 비활성화됨 (ocr.fpe.enabled=false). 원본 items 반환.")
            return Pair(items, 0)
        }

        // 1. 모든 item 에서 RRN 값 수집
        val allRrns = mutableListOf<String>()
        items.forEach { item ->
            RRN_PATTERN.findAll(item.text).forEach { m -> allRrns.add(m.value) }
        }

        if (allRrns.isEmpty()) {
            log.debug("민감 필드 없음 — 토큰화 스킵")
            return Pair(items, 0)
        }

        val uniqueRrns = allRrns.distinct()
        log.info("RRN {} 건 탐지 (고유 {} 건) — fpe-service 토큰화 요청", allRrns.size, uniqueRrns.size)

        // 2. fpe-service 배치 호출 — 실패 시 FpeCallException 전파 (저장 차단)
        val batchItems = uniqueRrns.map { FpeTokenizeItem(type = "rrn", value = it) }
        val response = fpeClient.tokenizeBatch(batchItems)

        if (response.tokens.size != uniqueRrns.size) {
            throw FpeCallException(
                "fpe-service 응답 토큰 수 불일치: 요청=${uniqueRrns.size}, 응답=${response.tokens.size}"
            )
        }

        // 3. 원본 → 토큰 매핑 구성
        val mapping: Map<String, String> = uniqueRrns
            .zip(response.tokens.map { it.token })
            .toMap()

        log.debug("토큰 매핑 완료: {}", mapping.keys.map { "***" })  // 원본 RRN 로그 기록 금지

        // 4. items 내 RRN 치환
        val tokenizedItems = items.map { item ->
            var text = item.text
            for ((original, token) in mapping) {
                text = text.replace(original, token)
            }
            item.copy(text = text)
        }

        log.info("민감 필드 토큰화 완료: {} 건", mapping.size)
        return Pair(tokenizedItems, mapping.size)
    }
}
