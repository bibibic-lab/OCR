# OCR 통합 플랫폼

OSS 기반 문서 처리 솔루션. 설계서: [docs/superpowers/specs/2026-04-18-ocr-solution-design.md](docs/superpowers/specs/2026-04-18-ocr-solution-design.md)

## 빠른 시작

```bash
make setup            # 도구 체크
make tf-init          # Terraform 초기화
make tf-apply         # dev 환경 적용
make argocd-bootstrap # ArgoCD 설치 + app-of-apps
make smoke            # P0 스모크 테스트
```
