package kr.ocr.upload

import jakarta.validation.constraints.NotBlank
import org.springframework.boot.context.properties.ConfigurationProperties
import org.springframework.boot.context.properties.bind.DefaultValue
import org.springframework.validation.annotation.Validated

/**
 * ocr.s3.*, ocr.ocr-worker.*, ocr.fpe.*, ocr.not-implemented.* 를 바인딩하는 설정 클래스.
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
    val notImplemented: List<NotImplementedItem> = emptyList(),
) {

    /**
     * POLICY-NI-01: Not Implemented 기능 항목.
     * 관리 대시보드에 표시되며 실 구현 대기 기능 목록을 유지한다.
     */
    data class NotImplementedItem(
        val feature: String,
        val reason: String,
        val guideRef: String,
    )
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
