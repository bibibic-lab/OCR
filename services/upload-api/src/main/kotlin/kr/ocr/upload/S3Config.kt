package kr.ocr.upload

import org.slf4j.LoggerFactory
import org.springframework.boot.context.properties.EnableConfigurationProperties
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.context.event.EventListener
import org.springframework.boot.context.event.ApplicationReadyEvent
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider
import software.amazon.awssdk.regions.Region
import software.amazon.awssdk.services.s3.S3Client
import software.amazon.awssdk.services.s3.model.BucketAlreadyExistsException
import software.amazon.awssdk.services.s3.model.BucketAlreadyOwnedByYouException
import software.amazon.awssdk.services.s3.model.CreateBucketRequest
import java.net.URI

/**
 * AWS SDK v2 S3Client 빈 설정.
 * - SeaweedFS S3 anonymous 모드: path-style 필수, 임의 credentials.
 * - ApplicationReadyEvent 수신 시 업로드 버킷 auto-create (멱등).
 */
@Configuration
@EnableConfigurationProperties(OcrProperties::class)
class S3Config(private val props: OcrProperties) {

    private val log = LoggerFactory.getLogger(S3Config::class.java)

    @Bean
    fun s3Client(): S3Client {
        val creds = AwsBasicCredentials.create(
            props.s3.accessKey.ifBlank { "dev-access-key" },
            props.s3.secretKey.ifBlank { "dev-secret-key" },
        )
        return S3Client.builder()
            .endpointOverride(URI.create(props.s3.endpoint))
            .credentialsProvider(StaticCredentialsProvider.create(creds))
            .region(Region.of(props.s3.region))
            .forcePathStyle(props.s3.pathStyle)
            .build()
    }

    @EventListener(ApplicationReadyEvent::class)
    fun ensureBucketExists() {
        val bucket = props.s3.bucket
        try {
            s3Client().createBucket(CreateBucketRequest.builder().bucket(bucket).build())
            log.info("S3 버킷 생성 완료: {}", bucket)
        } catch (e: BucketAlreadyOwnedByYouException) {
            log.debug("S3 버킷 이미 존재: {}", bucket)
        } catch (e: BucketAlreadyExistsException) {
            log.debug("S3 버킷 이미 존재: {}", bucket)
        } catch (e: Exception) {
            // 기동 시점 연결 불가(로컬 개발 등)는 경고만 — 서비스 기동을 막지 않음
            log.warn("S3 버킷 확인 실패 (ignore in dev): {}", e.message)
        }
    }
}
