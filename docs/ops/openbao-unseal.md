# OpenBao Unseal Runbook (dev)

**대상 환경**: kind `ocr-dev` / OpenBao 2.0.0 / Shamir 5-of-3 seal.

> **Phase 1 완료 (2026-04-23)**: `openbao-unsealer` Deployment가 `security` 네임스페이스에서 실행 중.
> pod 재기동 후 **18초 이내 자동 unseal** 확인. 수동 개입 불필요.
> 아래 수동 절차는 **unsealer pod 자체가 다운된 경우의 폴백(fallback)**으로 유지.

---

## 자동 unseal (현재 운영 방식)

`openbao-unsealer` Deployment가 10초 간격으로 `/v1/sys/seal-status`를 폴링하고,
sealed=true 감지 시 `openbao-init-keys` Secret의 Shamir 키 3개를 자동으로 제출한다.

### 상태 확인

```bash
# unsealer 정상 실행 여부
kubectl -n security get deploy openbao-unsealer

# unsealer 최근 로그 (unseal 이력 포함)
kubectl -n security logs deploy/openbao-unsealer --tail=30

# openbao-0 상태
kubectl -n security get pod openbao-0
```

### unsealer 재시작 (이상 감지 시)

```bash
kubectl -n security rollout restart deploy/openbao-unsealer
kubectl -n security rollout status deploy/openbao-unsealer
```

### smoke test 실행

```bash
bash tests/smoke/openbao_auto_unseal_smoke.sh
# - openbao-0 삭제 → 재기동 → unsealer가 자동 unseal → Ready 확인
# - 성공 기준: 120s 이내 Ready
```

---

## 증상

- `kubectl -n security get pod openbao-0` 가 `0/1 Running` 상태가 60s 이상 지속
- unsealer 로그에 `unseal SUCCESS` 대신 `WARN: unreachable` 반복
- 하위 애플리케이션이 Transit KEK 호출 시 `sealed` 에러 반환

---

## 폴백: 수동 unseal (unsealer pod 다운 시)

unsealer Deployment 자체가 실패한 경우에만 사용.

```bash
# 1) Shamir 키 3개를 Secret에서 로드
INIT=$(kubectl -n security get secret openbao-init-keys -o jsonpath='{.data.init\.json}' | base64 -d)

# 2) 각 키로 unseal (threshold=3)
for K in $(echo "$INIT" | jq -r '.unseal_keys_b64[0,1,2]'); do
  kubectl -n security exec openbao-0 -- \
    env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true \
    bao operator unseal "$K"
done

# 3) 상태 확인
kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true \
  bao status | head -5
# 기대 출력: Sealed=false, Initialized=true
```

readiness probe가 15~30초 내 통과 → pod `1/1 Running`.

수동 스크립트:
```bash
bash scripts/openbao-unseal.sh
```

---

## 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| unsealer 로그 `jq: ...` 파싱 오류 | 응답 형식 변경 | `kubectl exec ... -- curl ... /v1/sys/seal-status` 로 raw JSON 확인 |
| `WARN: unreachable` 반복 | openbao pod 아직 기동 중 | 30s 대기 후 재확인. openbao pod 로그 확인 |
| unsealer가 `unseal SUCCESS` 후 재기동 반복 | liveness probe HTTP/HTTPS 불일치 | StatefulSet probe scheme 확인: `kubectl -n security get sts openbao -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}'` → scheme이 HTTP면 HTTPS로 patch |
| `bao: command not found` | pod 이미지 변경 | `kubectl exec ... -- ls /bin/bao /usr/local/bin/bao` 로 실제 위치 확인 |
| `connection refused` on :8200 | 리스너 아직 안 뜸 | 10s 후 재시도. listener TLS 설정 확인 (`values.yaml`의 `tls_disable=0`) |
| `Seal Type: shamir` 없음 | Pod 재초기화 or PVC 유실 | **중대 사고**. 복구: `bao operator init` 재실행 → **이전 데이터 전체 손실**. Stage A5의 PVC `reclaimPolicy: Retain` 설정으로 가능성 크게 감소 |
| `Unseal Progress 3/3` 직후 여전히 `Sealed: true` | 네트워크 파티션 | 모든 pod에서 개별 unseal (replicas=1 dev에선 해당 없음) |

---

## 구현 세부사항

### 아키텍처

```
openbao-unsealer (Deployment, security ns)
  ├── ServiceAccount: openbao-unsealer (automountServiceAccountToken: false)
  ├── ConfigMap: openbao-unsealer-env (BAO_ADDR, INTERVAL=10s)
  ├── Secret 마운트: openbao-init-keys → /etc/openbao/init.json (readOnly)
  ├── Secret 마운트: openbao-tls:ca.crt → /etc/ssl/openbao-ca/ca.crt (readOnly)
  └── NetworkPolicy: egress DNS + openbao:8200 만 허용, ingress 없음
```

### 이미지

- `openbao-unsealer:v0.1.0` — Alpine 3.19 + curl + jq (24MB)
- 소스: `services/openbao-unsealer/Dockerfile`, `services/openbao-unsealer/unsealer.sh`
- 보안: non-root UID 1000, drop ALL caps, seccomp RuntimeDefault

### 파일 목록

| 파일 | 설명 |
|---|---|
| `infra/manifests/openbao/auto-unseal.yaml` | Deployment + SA + ConfigMap + NetworkPolicy |
| `services/openbao-unsealer/unsealer.sh` | 폴링 루프 스크립트 |
| `services/openbao-unsealer/Dockerfile` | Alpine 기반 이미지 |
| `tests/smoke/openbao_auto_unseal_smoke.sh` | auto-unseal smoke test |

### 알려진 한계 (Phase 1 carry-over)

1. **Multi-node Raft**: 현재 single-node(openbao-0). 3-node 환경에서는 모든 pod를 개별 unseal해야 함.
   - 대응: unsealer를 각 pod에 순차 unseal하도록 수정 필요 (poll loop에서 pod 목록 iterate)
2. **신뢰 경계**: Shamir 키가 `openbao-init-keys` Secret에 평문(base64). 현재 상태와 동일 수준.
   - 운영 환경: SealedSecrets 또는 외부 KMS로 교체 필요.
3. **jq false 파싱**: `false // "default"` jq 관용구는 JSON `false`를 falsy로 처리.
   - 해결: 스크립트 내 `| tostring` 사용으로 수정 완료.

---

## 관련 파일

- `infra/helm/values/dev/openbao.yaml` — probe scheme HTTPS + seal 설정
- Secret `security/openbao-init-keys` — 5 Shamir keys + root token (dev-only!)
- `tests/smoke/openbao_transit_test.sh` — transit unseal 검증
- `tests/smoke/openbao_auto_unseal_smoke.sh` — auto-unseal watcher 검증 (Phase 1 추가)
