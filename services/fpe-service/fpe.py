"""
fpe.py — Format-Preserving Encryption wrapper (NIST FF3-1)
=============================================================
알고리즘: FF3-1 (NIST SP 800-38G Rev 1)
구현체: ff3 Python 패키지 (ff3==1.0.2, pycryptodome 기반)

지원 필드 타입:
  - rrn     : 주민등록번호 (###### - #######, 13자리 숫자 + 하이픈)
  - card    : 카드번호 (16자리 숫자, 포맷 ####-####-####-####)
  - account : 계좌번호 (10~16자리 숫자)
  - passport: 여권번호 (영문 2자리 + 숫자 7자리, M12345678)

NOTE (dev-grade):
  - 현재 구현은 키/트윅을 OpenBao KV에서 런타임 로드.
  - Phase 2 에서 FF3-1 키 회전 + FIPS 검증 라이브러리로 업그레이드 예정.
  - FF3-1의 알려진 취약점(radix × minlen < 1_000_000 시 공격 표면): RRN은
    radix=10, len=13 → 10^13 = 충분. card(16자리)도 마찬가지.

참조:
  - NIST SP 800-38G Rev 1 (2024): https://doi.org/10.6028/NIST.SP.800-38Gr1
  - ff3 패키지: https://github.com/mysto/python-fpe
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Tuple

from ff3 import FF3Cipher


@dataclass
class FPEConfig:
    key_hex: str   # 256-bit AES key as hex string (64 chars)
    tweak_hex: str  # 56-bit tweak as hex string (14 chars)
    kek_version: str = "v1"


class FPEError(Exception):
    """FPE 연산 오류"""


# ──── RRN (주민등록번호) ──────────────────────────────────────────────────────
RRN_PATTERN = re.compile(r"^\d{6}-\d{7}$")
RRN_DIGITS_ONLY = re.compile(r"^\d{13}$")


def tokenize_rrn(value: str, config: FPEConfig) -> str:
    """
    RRN 토큰화: '900101-1234567' → '834721-8954162'
    - 하이픈 위치 보존
    - 13자리 숫자 그대로 FF3-1 적용
    """
    if not RRN_PATTERN.match(value):
        raise FPEError(f"잘못된 RRN 포맷: {value!r} (expected: ######-#######)")
    digits = value.replace("-", "")
    enc = _ff3_encrypt(digits, config)
    return f"{enc[:6]}-{enc[6:]}"


def detokenize_rrn(token: str, config: FPEConfig) -> str:
    """RRN 역토큰화"""
    if not RRN_PATTERN.match(token):
        raise FPEError(f"잘못된 RRN 토큰 포맷: {token!r}")
    digits = token.replace("-", "")
    dec = _ff3_decrypt(digits, config)
    return f"{dec[:6]}-{dec[6:]}"


# ──── 카드번호 ────────────────────────────────────────────────────────────────
CARD_PATTERN_HYPHEN = re.compile(r"^\d{4}-\d{4}-\d{4}-\d{4}$")
CARD_PATTERN_PLAIN = re.compile(r"^\d{16}$")


def tokenize_card(value: str, config: FPEConfig) -> str:
    """
    카드번호 토큰화: '1234-5678-9012-3456' 또는 '1234567890123456'
    → 포맷 보존 토큰 (하이픈 있으면 유지)
    """
    hyphen = CARD_PATTERN_HYPHEN.match(value)
    plain = CARD_PATTERN_PLAIN.match(value)
    if not hyphen and not plain:
        raise FPEError(f"잘못된 카드번호 포맷: {value!r}")
    digits = value.replace("-", "")
    enc = _ff3_encrypt(digits, config)
    if hyphen:
        return f"{enc[0:4]}-{enc[4:8]}-{enc[8:12]}-{enc[12:16]}"
    return enc


def detokenize_card(token: str, config: FPEConfig) -> str:
    """카드번호 역토큰화"""
    hyphen = CARD_PATTERN_HYPHEN.match(token)
    plain = CARD_PATTERN_PLAIN.match(token)
    if not hyphen and not plain:
        raise FPEError(f"잘못된 카드번호 토큰 포맷: {token!r}")
    digits = token.replace("-", "")
    dec = _ff3_decrypt(digits, config)
    if hyphen:
        return f"{dec[0:4]}-{dec[4:8]}-{dec[8:12]}-{dec[12:16]}"
    return dec


# ──── 계좌번호 ────────────────────────────────────────────────────────────────
ACCOUNT_PATTERN = re.compile(r"^\d{10,16}$")


def tokenize_account(value: str, config: FPEConfig) -> str:
    """계좌번호 토큰화: 10~16자리 숫자"""
    if not ACCOUNT_PATTERN.match(value):
        raise FPEError(f"잘못된 계좌번호 포맷: {value!r} (10~16자리 숫자)")
    return _ff3_encrypt(value, config)


def detokenize_account(token: str, config: FPEConfig) -> str:
    """계좌번호 역토큰화"""
    if not ACCOUNT_PATTERN.match(token):
        raise FPEError(f"잘못된 계좌번호 토큰 포맷: {token!r}")
    return _ff3_decrypt(token, config)


# ──── 여권번호 ────────────────────────────────────────────────────────────────
# 한국 여권: M + 8자리 숫자 (M12345678)
# FPE는 숫자 부분에만 적용, 'M' 접두사 보존
PASSPORT_PATTERN = re.compile(r"^[A-Z]{1,2}\d{7,9}$")


def tokenize_passport(value: str, config: FPEConfig) -> str:
    """여권번호 토큰화: 영문 접두사 보존, 숫자 부분 FPE"""
    if not PASSPORT_PATTERN.match(value):
        raise FPEError(f"잘못된 여권번호 포맷: {value!r}")
    prefix_len = sum(1 for c in value if c.isalpha())
    prefix = value[:prefix_len]
    digits = value[prefix_len:]
    enc_digits = _ff3_encrypt(digits, config)
    return prefix + enc_digits


def detokenize_passport(token: str, config: FPEConfig) -> str:
    """여권번호 역토큰화"""
    if not PASSPORT_PATTERN.match(token):
        raise FPEError(f"잘못된 여권번호 토큰 포맷: {token!r}")
    prefix_len = sum(1 for c in token if c.isalpha())
    prefix = token[:prefix_len]
    digits = token[prefix_len:]
    dec_digits = _ff3_decrypt(digits, config)
    return prefix + dec_digits


# ──── 내부 FF3 헬퍼 ──────────────────────────────────────────────────────────

def _ff3_encrypt(digits: str, config: FPEConfig) -> str:
    """FF3-1 암호화 (숫자 문자열 → 같은 길이 숫자 문자열)"""
    try:
        cipher = FF3Cipher(config.key_hex, config.tweak_hex)
        return cipher.encrypt(digits)
    except Exception as e:
        raise FPEError(f"FF3 암호화 실패: {e}") from e


def _ff3_decrypt(digits: str, config: FPEConfig) -> str:
    """FF3-1 복호화"""
    try:
        cipher = FF3Cipher(config.key_hex, config.tweak_hex)
        return cipher.decrypt(digits)
    except Exception as e:
        raise FPEError(f"FF3 복호화 실패: {e}") from e


# ──── 통합 디스패처 ───────────────────────────────────────────────────────────
FIELD_TYPES = {"rrn", "card", "account", "passport"}


def tokenize(field_type: str, value: str, config: FPEConfig) -> str:
    """필드 타입에 따른 토큰화 디스패치"""
    if field_type == "rrn":
        return tokenize_rrn(value, config)
    elif field_type == "card":
        return tokenize_card(value, config)
    elif field_type == "account":
        return tokenize_account(value, config)
    elif field_type == "passport":
        return tokenize_passport(value, config)
    else:
        raise FPEError(f"지원하지 않는 필드 타입: {field_type!r}. 허용: {FIELD_TYPES}")


def detokenize(field_type: str, token: str, config: FPEConfig) -> str:
    """필드 타입에 따른 역토큰화 디스패치"""
    if field_type == "rrn":
        return detokenize_rrn(token, config)
    elif field_type == "card":
        return detokenize_card(token, config)
    elif field_type == "account":
        return detokenize_account(token, config)
    elif field_type == "passport":
        return detokenize_passport(token, config)
    else:
        raise FPEError(f"지원하지 않는 필드 타입: {field_type!r}")
