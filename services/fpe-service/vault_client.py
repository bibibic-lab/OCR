"""
vault_client.py — OpenBao KV 클라이언트
==========================================
FPE 키 (AES 256-bit + FF3 tweak) 를 OpenBao KV v2 에서 읽어옵니다.

경로 규칙:
  kv/security/fpe-keys/{type}
  필드:
    aes_key_hex   : 64자 hex 문자열 (256-bit AES 키)
    tweak_hex     : 14자 hex 문자열 (56-bit FF3 트윅)
    kek_version   : "v1" 등 버전 식별자

인증 우선순위:
  1. BAO_TOKEN 환경변수 (개발 편의 / root token)
  2. KUBERNETES_SERVICE_ACCOUNT 자동 감지 (in-cluster Kubernetes auth)

환경변수:
  BAO_ADDR        : OpenBao 주소 (기본 https://openbao.security.svc.cluster.local:8200)
  BAO_TOKEN       : Static 토큰 (개발용)
  BAO_CACERT      : CA cert 파일 경로 (기본 /etc/ssl/openbao-ca/ca.crt)
  BAO_SKIP_VERIFY : "true" 시 TLS 검증 스킵 (개발 클러스터에서만)
  BAO_K8S_ROLE    : Kubernetes auth role (기본 fpe-service)
  BAO_K8S_MOUNT   : Kubernetes auth mount 경로 (기본 kubernetes)
"""
from __future__ import annotations

import functools
import logging
import os
from typing import Optional

import hvac

from fpe import FPEConfig

logger = logging.getLogger(__name__)

# 환경변수 설정
BAO_ADDR = os.environ.get("BAO_ADDR", "https://openbao.security.svc.cluster.local:8200")
BAO_TOKEN = os.environ.get("BAO_TOKEN", "")
BAO_CACERT = os.environ.get("BAO_CACERT", "/etc/ssl/openbao-ca/ca.crt")
BAO_SKIP_VERIFY = os.environ.get("BAO_SKIP_VERIFY", "false").lower() == "true"
BAO_K8S_ROLE = os.environ.get("BAO_K8S_ROLE", "fpe-service")
BAO_K8S_MOUNT = os.environ.get("BAO_K8S_MOUNT", "kubernetes")
KV_BASE_PATH = "security/fpe-keys"


def _build_client() -> hvac.Client:
    """hvac 클라이언트 초기화 (TLS + 인증)"""
    verify: bool | str = False if BAO_SKIP_VERIFY else BAO_CACERT
    if not BAO_SKIP_VERIFY and not os.path.exists(BAO_CACERT):
        # CA 파일 없으면 시스템 번들 사용
        verify = True
        logger.warning("BAO_CACERT 파일 없음, 시스템 번들 사용: %s", BAO_CACERT)

    client = hvac.Client(url=BAO_ADDR, verify=verify)

    if BAO_TOKEN:
        client.token = BAO_TOKEN
        logger.info("OpenBao: static token 사용 (개발 모드)")
        return client

    # Kubernetes SA 토큰 기반 인증
    sa_token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    if os.path.exists(sa_token_path):
        with open(sa_token_path) as f:
            sa_token = f.read().strip()
        try:
            client.auth.kubernetes.login(role=BAO_K8S_ROLE, jwt=sa_token, mount_point=BAO_K8S_MOUNT)
            logger.info("OpenBao: Kubernetes auth 성공 (role=%s)", BAO_K8S_ROLE)
        except Exception as e:
            logger.error("OpenBao Kubernetes auth 실패: %s", e)
            raise RuntimeError(f"OpenBao 인증 실패: {e}") from e
        return client

    raise RuntimeError("OpenBao 인증 방법 없음. BAO_TOKEN 또는 Kubernetes SA 필요.")


@functools.lru_cache(maxsize=None)
def _get_cached_config(field_type: str) -> FPEConfig:
    """FPE 키 로드 (프로세스 수명 동안 캐시). 재로드 필요 시 _get_cached_config.cache_clear() 호출."""
    client = _build_client()
    path = f"{KV_BASE_PATH}/{field_type}"
    try:
        secret = client.secrets.kv.v2.read_secret_version(path=path, mount_point="kv")
        data = secret["data"]["data"]
        config = FPEConfig(
            key_hex=data["aes_key_hex"],
            tweak_hex=data["tweak_hex"],
            kek_version=data.get("kek_version", "v1"),
        )
        # 기본 유효성 검사
        if len(config.key_hex) != 64:
            raise ValueError(f"aes_key_hex 길이 오류: {len(config.key_hex)} (expected 64)")
        if len(config.tweak_hex) != 14:
            raise ValueError(f"tweak_hex 길이 오류: {len(config.tweak_hex)} (expected 14)")
        logger.info("FPE 키 로드 완료: type=%s, kek_version=%s", field_type, config.kek_version)
        return config
    except Exception as e:
        logger.error("FPE 키 로드 실패: type=%s, path=%s, error=%s", field_type, path, e)
        raise RuntimeError(f"FPE 키 로드 실패 ({field_type}): {e}") from e


def get_fpe_config(field_type: str) -> FPEConfig:
    """필드 타입에 대한 FPE 키 설정 반환 (캐시 우선)"""
    return _get_cached_config(field_type)


def invalidate_key_cache() -> None:
    """키 캐시 무효화 (키 교체 후 호출)"""
    _get_cached_config.cache_clear()
    logger.info("FPE 키 캐시 초기화 완료")
