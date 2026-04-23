# ── Stage 1: builder ─────────────────────────────────────────────────────────
FROM gradle:8.7-jdk21 AS builder

WORKDIR /workspace

# 의존성 캐시 레이어: build 스크립트만 먼저 복사
COPY build.gradle.kts settings.gradle.kts gradle.properties ./
COPY gradle ./gradle

# 의존성 다운로드 (소스 변경 시 이 레이어는 캐시 히트)
RUN gradle dependencies --no-daemon -q 2>/dev/null || true

# 소스 전체 복사 후 bootJar 빌드 (테스트 제외 — 통합테스트는 클러스터 연결 필요)
COPY src ./src
RUN gradle bootJar --no-daemon -x test

# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM eclipse-temurin:21-jre-jammy

# 비루트 사용자 (UID 1000)
RUN groupadd -g 1000 appgroup && useradd -u 1000 -g appgroup -m -s /bin/sh appuser

WORKDIR /app

# JAR 복사
COPY --from=builder /workspace/build/libs/*.jar app.jar

# 엔트리포인트 복사 (CA 주입 + JVM 실행)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ocr-internal CA 마운트 포인트 디렉터리 + cacerts 쓰기 권한 허용 (keytool 실행 위해)
RUN mkdir -p /etc/ssl/ocr-internal \
  && chown -R appuser:appgroup /etc/ssl/ocr-internal /app \
  && chmod 664 /opt/java/openjdk/lib/security/cacerts \
  && chown appuser:appgroup /opt/java/openjdk/lib/security/cacerts

USER 1000

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
