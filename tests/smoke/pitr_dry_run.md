# PITR Dry-Run 검증 결과

| 항목 | 값 |
|------|-----|
| 실행일 | 2026-04-23 |
| 실행자 | Claude Code (Phase 1 #3) |
| 백업 소스 | `pg-main` Cluster, processing ns |
| 백업 ID | `20260423T050431` |
| 백업 방법 | barmanObjectStore (SeaweedFS S3) |
| 결과 | **PASS** |

---

## 1. 사전 상태 확인

### WAL 아카이버 상태 (복구 전)

```
 archived_count | last_archived_wal              | last_archived_time            | failed_count
----------------+--------------------------------+-------------------------------+--------------
             72 | 000000010000000000000046       | 2026-04-23 06:59:44+00        |            0
```

- 아카이빙 성공: 72개, 실패: 0건

### 백업 목록

```
NAME                                 CLUSTER  METHOD              PHASE
pg-main-manual-1776920497            pg-main  barmanObjectStore   completed   (20260423T050142)
pg-main-smoke-1776920663             pg-main  barmanObjectStore   completed   (20260423T050431)  ← 사용
```

### S3 오브젝트 (pg-backups/pg-main/)

```
pg-main/pg-main/base/20260423T050142/backup.info   (1,314 B)
pg-main/pg-main/base/20260423T050142/data.tar.gz   (6.3 MB)
pg-main/pg-main/base/20260423T050431/backup.info   (1,314 B)
pg-main/pg-main/base/20260423T050431/data.tar.gz   (6.3 MB)
pg-main/pg-main/wals/0000000100000000/             (WAL 000000010000000000000041 ~ 000000010000000000000046)
```

---

## 2. 복구 Cluster 설정

매니페스트: `infra/manifests/postgres/restore-test.yaml`

주요 설정:
- `bootstrap.recovery.source: pg-main-origin`
- `externalClusters[].barmanObjectStore.serverName: "pg-main"` ← **필수**: 이 값 없으면 "no target backup found" 에러
- `recoveryTarget` 없음 → 최신 백업 + WAL end까지 복구

---

## 3. 복구 실행 로그 요약

| 단계 | 시각 (UTC) | 내용 |
|------|-----------|------|
| Cluster 생성 | 07:11:52 | `kubectl apply` 실행 |
| full-recovery pod 기동 | 07:14:05 | `Recovering from external cluster` |
| 백업 탐색 성공 | 07:14:07 | `Target backup found: 20260423T050431` |
| barman-cloud-restore 시작 | 07:14:08 | 백업 데이터 다운로드 |
| 복구 완료 | 07:14:12 | `Restore completed` |
| WAL 복구 시작 | 07:14:22 | `starting archive recovery` |
| WAL 적용 완료 → promote | ~07:16 | pod `pg-restore-test-1` Running |
| **Ready** | **07:17:27** | **복구 시작으로부터 약 3분 20초** |

---

## 4. 데이터 검증

### 데이터베이스 목록 (`\l`)

```
 Name      | Owner    | Encoding
-----------+----------+---------
 app       | app      | UTF8
 dmz       | postgres | UTF8    ← 검증 대상
 keycloak  | keycloak | UTF8
 ocr       | ocr      | UTF8
 postgres  | postgres | UTF8
 template0 | postgres | UTF8
 template1 | postgres | UTF8
```

### dmz 데이터베이스 테이블 (`\dt`)

```
 Schema | Name                  | Type  | Owner
--------+-----------------------+-------+---------
 public | document              | table | dmz_app   ✓
 public | flyway_schema_history | table | dmz_app
 public | ocr_result            | table | dmz_app   ✓
```

### 레코드 수

```sql
-- document 테이블
SELECT count(*) FROM document;
-- 결과: 45

-- ocr_result 테이블
SELECT count(*) FROM ocr_result;
-- 결과: 40
```

---

## 5. 클린업

```bash
kubectl -n processing delete cluster pg-restore-test
# → cluster.postgresql.cnpg.io "pg-restore-test" deleted
# → 15초 후 pod 없음 확인
```

---

## 6. 성공 기준 체크

| 기준 | 결과 |
|------|------|
| pg-restore-test Ready within 5 min | PASS (약 3분 20초) |
| `\l` 에 dmz 데이터베이스 존재 | PASS |
| `\dt` 에 document, ocr_result 테이블 존재 | PASS |
| document count > 0 | PASS (45행) |
| ocr_result count > 0 | PASS (40행) |
| 클린업 완료 (pg-restore-test-1 pod 없음) | PASS |

**결론: SeaweedFS S3 barmanObjectStore 기반 PITR 복구 정상 동작 확인.**

---

## 7. 트러블슈팅 메모

### 1차 시도 실패: "no target backup found"

**원인**: `externalClusters` 에 `serverName` 필드 누락.

CNPG recovery 시 `barman-cloud-restore`는 아래 구조로 S3 경로를 탐색:
```
s3://<destinationPath>/<serverName>/base/<backupId>/
```

`serverName`을 지정하지 않으면 `externalClusters[].name` (= `pg-main-origin`)을 서버명으로 사용하여 존재하지 않는 경로 탐색 → "no target backup found".

**해결**: `externalClusters[].barmanObjectStore.serverName: "pg-main"` 명시.

---

## 8. 참고 명령

```bash
# 복구 Cluster 기동 (dry-run 시)
kubectl apply -f infra/manifests/postgres/restore-test.yaml

# 복구 진행 로그 확인
kubectl -n processing logs -l cnpg.io/cluster=pg-restore-test -c full-recovery --follow

# 데이터 검증
kubectl -n processing exec pg-restore-test-1 -c postgres -- psql -U postgres -l
kubectl -n processing exec pg-restore-test-1 -c postgres -- psql -U postgres -d dmz -c "\dt"
kubectl -n processing exec pg-restore-test-1 -c postgres -- psql -U postgres -d dmz -c "SELECT count(*) FROM document"
kubectl -n processing exec pg-restore-test-1 -c postgres -- psql -U postgres -d dmz -c "SELECT count(*) FROM ocr_result"

# 클린업
kubectl -n processing delete cluster pg-restore-test
```
