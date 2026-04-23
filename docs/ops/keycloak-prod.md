# Keycloak 프로덕션 모드 Runbook

- 작성일: 2026-04-22
- 적용 환경: `admin` namespace, Keycloak 26.3.3 (bitnamilegacy), Helm chart 25.2.0
- 관련 파일: `infra/helm/values/dev/keycloak.yaml`

---

## 1. 현재 구성 요약

| 항목 | 값 |
|------|-----|
| 기동 명령 | `start` (프로덕션 모드) — `start-dev` 아님 |
| `KEYCLOAK_PRODUCTION` | `true` |
| `KC_HOSTNAME` | `keycloak.admin.svc.cluster.local` |
| `KC_HOSTNAME_STRICT` | `true` |
| `KC_HOSTNAME_STRICT_HTTPS` | `true` |
| `KC_HTTP_ENABLED` | `false` (HTTPS 전용) |
| `KC_PROXY` | `edge` |
| `KC_METRICS_ENABLED` | `true` |
| `KC_HEALTH_ENABLED` | `true` |
| `KC_CACHE` | `ispn` (Infinispan JDBC-Ping) |
| TLS | cert-manager 발급 `keycloak-tls` Secret |
| TLS SAN | `keycloak`, `keycloak.admin`, `keycloak.admin.svc`, `keycloak.admin.svc.cluster.local` |

---

## 2. issuer 고정

`KC_HOSTNAME_STRICT=true` 설정으로 모든 realm의 issuer가 아래로 고정됩니다.

```
https://keycloak.admin.svc.cluster.local/realms/<realm-name>
```

**주의**: port-forward(`localhost:8443`) 접근 시 issuer 불일치 발생 → 토큰 검증 실패.  
클러스터 외부에서 검증이 필요한 경우:
- `--resolve keycloak.admin.svc.cluster.local:8443:127.0.0.1` curl 옵션 사용
- 또는 클러스터 내부 파드에서 직접 curl

---

## 3. 헬스 / 메트릭 엔드포인트

관리 포트 9000 (HTTPS, `-k` 필요):

```bash
# 헬스 체크
kubectl -n admin exec keycloak-0 -- curl -sk https://localhost:9000/health
kubectl -n admin exec keycloak-0 -- curl -sk https://localhost:9000/health/ready

# Prometheus 메트릭
kubectl -n admin exec keycloak-0 -- curl -sk https://localhost:9000/metrics | head -30
```

기대 응답:
```json
{
    "status": "UP",
    "checks": [
        {"name": "Keycloak database connections async health check", "status": "UP"}
    ]
}
```

---

## 4. 이벤트 로깅 (OCR realm)

Phase 1 Low #3 적용 후 OCR realm 이벤트 로깅이 활성화되어 있습니다.

| 항목 | 값 |
|------|-----|
| `eventsEnabled` | `true` |
| `adminEventsEnabled` | `true` |
| `adminEventsDetailsEnabled` | `true` |
| `eventsExpiration` | 2592000초 (30일) |
| `eventsListeners` | `jboss-logging`, `keycloak-events-listener` |

### 이벤트 로깅 상태 확인

```bash
# kcadm 인증 설정 (JKS truststore 필요)
kubectl -n admin exec keycloak-0 -- bash -c "
  mkdir -p /tmp/kcadm
  keytool -import -noprompt -alias ca \
    -file /opt/bitnami/keycloak/certs/ca.crt \
    -keystore /tmp/kcadm/truststore.jks \
    -storepass changeit 2>/dev/null || true
  KC_ADMIN_PASS=\$(cat /opt/bitnami/keycloak/secrets/password)
  /opt/bitnami/keycloak/bin/kcadm.sh config truststore \
    --config /tmp/kcadm/config \
    --trustpass changeit \
    /tmp/kcadm/truststore.jks 2>/dev/null
  /opt/bitnami/keycloak/bin/kcadm.sh config credentials \
    --config /tmp/kcadm/config \
    --server https://keycloak.admin.svc.cluster.local:443 \
    --realm master \
    --user keycloak-admin \
    --password \"\$KC_ADMIN_PASS\" 2>/dev/null
  /opt/bitnami/keycloak/bin/kcadm.sh get events/config \
    --config /tmp/kcadm/config \
    -r ocr
"
```

### 이벤트 로깅 비활성화된 경우 재활성화

```bash
kubectl -n admin exec keycloak-0 -- bash -c "
  # (kcadm 인증 설정은 위 스크립트 참조)
  /opt/bitnami/keycloak/bin/kcadm.sh update realms/ocr \
    --config /tmp/kcadm/config \
    -s eventsEnabled=true \
    -s 'eventsListeners=[\"jboss-logging\",\"keycloak-events-listener\"]' \
    -s adminEventsEnabled=true \
    -s adminEventsDetailsEnabled=true \
    -s eventsExpiration=2592000
"
```

---

## 5. Helm 업그레이드 절차

```bash
# 1. 값 변경
vi infra/helm/values/dev/keycloak.yaml

# 2. 업그레이드
helm upgrade keycloak bitnami/keycloak \
  -n admin \
  -f infra/helm/values/dev/keycloak.yaml \
  --version 25.2.0 \
  --timeout 300s

# 3. 롤링 재시작 모니터링
kubectl -n admin rollout status sts/keycloak --timeout=300s

# 4. Smoke 테스트
bash tests/smoke/keycloak_token_test.sh
bash tests/smoke/upload_api_e2e_smoke.sh 2>&1 | tail -10
```

---

## 6. 롤백 절차

```bash
# 이전 revision 확인
helm history keycloak -n admin

# 롤백
helm rollback keycloak <revision> -n admin --timeout 300s

# 재확인
kubectl -n admin rollout status sts/keycloak --timeout=300s
```

---

## 7. kcadm.sh 사용 시 주의사항

- `localhost`는 TLS 인증서 SAN에 포함되지 않음 → `localhost` URL 사용 불가
- `keycloak.admin.svc.cluster.local:443` 또는 `keycloak:443` 사용
- JKS truststore 필요: `/opt/bitnami/keycloak/certs/ca.crt`를 `keytool`로 변환
- config 파일은 `/tmp/kcadm/` 등 쓰기 가능 디렉토리에 생성

---

## 8. 알려진 이슈 및 Carry-over

| 이슈 | 상태 | 비고 |
|------|------|------|
| port-forward issuer 불일치 | 알림 | `KC_HOSTNAME_STRICT=true`로 인해 `localhost` issuer 차단. 클러스터 내부 curl 또는 `--resolve` 옵션 사용 |
| `keycloak-events-listener` SPI 등록 확인 필요 | Carry-over | listener 추가됐으나 Keycloak SPI로 실제 DB 저장되는지 확인 필요 (기본 `jboss-logging`은 콘솔 출력 전용) |
| `KC_HOSTNAME_ADMIN` 미설정 | Carry-over | admin-ui dev 환경(`http://localhost:3000`) redirect_uri와 충돌 가능. 필요 시 `KC_HOSTNAME_ADMIN=keycloak.admin.svc.cluster.local` 추가 |
| Prometheus ServiceMonitor | Carry-over | metrics 엔드포인트 활성화됨. kube-prometheus-stack ServiceMonitor 설정은 Phase 2 |
