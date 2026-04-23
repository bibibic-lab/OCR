package kr.ocr.intgr

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication

@SpringBootApplication
class IntegrationHubApplication

fun main(args: Array<String>) {
    runApplication<IntegrationHubApplication>(*args)
}
