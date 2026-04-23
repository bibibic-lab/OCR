#!/bin/sh
# entrypoint.sh — ocr-internal CA를 JVM truststore에 주입한 뒤 애플리케이션 기동.
set -e

CA_FILE="/etc/ssl/ocr-internal/ca.crt"
ALIAS="ocr-internal"
JAVA_HOME="${JAVA_HOME:-/opt/java/openjdk}"
KEYSTORE="${JAVA_HOME}/lib/security/cacerts"
STOREPASS="changeit"

if [ -f "${CA_FILE}" ]; then
  keytool -delete -noprompt -alias "${ALIAS}" \
    -keystore "${KEYSTORE}" -storepass "${STOREPASS}" 2>/dev/null || true

  keytool -importcert -noprompt \
    -alias "${ALIAS}" \
    -file "${CA_FILE}" \
    -keystore "${KEYSTORE}" \
    -storepass "${STOREPASS}"
  echo "[entrypoint] ocr-internal CA registered in JVM truststore."
else
  echo "[entrypoint] WARNING: ${CA_FILE} not found — skipping CA import."
fi

exec java \
  -XX:MaxRAMPercentage=75 \
  -XX:+UseG1GC \
  -Xss512k \
  -Dfile.encoding=UTF-8 \
  -jar /app/app.jar "$@"
