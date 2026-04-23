import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("org.springframework.boot") version "3.2.5"
    id("io.spring.dependency-management") version "1.1.4"
    kotlin("jvm") version "1.9.23"
    kotlin("plugin.spring") version "1.9.23"
}

group = "kr.ocr"
version = "0.1.0-SNAPSHOT"

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
}

repositories {
    mavenCentral()
}

// Apache Camel BOM
extra["camelVersion"] = "4.4.4"

dependencyManagement {
    imports {
        mavenBom("org.apache.camel.springboot:camel-spring-boot-bom:${property("camelVersion")}")
    }
}

dependencies {
    // Spring Boot
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    implementation("org.springframework.boot:spring-boot-starter-validation")

    // Kotlin
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin")
    implementation("org.jetbrains.kotlin:kotlin-reflect")
    implementation("org.jetbrains.kotlin:kotlin-stdlib-jdk8")

    // Apache Camel — core
    implementation("org.apache.camel.springboot:camel-spring-boot-starter")
    // HTTP client (외부 agency 호출)
    implementation("org.apache.camel.springboot:camel-http-starter")
    // Jackson JSON marshal/unmarshal in Camel
    implementation("org.apache.camel.springboot:camel-jackson-starter")

    // Resilience4j (Circuit Breaker / Bulkhead)
    implementation("io.github.resilience4j:resilience4j-spring-boot3:2.2.0")
    // Camel Resilience4j integration
    implementation("org.apache.camel.springboot:camel-resilience4j-starter")

    // BouncyCastle — TSA RFC 3161 scaffolding (no PKCS#11 in mock mode)
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.78.1")

    // Micrometer Prometheus
    implementation("io.micrometer:micrometer-registry-prometheus")

    // Test
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    // Camel test support
    testImplementation("org.apache.camel:camel-test-spring-junit5:${property("camelVersion")}")
    // WireMock for external agency stub in tests
    testImplementation("org.wiremock:wiremock-standalone:3.5.4")
}

tasks.withType<KotlinCompile> {
    kotlinOptions {
        freeCompilerArgs += "-Xjsr305=strict"
        jvmTarget = "21"
    }
}

tasks.withType<Test> {
    useJUnitPlatform()
}
