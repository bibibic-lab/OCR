package kr.ocr.upload

import com.fasterxml.jackson.annotation.JsonIgnoreProperties
import com.fasterxml.jackson.databind.ObjectMapper
import org.slf4j.LoggerFactory
import org.springframework.core.io.ByteArrayResource
import org.springframework.http.MediaType
import org.springframework.http.client.SimpleClientHttpRequestFactory
import org.springframework.stereotype.Component
import org.springframework.util.LinkedMultiValueMap
import org.springframework.web.client.RestClient

/**
 * ocr-worker 의 POST /ocr 엔드포인트를 호출하는 HTTP 클라이언트.
 *
 * 설계 선택: RestClient (동기) 사용
 *  - @Async 메서드 안에서 호출되므로 비동기성은 스레드풀 수준에서 이미 확보됨.
 *  - WebClient(reactive)보다 단순하고 WebFlux 의존성 없이 동작.
 *
 * 타임아웃: OcrProperties.ocrWorker.timeoutMs (기본 60,000 ms)
 *
 * 기대 응답 JSON (ocr-worker server.py 기준):
 * {
 *   "filename": "...",
 *   "engine":   "EasyOCR 1.7.1",
 *   "langs":    ["ko","en"],
 *   "count":    5,
 *   "items": [{"text":"...","confidence":0.9998,"bbox":[[x,y],...]}]
 * }
 */
@Component
class OcrClient(
    private val props: OcrProperties,
    private val objectMapper: ObjectMapper,
) {

    private val log = LoggerFactory.getLogger(OcrClient::class.java)

    private val restClient: RestClient = buildRestClient()

    private fun buildRestClient(): RestClient {
        val factory = SimpleClientHttpRequestFactory().apply {
            setConnectTimeout(props.ocrWorker.timeoutMs.toInt())
            setReadTimeout(props.ocrWorker.timeoutMs.toInt())
        }
        return RestClient.builder()
            .baseUrl(props.ocrWorker.baseUrl)
            .requestFactory(factory)
            .build()
    }

    /**
     * @param fileBytes S3에서 읽어 온 파일 원본 바이트
     * @param filename  원본 파일명 (Content-Disposition 용)
     * @return OCR 결과 DTO
     * @throws OcrCallException 네트워크 오류, 4xx/5xx, JSON 파싱 실패 포함
     */
    fun callOcr(fileBytes: ByteArray, filename: String): OcrResponse {
        log.debug("OCR worker POST /ocr 호출: filename={}, bytes={}", filename, fileBytes.size)

        val body = LinkedMultiValueMap<String, Any>().apply {
            val resource = object : ByteArrayResource(fileBytes) {
                override fun getFilename() = filename
            }
            add("file", resource)
        }

        val rawJson = try {
            restClient.post()
                .uri("/ocr")
                .contentType(MediaType.MULTIPART_FORM_DATA)
                .body(body)
                .retrieve()
                .onStatus({ it.is4xxClientError || it.is5xxServerError }) { _, response ->
                    val statusCode = response.statusCode.value()
                    val bodyText = runCatching { response.body.bufferedReader().readText() }.getOrDefault("")
                    throw OcrCallException("OCR worker 오류 응답: status=$statusCode body=$bodyText")
                }
                .body(String::class.java)
                ?: throw OcrCallException("OCR worker 응답 body 가 비어 있습니다.")
        } catch (e: OcrCallException) {
            throw e
        } catch (e: Exception) {
            throw OcrCallException("OCR worker 네트워크/타임아웃 오류: ${e.message}", e)
        }

        return try {
            objectMapper.readValue(rawJson, OcrResponse::class.java)
        } catch (e: Exception) {
            throw OcrCallException("OCR worker 응답 JSON 파싱 실패: $rawJson", e)
        }
    }
}

/** ocr-worker 응답 DTO */
@JsonIgnoreProperties(ignoreUnknown = true)
data class OcrResponse(
    val filename: String = "",
    val engine: String = "",
    val langs: List<String> = emptyList(),
    val count: Int = 0,
    val items: List<OcrItem> = emptyList(),
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class OcrItem(
    val text: String = "",
    val confidence: Double = 0.0,
    val bbox: List<List<Double>> = emptyList(),
)

class OcrCallException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)
