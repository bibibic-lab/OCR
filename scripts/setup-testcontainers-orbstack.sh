#!/usr/bin/env bash
# setup-testcontainers-orbstack.sh
#
# OrbStack 사용 환경에서 Testcontainers 가 Docker 소켓을 인식하도록
# ~/.testcontainers.properties 를 멱등 설정하는 스크립트.
#
# 실행 조건: macOS + OrbStack 설치
# 참조: services/upload-api/README.md — "Local Test Setup (OrbStack)"
#
# 사용법:
#   bash scripts/setup-testcontainers-orbstack.sh

set -euo pipefail

PROPS_FILE="${HOME}/.testcontainers.properties"

# ── 1. OrbStack 소켓 경로 결정 ─────────────────────────────────────────────
ORBSTACK_SOCK="${HOME}/.orbstack/run/docker.sock"
DEFAULT_SOCK="/var/run/docker.sock"

if [[ -S "${ORBSTACK_SOCK}" ]]; then
    DOCKER_HOST_VALUE="unix://${ORBSTACK_SOCK}"
    echo "[info] OrbStack 소켓 발견: ${ORBSTACK_SOCK}"
elif [[ -S "${DEFAULT_SOCK}" ]]; then
    DOCKER_HOST_VALUE="unix://${DEFAULT_SOCK}"
    echo "[info] 기본 Docker 소켓 사용: ${DEFAULT_SOCK}"
else
    echo "[warn] Docker 소켓을 찾을 수 없습니다."
    echo "       OrbStack 이 실행 중인지 확인하세요."
    echo "       수동으로 ~/.testcontainers.properties 를 설정할 수 있습니다."
    echo "       참조: services/upload-api/README.md"
    exit 1
fi

# ── 2. 프로퍼티 파일 생성 (없으면) ────────────────────────────────────────
touch "${PROPS_FILE}"

# ── 3. docker.host 설정 (이미 존재하면 건너뜀) ────────────────────────────
if grep -q "^docker\.host=" "${PROPS_FILE}" 2>/dev/null; then
    EXISTING=$(grep "^docker\.host=" "${PROPS_FILE}")
    echo "[skip] docker.host 이미 설정됨: ${EXISTING}"
else
    echo "docker.host=${DOCKER_HOST_VALUE}" >> "${PROPS_FILE}"
    echo "[added] docker.host=${DOCKER_HOST_VALUE}"
fi

# ── 4. ryuk.disabled 설정 (이미 존재하면 건너뜀) ──────────────────────────
if grep -q "^ryuk\.disabled=" "${PROPS_FILE}" 2>/dev/null; then
    EXISTING=$(grep "^ryuk\.disabled=" "${PROPS_FILE}")
    echo "[skip] ryuk.disabled 이미 설정됨: ${EXISTING}"
else
    echo "ryuk.disabled=true" >> "${PROPS_FILE}"
    echo "[added] ryuk.disabled=true"
fi

echo ""
echo "설정 완료: ${PROPS_FILE}"
echo "─────────────────────────────────────"
cat "${PROPS_FILE}"
echo "─────────────────────────────────────"
echo ""
echo "이제 ./gradlew test 를 실행하면 Testcontainers 가 OrbStack 을 사용합니다."
