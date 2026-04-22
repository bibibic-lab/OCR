package kr.ocr.upload

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.context.properties.ConfigurationPropertiesScan
import org.springframework.boot.runApplication

@SpringBootApplication
@ConfigurationPropertiesScan
class UploadApiApplication

fun main(args: Array<String>) {
    runApplication<UploadApiApplication>(*args)
}
