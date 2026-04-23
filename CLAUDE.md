# OCR 프로젝트 — 프로젝트별 규칙

이 파일은 OCR 통합 플랫폼 프로젝트에만 적용되는 규칙입니다. 전역 규칙(`~/.claude/CLAUDE.md`)을 상속·확장하며, 충돌 시 **전역 규칙이 우선**합니다.

## 문서 위치

- **원본(정본)**: `docs/superpowers/specs/` (설계서), `docs/superpowers/plans/` (구현계획)
- **MS Word 사본**: `Documents/` (프로젝트 루트)
- **RULE-DOC-02** 에 따라 1:1 매핑 유지. basename 동일.

## 동기화

- `make docs-sync` — `docs/` 하위 모든 `.md`를 `Documents/*.docx` 로 일괄 변환
- Claude가 문서를 생성·수정한 직후 반드시 실행

## 예외

- `README.md` (프로젝트 루트)는 원본만 유지. docx 사본 생략.
- `infra/manifests/**/*.yaml` 내 인라인 주석은 문서화 대상 아님.

## 스택 확정 참조

스택·아키텍처 결정은 `docs/superpowers/specs/2026-04-18-ocr-solution-design.md` 를 단일 정본으로 함. 재논의 금지.

## 이 프로젝트의 진행 원칙

- Dry-Run P0 모드는 2026-04-18 세션에서 한 번 적용됐고, 2026-04-19 이후 세션은 **실 apply 검증** 모드.
- 각 구현 태스크는 Implementer → Spec Reviewer → Code Quality Reviewer 3단계 서브에이전트 파이프라인을 거친다.
- Code Reviewer가 Important 이상 지적 시 해당 이슈는 같은 세션에서 수정하여 반영한다.

## [POLICY-NI-01] Not Implemented 더미 정책 (2026-04-23 유저 지정)

실 연결 테스트 불가한 외부 연계(행안부·NICE·KISA TSA 등), 실 HSM, FIPS 라이브러리, 그 외 미구현 기능은 **정상 송수신 더미**로 구현하되 **코드·API·UI 3지점에 Not Implemented 명확 표시 의무**.

### 3지점 의무

**1. 코드**:
- 마커 상수/주석: `// NOT_IMPLEMENTED: 실 API 계약 대기 (docs/ops/integration-agencies.md)`
- 호출 시 WARN 로그: `log.warn("NOT_IMPLEMENTED: {}/{} returning dummy — real pending", agency, endpoint)`
- DTO/인터페이스에 `@NotImplemented` 또는 KDoc/JavaDoc 태그

**2. API 응답**:
- 헤더: `X-Not-Implemented: true` + `X-Agency-Name: <기관명>`
- Body JSON: `"notImplemented": true`, `"mockReason": "..."`

**3. UI (백오피스)**:
- 기능 트리거 화면에 노란색 배너 `⚠️ Not Implemented — 모의 응답입니다`
- 결과에 `[Dummy]` / `[Mock]` prefix 또는 워터마크
- 관리자 대시보드에 Not Implemented 기능 목록 섹션 유지

### 위반 시

- 코드 마커 누락 → 코드 리뷰 **Critical** reject
- API 응답 플래그 누락 → 리뷰 reject
- UI 배너 누락 → QA 지적, 배포 보류

### 전환 절차 (실 구현 도입 시)

1. 실 API 계약·인증서·계정 획득
2. feature flag off (`NOT_IMPLEMENTED = false`)
3. 응답에서 `notImplemented` 필드 제거
4. UI 배너 자동 제거 (동일 플래그 기반 렌더링)
5. 감사 로그에 전환 이벤트 1회 기록
6. `docs/ops/integration-agencies.md` 해당 섹션 "전환 절차" checklist 실행

상세: `~/.claude/projects/-Users-jimmy--Workspace/memory/feedback_not_implemented_policy.md`
