package kr.ocr.upload

import jakarta.validation.constraints.NotBlank
import org.springframework.boot.context.properties.ConfigurationProperties
import org.springframework.boot.context.properties.bind.DefaultValue
import org.springframework.validation.annotation.Validated

/**
 * ocr.s3.*, ocr.ocr-worker.*, ocr.fpe.* 를 바인딩하는 설정 클래스.
 *
 * @EnableConfigurationProperties(OcrProperties::class) 또는
 * @ConfigurationPropertiesScan 에 의해 등록된다.
 */
@Validated
@ConfigurationProperties(prefix = "ocr")
data class OcrProperties(
    val s3: S3Props,
    val ocrWorker: OcrWorkerProps,
    val fpe: FpeProps = FpeProps(),
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

    /**
     * FPE(Format-Preserving Encryption) 토큰화 서비스 설정.
     *
     * enabled=false 시 토큰화 없이 원본 OCR 결과를 그대로 저장 (점진적 롤아웃 지원).
     * enabled=true  시 RRN 탐지 → fpe-service 호출 → 실패 시 저장 차단.
     */
    data class FpeProps(
        /** 토큰화 기능 활성 여부 (점진적 롤아웃 feature flag) */
        @DefaultValue("true") val enabled: Boolean = true,
        /** fpe-service 베이스 URL (cluster internal) */
        val serviceUrl: String = "http://fpe-service.security.svc.cluster.local",
        /** 연결·읽기 타임아웃 (ms) */
        @DefaultValue("10000") val timeoutMs: Long = 10_000L,
    )
}
