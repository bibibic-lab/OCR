package kr.ocr.upload

import com.fasterxml.jackson.annotation.JsonIgnoreProperties
import com.fasterxml.jackson.annotation.JsonProperty
import org.slf4j.LoggerFactory
import org.springframework.http.MediaType
import org.springframework.http.client.SimpleClientHttpRequestFactory
import org.springframework.stereotype.Component
import org.springframework.web.client.RestClient

/**
 * fpe-service 의 POST /tokenize-batch 엔드포인트를 호출하는 HTTP 클라이언트.
 *
 * 설계 선택:
 *  - RestClient(동기) — @Async 스레드풀 내에서 호출되므로 비동기성 불필요.
 *  - FPE_TOKENIZATION_ENABLED=false 일 때 bean 자체는 존재하지만 TokenizationService 가 호출하지 않음.
 *
 * 타임아웃: FpeProperties.timeoutMs (기본 10,000 ms)
 *
 * fpe-service /tokenize-batch 요청/응답 (dev, FPE_REQUIRE_AUTH=false):
 * Request:
 *   { "items": [ {"type":"rrn","value":"900101-1234567"}, ... ] }
 * Response:
 *   { "tokens": [ {"type":"rrn","token":"??????-???????","token_id":"uuid"}, ... ] }
 */
@Component
class FpeClient(private val props: OcrProperties) {

    private val log = LoggerFactory.getLogger(FpeClient::class.java)

    private val restClient: RestClient by lazy { buildRestClient() }

    private fun buildRestClient(): RestClient {
        val factory = SimpleClientHttpRequestFactory().apply {
            setConnectTimeout(props.fpe.timeoutMs.toInt())
            setReadTimeout(props.fpe.timeoutMs.toInt())
        }
        return RestClient.builder()
            .baseUrl(props.fpe.serviceUrl)
            .requestFactory(factory)
            .build()
    }

    /**
     * 배치 토큰화 요청.
     *
     * @param items 토큰화할 항목 목록 (type + value)
     * @return 토큰 목록 (요청 순서와 1:1 대응)
     * @throws FpeCallException 네트워크 오류, 4xx/5xx 응답 포함
     */
    fun tokenizeBatch(items: List<FpeTokenizeItem>): FpeBatchResponse {
        log.debug("FPE /tokenize-batch 호출: items={}", items.size)
        val request = FpeBatchRequest(items = items)

        return try {
            restClient.post()
                .uri("/tokenize-batch")
                .contentType(MediaType.APPLICATION_JSON)
                .body(request)
                .retrieve()
                .onStatus({ it.is4xxClientError || it.is5xxServerError }) { _, response ->
                    val statusCode = response.statusCode.value()
                    val bodyText = runCatching { response.body.bufferedReader().readText() }.getOrDefault("")
                    throw FpeCallException("fpe-service 오류 응답: status=$statusCode body=$bodyText")
                }
                .body(FpeBatchResponse::class.java)
                ?: throw FpeCallException("fpe-service 응답 body 가 비어 있습니다.")
        } catch (e: FpeCallException) {
            throw e
        } catch (e: Exception) {
            throw FpeCallException("fpe-service 네트워크/타임아웃 오류: ${e.message}", e)
        }
    }
}

// ── Request DTOs ──────────────────────────────────────────────────────────────

data class FpeBatchRequest(
    val items: List<FpeTokenizeItem>,
)

data class FpeTokenizeItem(
    val type: String,   // "rrn" | "card"
    val value: String,
)

// ── Response DTOs ─────────────────────────────────────────────────────────────

@JsonIgnoreProperties(ignoreUnknown = true)
data class FpeBatchResponse(
    val tokens: List<FpeTokenResult> = emptyList(),
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class FpeTokenResult(
    val type: String = "",
    val token: String = "",
    @JsonProperty("token_id") val tokenId: String = "",
)

class FpeCallException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)
