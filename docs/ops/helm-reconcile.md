# Helm Release 상태 복구 Runbook

**작성일**: 2026-04-23  
**작업자**: Claude (Phase 1 Medium #1)  
**대상 릴리스**: `cert-manager` (security ns), `openbao` (security ns)  
**결과**: 양쪽 모두 `STATUS=deployed` 전환 완료

---

## 1. 배경 및 문제 정의

### 증상
`helm ls -A` 실행 시 아래 두 릴리스가 `failed` 상태:

| Release | Namespace | Revision | Status |
|---------|-----------|----------|--------|
| cert-manager | security | 1 | failed |
| openbao | security | 7 | failed |

### 영향
- GitOps 연계(ArgoCD) 시 failed 릴리스를 재배포 대상으로 인식 → 불필요한 재배포 및 커스터마이징 덮어쓰기 위험
- `helm upgrade` 시 "이미 failed 상태" 경고로 인한 CI/CD 혼란

---

## 2. cert-manager 복구

### 2-1. 실패 원인 분석

**`helm status cert-manager -n security`** 출력:
```
DESCRIPTION: Release "cert-manager" failed: 
  resource Deployment/security/cert-manager-cainjector not ready. status: InProgress, message: Available: 0/2
  resource Deployment/security/cert-manager-webhook not ready. status: InProgress, message: Available: 0/2
  context deadline exceeded
```

**원인**: 초기 `helm install` 시 timeout 기본값(5분) 내에 Deployment rollout 미완료로 `failed` 표기됨. 설치 자체는 성공했으나 helm 상태만 `failed` 잔존.

**증거**: Deployment는 이미 `READY=2/2` — pods 모두 Running.

### 2-2. Values Drift 확인

`diff <(helm get values cert-manager -n security -o yaml) infra/helm/values/dev/cert-manager.yaml`

결과: **YAML 구조 순서 및 주석 차이만 있음. 실제 값은 동일.** → git values 파일로 그대로 upgrade 가능.

### 2-3. 복구 절차

```bash
helm upgrade --install cert-manager jetstack/cert-manager \
  -n security \
  -f infra/helm/values/dev/cert-manager.yaml \
  --version v1.14.5 \
  --timeout 120s
```

**결과**: `Release "cert-manager" has been upgraded. Happy Helming! STATUS: deployed REVISION: 2`

### 2-4. 사후 검증

- `helm status cert-manager -n security`: STATUS=deployed, REVISION=2
- 모든 Deployment READY 2/2, 모든 Pod Running (재시작 없음)

---

## 3. openbao 복구

### 3-1. 실패 원인 분석 (Rev 7)

**`helm status openbao -n security`** 출력:
```
DESCRIPTION: Upgrade "openbao" failed: StatefulSet.apps "openbao" is invalid: 
  spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 
  'ordinals', 'template', 'updateStrategy', 'revisionHistoryLimit', 
  'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden
```

**원인**: `openbao-0.5.0` → `openbao-0.27.1` chart 메이저 버전 업그레이드 시 StatefulSet `volumeClaimTemplates` 필드 변경 시도 → K8s 불변 필드 제약으로 실패.

**Helm 히스토리**:

| Rev | Chart | Status | 설명 |
|-----|-------|--------|------|
| 1-5 | 0.5.0 | superseded | 초기 설치·설정 |
| 6 | 0.5.0 | **deployed** | 마지막 정상 상태 |
| 7 | 0.27.1 | **failed** | volumeClaimTemplates 불변 충돌 |

### 3-2. 복구 전략 선택

**옵션 비교**:

| 옵션 | 방법 | 위험도 |
|------|------|--------|
| A. `helm rollback 6` | 직전 정상 revision으로 rollback | 낮음 (PVC 유지) |
| B. `helm uninstall` + `helm install` | 재설치 | 중간 (Pod 재생성, unseal 필요) |
| C. 실패 상태 유지 | — | 해결 안됨 |

**선택: 옵션 A** — PVC 삭제 없이 안전하게 rev 6 상태 복원.

### 3-3. SSA Field Manager 충돌 해결

**증상**: `helm rollback openbao 6` 실행 시 아래 에러:
```
conflict occurred while applying object security/openbao apps/v1, Kind=StatefulSet:
Apply failed with 2 conflicts: conflicts with "kubectl-patch" using apps/v1:
- .spec.template.spec.containers[name="openbao"].livenessProbe.httpGet.scheme
- .spec.template.spec.containers[name="openbao"].readinessProbe.httpGet.scheme
```

**원인**: 이전 운영 세션에서 `kubectl patch` 명령으로 probe scheme을 `HTTPS`로 수정 시 `kubectl-patch` field manager가 해당 필드의 소유권을 취득. Helm SSA(Server-Side Apply) 방식과 충돌.

**해결**: `kubectl-patch` managedFields 항목 직접 제거:

```bash
# managedFields에서 kubectl-patch 항목 위치 확인
kubectl get statefulset openbao -n security -o json --show-managed-fields | python3 -c "
import json, sys
d = json.load(sys.stdin)
for i, m in enumerate(d['metadata']['managedFields']):
    print(f'[{i}] manager={m[\"manager\"]} op={m[\"operation\"]}')
"
# 출력: [2] manager=kubectl-patch op=Update

# kubectl-patch 항목 제거 (인덱스 2)
kubectl patch statefulset openbao -n security \
  --type=json \
  -p '[{"op":"remove","path":"/metadata/managedFields/2"}]'
```

### 3-4. 복구 절차

```bash
helm rollback openbao 6 -n security --timeout 120s
```

**결과**: `Rollback was a success! Happy Helming!` → REVISION=13, STATUS=deployed

### 3-5. openbao 봉인 상태 확인

```
$ kubectl exec -n security openbao-0 -- bao status -address=https://127.0.0.1:8200 -tls-skip-verify

Seal Type    shamir
Initialized  true
Sealed       false         ← 정상 (unsealed)
HA Mode      active
```

Pod 재시작 없음. openbao-unsealer가 자동 unseal 개입 불필요.

### 3-6. Values Drift 분석

`diff <(helm get values openbao -n security -o yaml) infra/helm/values/dev/openbao.yaml`

결과: **YAML 키 순서 및 주석 차이만 있음. 실제 값은 동일.** → git values 파일 업데이트 불필요.

---

## 4. 최종 상태 확인

```bash
helm ls -A | grep -E "cert-manager|openbao"
```

```
cert-manager   security   2    2026-04-23 16:29:47  deployed  cert-manager-v1.14.5   v1.14.5
openbao        security   13   2026-04-23 16:34:09  deployed  openbao-0.5.0          v2.0.1
```

**성공 기준 달성**: 양쪽 모두 `STATUS=deployed`.

---

## 5. 잔류 리소스 (Leftover Resources) 메모

추가 정리 시 확인 권장 항목 — 이번 세션에서는 수정하지 않음:

| 항목 | 내용 | 우선순위 |
|------|------|----------|
| openbao chart 버전 | 현재 0.5.0(v2.0.1) 사용 중. 최신 0.27.1(v2.5.2)으로 업그레이드 시 StatefulSet volumeClaimTemplates 사전 조사 필요 | Medium |
| openbao helm history 누적 | rev 13까지 누적. 불필요한 history 정리 고려 (`helm history --max` 설정) | Low |
| kubectl-patch field manager 재발 방지 | probe scheme 변경 시 `kubectl patch` 대신 values 파일 수정 → `helm upgrade` 워크플로우 준수 | High |
| cert-manager ServiceMonitor | `servicemonitor.enabled: false` 현재 설정. kube-prometheus-stack 설치 후 `true`로 전환 필요 | Low |

---

## 6. openbao chart 업그레이드 시 주의사항 (미래 작업)

chart `0.5.0` → `0.27.1` 직접 upgrade는 **StatefulSet volumeClaimTemplates 불변 필드** 충돌로 불가. 절차:

1. `kubectl get pvc -n security` → PVC 목록 확인 및 `persistentVolumeReclaimPolicy=Retain` 검증
2. `helm uninstall openbao -n security --keep-history`
3. StatefulSet 직접 삭제 (`kubectl delete sts openbao -n security`)
4. PVC는 **삭제하지 말 것** (Retain 정책으로 데이터 보존)
5. `helm install openbao openbao/openbao --version 0.27.1 -n security -f infra/helm/values/dev/openbao.yaml`
6. openbao Pod 기동 후 seal 상태 확인 (unsealer 자동 개입 예상)

이 작업은 **별도 계획된 유지보수 세션**에서 수행. 예상 downtime ~5분 (unsealer 자동 unseal 포함).

---

## 7. 관련 파일

- `infra/helm/values/dev/cert-manager.yaml` — cert-manager values (변경 없음)
- `infra/helm/values/dev/openbao.yaml` — openbao values (변경 없음, drift 없음 확인)
- `infra/manifests/openbao/auto-unseal.yaml` — openbao-unsealer Deployment (helm 외부 관리, 영향 없음)
