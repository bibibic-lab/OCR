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
