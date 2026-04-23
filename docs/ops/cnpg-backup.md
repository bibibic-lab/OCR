# CNPG barmanObjectStore 백업 & 복구 런북

| 항목 | 값 |
|------|-----|
| 작성일 | 2026-04-22 |
| 작성자 | Claude Code (Phase 1 #3 구현) |
| 적용 버전 | CNPG 1.x, SeaweedFS 3.x |
| 상태 | 운영 중 (dev 클러스터 검증 완료) |

---

## 1. 아키텍처 개요

```
pg-main (processing ns)  ──WAL──►  seaweedfs-s3:8333  ──►  s3://pg-backups/pg-main/
pg-pii  (security ns)    ──WAL──►  seaweedfs-s3:8333  ──►  s3://pii-backups/pg-pii/
```

- **WAL 연속 아카이빙**: `archive_timeout=5min`, gzip 압축, 병렬 2
- **정기 베이스 백업**: 매일 03:17 KST (pg-main), 03:27 KST (pg-pii)
- **보존 정책**: 14일
- **S3 엔드포인트**: `http://seaweedfs-s3.processing.svc.cluster.local:8333`
- **인증**: Secret `pg-backup-s3-creds` (dev: `dev-backup-access-key` / `dev-backup-secret-key`)

> Phase 2 계획: ESO(OpenBao KV)를 통한 자격증명 자동 주입으로 전환.
> 재검토 조건: Phase 1 #2 (ESO 패턴) 완료 시. 책임자: 인프라 팀.

---

## 2. 관련 리소스 목록

| 종류 | 이름 | 네임스페이스 | 설명 |
|------|------|-------------|------|
| Secret | `pg-backup-s3-creds` | processing | S3 자격증명 |
| Secret | `pg-backup-s3-creds` | security | S3 자격증명 (pg-pii용) |
| Cluster | `pg-main` | processing | `spec.backup.barmanObjectStore` 설정 포함 |
| Cluster | `pg-pii` | security | `spec.backup.barmanObjectStore` 설정 포함 |
| ScheduledBackup | `pg-main-daily` | processing | 매일 18:17 UTC |
| ScheduledBackup | `pg-pii-daily` | security | 매일 18:27 UTC |
| Job | `bucket-bootstrap` | processing | S3 버킷 초기 생성 (one-shot) |

---

## 3. 상태 모니터링

### 3.1 WAL 아카이빙 상태 확인

```bash
# pg_stat_archiver 조회
kubectl -n processing exec pg-main-1 -c postgres -- \
  psql -U postgres -d postgres -c \
  "SELECT archived_count, failed_count, last_archived_wal, last_archived_time, last_failed_wal, last_failed_time FROM pg_stat_archiver;"
```

정상: `failed_count = 0`, `archived_count > 0`, `last_failed_wal` 없음.

### 3.2 CNPG 클러스터 ContinuousArchiving 조건

```bash
kubectl -n processing get cluster pg-main \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'
```

정상: `"status":"True"`, `"reason":"ContinuousArchivingSuccess"`.

### 3.3 Backup 목록

```bash
kubectl -n processing get backup --sort-by=.metadata.creationTimestamp
kubectl -n security  get backup --sort-by=.metadata.creationTimestamp
```

### 3.4 S3 백업 객체 확인

```bash
kubectl -n processing run s3ls --rm -i --restart=Never --image=amazon/aws-cli:2.15.30 \
  --env="AWS_ACCESS_KEY_ID=dev-backup-access-key" \
  --env="AWS_SECRET_ACCESS_KEY=dev-backup-secret-key" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  --command -- aws \
  --endpoint-url "http://seaweedfs-s3.processing.svc.cluster.local:8333" \
  s3 ls --recursive s3://pg-backups/
```

---

## 4. 수동 백업 실행

```bash
# pg-main 즉시 백업
kubectl -n processing apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: pg-main-manual-$(date +%Y%m%d%H%M)
  namespace: processing
spec:
  cluster:
    name: pg-main
  method: barmanObjectStore
EOF

# 완료 대기
kubectl -n processing wait \
  --for=jsonpath='{.status.phase}'=completed \
  backup/pg-main-manual-$(date +%Y%m%d%H%M) \
  --timeout=300s
```

---

## 5. PITR Dry-Run 검증 결과 (2026-04-23)

| 항목 | 값 |
|------|-----|
| 실행일 | 2026-04-23 |
| 백업 ID | `20260423T050431` |
| 복구 소요 시간 | 약 3분 20초 |
| 결과 | **PASS** |

### 검증 항목

| 기준 | 결과 |
|------|------|
| pg-restore-test Ready within 5 min | PASS (3분 20초) |
| `\l` 에 dmz 데이터베이스 존재 | PASS |
| `\dt` 에 document, ocr_result 테이블 존재 | PASS |
| document count > 0 | PASS (45행) |
| ocr_result count > 0 | PASS (40행) |
| 클린업 완료 | PASS |

> 상세 결과: `tests/smoke/pitr_dry_run.md` 참조

### 핵심 발견사항: serverName 필드 필수

CNPG externalClusters 에서 `serverName`을 명시하지 않으면 `no target backup found` 에러 발생.  
원본 클러스터명(`pg-main`)을 `serverName`에 명시해야 barman이 올바른 S3 경로를 탐색:
```
s3://pg-backups/pg-main/pg-main/base/<backupId>/
                        ^^^^^^^^ serverName
```

---

## 6. 복구 절차 (Point-in-Time Recovery)

### 5.1 사전 준비

1. 복구할 시점(target time) 결정 — RFC3339 형식: `2026-04-22T03:00:00+09:00`
2. 복구 대상 네임스페이스 및 Cluster 이름 결정 (기존과 다른 이름 권장)
3. S3에서 해당 시점 이전의 백업 ID 확인:

```bash
kubectl -n processing run s3ls --rm -i --restart=Never --image=amazon/aws-cli:2.15.30 \
  --env="AWS_ACCESS_KEY_ID=dev-backup-access-key" \
  --env="AWS_SECRET_ACCESS_KEY=dev-backup-secret-key" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  --command -- aws \
  --endpoint-url "http://seaweedfs-s3.processing.svc.cluster.local:8333" \
  s3 ls s3://pg-backups/pg-main/pg-main/base/
```

### 5.2 PITR Cluster 매니페스트

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main-restore
  namespace: processing
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.2
  storage:
    size: 10Gi
    storageClass: standard
  bootstrap:
    recovery:
      source: pg-main-backup
      recoveryTarget:
        # 특정 시점 복구 (KST → UTC 변환 필요)
        targetTime: "2026-04-22T18:00:00Z"
        # 또는 특정 WAL LSN:
        # targetLSN: "0/41000000"
        # 또는 특정 백업 ID:
        # backupID: "20260422T030000"
  externalClusters:
    - name: pg-main-backup
      barmanObjectStore:
        destinationPath: "s3://pg-backups/pg-main"
        endpointURL: "http://seaweedfs-s3.processing.svc.cluster.local:8333"
        s3Credentials:
          accessKeyId:
            name: pg-backup-s3-creds
            key: accessKeyId
          secretAccessKey:
            name: pg-backup-s3-creds
            key: secretAccessKey
        wal:
          maxParallel: 2
```

### 5.3 복구 실행

```bash
# 1. Secret 확인 (이미 있어야 함)
kubectl -n processing get secret pg-backup-s3-creds

# 2. 복구 Cluster 적용
kubectl apply -f pg-main-restore.yaml

# 3. 복구 완료 대기
kubectl -n processing wait --for=condition=Ready \
  cluster/pg-main-restore --timeout=600s

# 4. 데이터 검증
kubectl -n processing exec pg-main-restore-1 -c postgres -- \
  psql -U postgres -d ocr -c "SELECT count(*) FROM <핵심 테이블>;"

# 5. (선택) 서비스 전환 — pg-main Service가 pg-main-restore를 가리키도록 변경
#    또는 pg-main 삭제 후 pg-main-restore를 pg-main으로 rename (PVC 유지 주의)
```

> **주의**: 복구 Cluster는 기존 `pg-main`과 **동시에 존재** 가능. 
> 검증 완료 후 기존 클러스터 삭제 여부를 수동으로 결정할 것.

### 5.4 복구 후 정리

```bash
# 검증 완료 시 복구 클러스터 삭제
kubectl -n processing delete cluster pg-main-restore
```

---

## 7. 장애 대응 시나리오

### 6.1 WAL 아카이빙 실패

**증상**: `pg_stat_archiver.failed_count > 0` 또는 `ContinuousArchiving: False`

**원인 확인**:
```bash
# CNPG 컨트롤러 로그
kubectl -n cnpg-system logs -l app.kubernetes.io/name=cloudnative-pg --tail=50

# pg-main-1 pod 내 barman-cloud-wal-archive 로그
kubectl -n processing logs pg-main-1 -c postgres --tail=100 | grep -i "barman\|archive\|error"
```

**대응**:
1. SeaweedFS S3 서비스 상태 확인: `kubectl -n processing get pod -l app.kubernetes.io/name=seaweedfs`
2. Secret 자격증명 확인: `kubectl -n processing get secret pg-backup-s3-creds -o jsonpath='{.data.accessKeyId}' | base64 -d`
3. 버킷 존재 확인 (§3.4 참조)
4. NetworkPolicy 확인: `kubectl -n processing get networkpolicy allow-intra-namespace`

### 6.2 ScheduledBackup 미실행

**증상**: `kubectl -n processing get scheduledbackup pg-main-daily` 의 `lastBackupTime` 갱신 안 됨

**원인 확인**:
```bash
kubectl -n processing describe scheduledbackup pg-main-daily
```

**대응**: 수동 백업 실행 (§4) 후 스케줄 설정 재검토.

### 6.3 SeaweedFS S3 다운

**임시 조치**: WAL은 로컬에 누적됨 (`wal_keep_size: 512MB`). 서비스 복구 후 자동 재전송.
**장기 조치**: SeaweedFS 복구 절차 (`docs/ops/seaweedfs-recovery.md` 참조 — 미작성).

---

## 8. 운영 체크리스트 (일별)

- [ ] `pg_stat_archiver.failed_count = 0` 확인
- [ ] 전날 ScheduledBackup `phase=completed` 확인
- [ ] S3 버킷 사용량 모니터링 (SeaweedFS 용량 대비 14일치 보존)

---

## 9. 관련 파일

| 파일 | 설명 |
|------|------|
| `infra/manifests/postgres/backup-s3-creds.yaml` | S3 자격증명 Secret |
| `infra/manifests/postgres/bucket-bootstrap.yaml` | 버킷 초기 생성 Job |
| `infra/manifests/postgres/main-cluster.yaml` | pg-main Cluster (backup 포함) |
| `infra/manifests/postgres/pii-cluster.yaml` | pg-pii Cluster (backup 포함) |
| `infra/manifests/postgres/scheduled-backup.yaml` | 정기 백업 CR |
| `tests/smoke/cnpg_backup_smoke.sh` | 자동화 검증 스크립트 |

---

## 10. barman-cloud 버전 메모

CNPG v1.x 내장 `barman-cloud` 버전은 CNPG 이미지(`ghcr.io/cloudnative-pg/postgresql:16.2`)에 번들로 포함.
버전 확인:
```bash
kubectl -n processing exec pg-main-1 -c postgres -- barman-cloud-backup --version 2>/dev/null || \
  kubectl -n processing exec pg-main-1 -c postgres -- pip show barman 2>/dev/null | grep Version
```

> 재검토 조건: CNPG 업그레이드 시 barman-cloud 버전 호환성 재확인.

---

## 11. Phase 2 이관 계획 (ESO → OpenBao KV)

현재 `pg-backup-s3-creds` Secret은 정적 플레이스홀더 값.
Phase 1 #2(ESO 패턴) 완료 후:
1. OpenBao KV에 `secret/data/postgres/backup-s3` 경로로 자격증명 저장
2. ExternalSecret CR 생성하여 `pg-backup-s3-creds` 자동 동기화
3. `backup-s3-creds.yaml` 정적 Secret 제거
4. SeaweedFS S3 auth configmap의 `pg-backup` identity에 실 자격증명 설정

책임자: 인프라 팀. 재검토 일자: Phase 1 완료 시.
