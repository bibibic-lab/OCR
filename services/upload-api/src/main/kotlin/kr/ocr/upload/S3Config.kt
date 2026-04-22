package kr.ocr.upload

import org.springframework.boot.context.properties.EnableConfigurationProperties
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider
import software.amazon.awssdk.regions.Region
import software.amazon.awssdk.services.s3.S3Client
import java.net.URI

/**
 * AWS SDK v2 S3Client 빈 설정.
 * - SeaweedFS S3 anonymous 모드: path-style 필수, 임의 credentials.
 *
 * 버킷 초기화는 S3BucketInitializer 가 담당한다.
 * 이 클래스에서 s3Client()를 직접 호출하면 CGLIB 프록시를 우회하여
 * 새 S3Client 인스턴스가 생성되므로 분리 설계함.
 */
@Configuration
@EnableConfigurationProperties(OcrProperties::class)
class S3Config(private val props: OcrProperties) {

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
}
