package kr.ocr.upload

import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.scheduling.annotation.EnableAsync
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor
import java.util.concurrent.Executor

/**
 * @Async 를 활성화하고 OCR 트리거 전용 스레드풀을 등록한다.
 *
 * SimpleAsyncTaskExecutor(기본값)는 호출 때마다 스레드를 생성하여 unbounded.
 * 여기서는 bounded pool 을 사용해 OOM·Thread 폭증을 방지한다.
 *
 * 설정값 근거:
 *  - corePoolSize=2   : 동시 OCR 처리 최소 병렬도 (Walking Skeleton 수준)
 *  - maxPoolSize=5    : 순간 spike 허용 최대치
 *  - queueCapacity=50 : 대기열 한계 초과 시 TaskRejectedException → 호출자에서 처리
 *
 * bean name "ocrTriggerExecutor" 를 @Async("ocrTriggerExecutor") 에서 참조.
 */
@Configuration
@EnableAsync
class AsyncConfig {

    @Bean("ocrTriggerExecutor")
    fun ocrTriggerExecutor(): Executor = ThreadPoolTaskExecutor().apply {
        corePoolSize = 2
        maxPoolSize = 5
        queueCapacity = 50
        setThreadNamePrefix("ocr-trigger-")
        setTaskDecorator { runnable ->
            val contextMap = org.slf4j.MDC.getCopyOfContextMap()
            Runnable {
                try {
                    if (contextMap != null) org.slf4j.MDC.setContextMap(contextMap)
                    runnable.run()
                } finally {
                    org.slf4j.MDC.clear()
                }
            }
        }
        initialize()
    }
}
