# 로컬 백엔드로 시작. Phase 1에 S3/GCS·state locking으로 전환.
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
