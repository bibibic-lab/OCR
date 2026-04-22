package kr.ocr.upload

import org.slf4j.LoggerFactory
import org.springframework.boot.context.event.ApplicationReadyEvent
import org.springframework.context.event.EventListener
import org.springframework.stereotype.Component
import software.amazon.awssdk.services.s3.S3Client
import software.amazon.awssdk.services.s3.model.BucketAlreadyExistsException
import software.amazon.awssdk.services.s3.model.BucketAlreadyOwnedByYouException

/**
 * 애플리케이션 기동 시 S3 업로드 버킷을 멱등 생성.
 *
 * S3Config 에서 분리한 이유:
 *  - @Configuration 클래스 내에서 @Bean 메서드를 직접 호출하면 Kotlin 에서는
 *    CGLIB 인터셉션이 보장되지 않아 새 S3Client 인스턴스가 누수됨.
 *  - 이 컴포넌트는 s3Client 빈을 생성자 주입받아 단일 공유 인스턴스를 사용한다.
 */
@Component
class S3BucketInitializer(
    private val s3Client: S3Client,
    private val props: OcrProperties,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    @EventListener(ApplicationReadyEvent::class)
    fun ensureBucketExists() {
        val bucket = props.s3.bucket
        try {
            s3Client.createBucket { it.bucket(bucket) }
            log.info("S3 버킷 생성 완료: {}", bucket)
        } catch (e: BucketAlreadyOwnedByYouException) {
            log.debug("S3 버킷 이미 존재 (소유): {}", bucket)
        } catch (e: BucketAlreadyExistsException) {
            log.debug("S3 버킷 이미 존재: {}", bucket)
        } catch (e: Exception) {
            // 기동 시점 연결 불가(로컬 개발 등)는 경고만 — 서비스 기동을 막지 않음
            log.warn("S3 버킷 확인 실패 (ignore in dev): {}", e.message)
        }
    }
}
