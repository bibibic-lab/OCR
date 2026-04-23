# upload-api

Spring Boot 기반 문서 업로드 서비스.  
JWT(Keycloak) 인증 → Content-Type 검증 → S3(SeaweedFS) 저장 → PostgreSQL 메타데이터 기록.

## 빌드 & 실행

```bash
export JAVA_HOME=/usr/local/Cellar/openjdk@21/21.0.11/libexec/openjdk.jdk/Contents/Home
./gradlew build
```

## 테스트 실행

```bash
./gradlew test
```

통합 테스트(`DocumentControllerTest`)는 Testcontainers로 PostgreSQL 16 + LocalStack S3를 자동 기동합니다.

## Local Test Setup (OrbStack)

macOS에서 Docker Desktop 대신 **OrbStack**을 사용하는 경우, Testcontainers가 Docker 소켓을 찾지 못해 컨테이너를 기동하지 못합니다.  
아래 스크립트를 한 번 실행하면 `~/.testcontainers.properties` 에 OrbStack 소켓 경로를 설정합니다.

```bash
# 프로젝트 루트에서 실행
bash scripts/setup-testcontainers-orbstack.sh
```

스크립트가 하는 일:
1. OrbStack 소켓(`/var/run/docker.sock` 또는 `~/.orbstack/run/docker.sock`)이 존재하는지 확인
2. `~/.testcontainers.properties` 에 `docker.host=unix://...` 항목을 추가 (이미 설정된 경우 건너뜀)
3. `ryuk.disabled=true` 추가 (OrbStack에서 Ryuk reaper가 소켓 권한 문제를 일으키는 경우 방지)

### 수동 설정

스크립트 없이 직접 설정하려면 `~/.testcontainers.properties` 파일에 다음을 추가하세요:

```properties
# OrbStack 소켓 경로 — Docker Desktop 사용 시 이 줄 불필요
docker.host=unix:///var/run/docker.sock
ryuk.disabled=true
```

OrbStack이 `~/.orbstack/run/docker.sock` 경로를 사용하는 경우:

```properties
docker.host=unix:///Users/<your-username>/.orbstack/run/docker.sock
ryuk.disabled=true
```

> **참고:** `~/.testcontainers.properties` 는 사용자 전역 파일이므로 git에 커밋되지 않습니다.  
> 팀원이 OrbStack 환경을 새로 설정할 때 위 스크립트 또는 수동 설정이 필요합니다.

## 정확도 측정 (Stage B-2)

엔드투엔드 OCR 정확도를 10개 샘플에 대해 자동 측정합니다.  
기준 커밋 `11fee76` 기준: `char_accuracy` 95.8% / `exact_match_rate` 78.8% / `field_recall` 100.0%

### 실행

```bash
bash tests/accuracy/run.sh
```

### 결과 해석

| 지표 | 의미 | 권장 기준 |
|------|------|-----------|
| `char_accuracy` | 문자 단위 정확도 (1 - edit_distance/char_count) | ≥95% |
| `exact_match_rate` | 필드 단위 완전일치 비율 (엄격 지표) | ≥78.8% (baseline 유지) |
| `field_recall` | 부분일치라도 탐지 성공한 필드 비율 | ≥90% |
| `avg_edit_distance` | 필드당 평균 편집거리 (낮을수록 좋음) | ≤0.5 |
| `low_conf_rate` | 낮은 신뢰도 바운딩박스 비율 | ≤0.10 |

리포트 저장 위치: `tests/accuracy/reports/baseline-<commit>.json`

### Phase 1 목표

전체 Phase별 목표표 및 현재 한계 분석은 `docs/accuracy-targets.md` 참조.

- Phase 1 MVP (PaddleOCR PP-OCRv4, Triton GPU): `char_accuracy ≥ 97%`, `exact_match_rate ≥ 85%`
- Phase 1 파인튜닝 (도메인 1만 장): `char_accuracy ≥ 99%`, `exact_match_rate ≥ 95%`
