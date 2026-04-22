package kr.ocr.upload

import jakarta.validation.constraints.NotBlank
import org.springframework.boot.context.properties.ConfigurationProperties
import org.springframework.boot.context.properties.bind.DefaultValue
import org.springframework.validation.annotation.Validated

/**
 * ocr.s3.* 와 ocr.ocr-worker.* 를 바인딩하는 설정 클래스.
 *
 * @EnableConfigurationProperties(OcrProperties::class) 또는
 * @ConfigurationPropertiesScan 에 의해 등록된다.
 */
@Validated
@ConfigurationProperties(prefix = "ocr")
data class OcrProperties(
    val s3: S3Props,
    val ocrWorker: OcrWorkerProps,
) {
    data class S3Props(
        @field:NotBlank val endpoint: String,
        @field:NotBlank val region: String,
        @field:NotBlank val bucket: String,
        /** SeaweedFS anonymous 모드에서는 임의 값 허용 */
        val accessKey: String = "",
        val secretKey: String = "",
        @DefaultValue("true") val pathStyle: Boolean = true,
    )

    data class OcrWorkerProps(
        @field:NotBlank val baseUrl: String,
        @DefaultValue("60000") val timeoutMs: Long = 60_000L,
    )
}
