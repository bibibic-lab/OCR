# OpenBao Unseal Runbook (dev)

**대상 환경**: kind `ocr-dev` / OpenBao 2.0.0 / Shamir 5-of-3 seal. Phase 1에 SoftHSM 또는 K8s transit auto-unseal로 교체 예정. 지금은 pod 재기동마다 **수동 unseal** 필요.

## 증상

- `kubectl -n security get pods -l app.kubernetes.io/name=openbao` 가 `0/1 Running` 또는 `CrashLoopBackOff`
- `kubectl -n security logs openbao-0` 에 `Vault is sealed` 또는 health `HTTP 400`
- 하위 애플리케이션이 Transit KEK 호출 시 `sealed` 에러 반환

## 즉시 복구 (3단계, 약 30초)

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

그 다음 readiness probe가 15~30초 내 Ready 전환 → pod `1/1 Running`.

## 자동화 스크립트 (권장)

```bash
bash /Users/jimmy/_Workspace/ocr/scripts/openbao-unseal.sh
```

이 스크립트는 sealed=true일 때만 동작한다. Cron/systemd로 주기 호출해도 안전.

## Why 지금은 수동인가

- Shamir 5/3은 manual step 전제. Auto-unseal을 위해서는:
  - **K8s Transit unseal**: 별도 OpenBao 인스턴스의 transit engine으로 unseal. 순환 종속성(chicken-and-egg) 있음.
  - **SoftHSM PKCS#11**: SoftHSM 컨테이너가 HA 환경에서 consistency 문제.
  - **Cloud KMS** (AWS KMS/GCP KMS/Azure KeyVault): kind 환경엔 부적합.
- Phase 1에 K8s transit 또는 외부 KMS 도입 예정 (`docs/superpowers/specs/2026-04-18-ocr-solution-design.md` §A.5 Phase 1 TODO).

## 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `bao: command not found` | pod 이미지 변경 | `kubectl exec ... -- ls /bin/bao /usr/local/bin/bao` 로 실제 위치 확인 |
| `connection refused` on :8200 | 리스너 아직 안 뜸 | `sleep 10` 후 재시도. listener TLS 설정 확인 (`values.yaml`의 `tls_disable=0`) |
| `Seal Type : shamir` 없음 | Pod 재초기화 or PVC 유실 | **중대 사고**. `openbao-init-keys` Secret의 root_token은 의미 없음 (새 unseal keys 필요). 복구: `bao operator init` 재실행 → **이전 데이터 전체 손실**. Stage A5의 PVC `reclaimPolicy: Retain` 설정 이후 이 사고 발생 가능성 크게 감소 |
| `Unseal Progress 3/3` 직후 여전히 `Sealed: true` | 네트워크 파티션 | 모든 pod에서 개별 unseal (replicas=1 dev에선 해당 없음) |

## Phase 1 마이그레이션 가이드 (스텁)

1. Kubernetes auth method 활성
2. 별도 transit unseal OpenBao 인스턴스 배포 (또는 외부 Vault Enterprise / 클라우드 KMS)
3. `seal "transit"` 설정 stanza 추가
4. 실 unseal 후 seal-migrate 명령으로 기존 Shamir → Transit 변환
5. Shamir 키 5개 안전 파기 (또는 BCP-용으로 분산 보관)

자세한 공식 문서: https://openbao.org/docs/commands/operator/migrate/

## 관련 파일

- `infra/helm/values/dev/openbao.yaml` — probe scheme HTTPS + seal 설정
- Secret `security/openbao-init-keys` — 5 Shamir keys + root token (dev-only!)
- `tests/smoke/openbao_transit_test.sh` — unseal 검증
