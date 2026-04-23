package kr.ocr.intgr.config

import org.apache.camel.CamelContext
import org.apache.camel.spring.boot.CamelContextConfiguration
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration

/**
 * Camel 컨텍스트 전역 설정.
 *
 * 주요 조정:
 * - streamCaching: 응답 body를 메모리에 캐시하여 재처리 허용
 * - shutdownTimeout: 그레이스풀 셧다운 최대 10초
 * - exchangeFormatter: 로그 출력 길이 제한 (PII 노출 최소화)
 */
@Configuration
class CamelConfig {

    @Bean
    fun camelContextConfiguration(): CamelContextConfiguration {
        return object : CamelContextConfiguration {
            override fun beforeApplicationStart(camelContext: CamelContext) {
                camelContext.isStreamCaching = true
                camelContext.shutdownStrategy.timeout = 10
                camelContext.globalOptions["CamelLogDebugBodyMaxChars"] = "512"
            }

            override fun afterApplicationStart(camelContext: CamelContext) {
                // no-op
            }
        }
    }
}
