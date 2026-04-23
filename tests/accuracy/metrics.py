"""
metrics.py — OCR 정확도 측정 핵심 함수 모음

제공 기능:
  normalize()       — NFKC + 공백 제거 정규화
  levenshtein()     — DP 기반 편집 거리 (외부 의존 없음)
  find_best_match() — substring-window 기반 최적 매칭
  summarize()       — 샘플 목록에서 전체 지표 집계
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from typing import Optional


# ── 정규화 ────────────────────────────────────────────────────────────────────

def normalize(s: str) -> str:
    """NFKC 정규화 후 공백 전체 제거. 비교 전처리 기준."""
    s = unicodedata.normalize("NFKC", s)
    s = re.sub(r"\s+", "", s)
    return s.strip()


# ── Levenshtein 거리 ──────────────────────────────────────────────────────────

def levenshtein(a: str, b: str) -> int:
    """표준 DP Levenshtein. python-Levenshtein 없이도 동작."""
    if len(a) < len(b):
        a, b = b, a
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            cur.append(min(cur[-1] + 1, prev[j] + 1, prev[j - 1] + cost))
        prev = cur
    return prev[-1]


# ── 최적 매칭 ─────────────────────────────────────────────────────────────────

def find_best_match(expected: str, items: list[dict]) -> tuple[str, int]:
    """
    OCR items[] 중 expected text와 가장 가까운 항목을 반환.

    EasyOCR는 라인 전체("면허번호: 11-00-123456-79")를 반환하므로
    expected 길이와 동일한 substring window를 슬라이딩하여 비교.

    Returns:
        (matched_text, edit_distance)
    """
    exp = normalize(expected)
    if not exp:
        return "", 0

    best_text: str = ""
    best_d: int = 10 ** 9

    for it in items:
        raw = it.get("text", "")
        got = normalize(raw)

        if not got:
            continue

        exp_len = len(exp)
        got_len = len(got)

        if got_len < exp_len:
            # got가 더 짧으면 전체 비교만
            d = levenshtein(exp, got)
            if d < best_d:
                best_d, best_text = d, raw
            continue

        # substring window 슬라이딩 (O(exp_len × got_len))
        for i in range(got_len - exp_len + 1):
            window = got[i : i + exp_len]
            d = levenshtein(exp, window)
            if d < best_d:
                best_d, best_text = d, raw

        # 전체 문자열과도 비교 (짧은 expected가 더 잘 맞을 수 있음)
        d_full = levenshtein(exp, got)
        if d_full < best_d:
            best_d, best_text = d_full, raw

    return best_text, best_d


# ── 필드 결과 ─────────────────────────────────────────────────────────────────

@dataclass
class FieldResult:
    key: str
    expected_text: str
    matched_text: str
    edit_distance: int
    is_exact: bool                          # edit_distance == 0 (정규화 기준)
    is_within_tolerance: bool               # max_edit_distance 허용 범위 이내
    char_count: int                         # normalize(expected) 글자 수
    exact_match_required: bool = False      # tolerances.exact_match_required


@dataclass
class SampleResult:
    image: str
    category: str
    status: str                             # "done" | "failed" | "timeout"
    fail_reason: Optional[str] = None
    fields: list[FieldResult] = field(default_factory=list)
    ocr_item_count: int = 0
    low_conf_count: int = 0
    total_items: int = 0

    # ── 집계 프로퍼티 ─────────────────────────────────────────────────────────
    @property
    def required_fields(self) -> list[FieldResult]:
        return [f for f in self.fields if f.expected_text]  # 모든 필드

    @property
    def exact_matched(self) -> int:
        return sum(1 for f in self.fields if f.is_exact)

    @property
    def within_tolerance(self) -> int:
        return sum(1 for f in self.fields if f.is_within_tolerance)

    @property
    def total_fields(self) -> int:
        return len(self.fields)

    @property
    def avg_edit_distance(self) -> float:
        if not self.fields:
            return 0.0
        return sum(f.edit_distance for f in self.fields) / len(self.fields)

    @property
    def char_accuracy(self) -> float:
        """char_accuracy = 1 - (sum(edit_dist) / sum(char_count))"""
        total_chars = sum(f.char_count for f in self.fields)
        total_edits = sum(f.edit_distance for f in self.fields)
        if total_chars == 0:
            return 1.0
        return max(0.0, 1.0 - total_edits / total_chars)

    @property
    def low_conf_rate(self) -> float:
        if self.total_items == 0:
            return 0.0
        return self.low_conf_count / self.total_items


# ── 전체 집계 ─────────────────────────────────────────────────────────────────

@dataclass
class Summary:
    total_images: int
    done_images: int
    failed_images: int
    total_fields: int
    exact_matched: int
    within_tolerance: int
    total_chars: int
    total_edits: int
    total_items: int
    low_conf_items: int

    @property
    def exact_match_rate(self) -> float:
        if self.total_fields == 0:
            return 0.0
        return self.exact_matched / self.total_fields

    @property
    def tolerance_match_rate(self) -> float:
        if self.total_fields == 0:
            return 0.0
        return self.within_tolerance / self.total_fields

    @property
    def avg_edit_distance(self) -> float:
        if self.total_fields == 0:
            return 0.0
        return self.total_edits / self.total_fields

    @property
    def char_accuracy(self) -> float:
        if self.total_chars == 0:
            return 1.0
        return max(0.0, 1.0 - self.total_edits / self.total_chars)

    @property
    def low_conf_rate(self) -> float:
        if self.total_items == 0:
            return 0.0
        return self.low_conf_items / self.total_items


def summarize(results: list[SampleResult]) -> Summary:
    """SampleResult 목록에서 전체 Summary 집계."""
    done = [r for r in results if r.status == "done"]
    failed = [r for r in results if r.status != "done"]
    all_fields = [f for r in done for f in r.fields]

    return Summary(
        total_images=len(results),
        done_images=len(done),
        failed_images=len(failed),
        total_fields=len(all_fields),
        exact_matched=sum(1 for f in all_fields if f.is_exact),
        within_tolerance=sum(1 for f in all_fields if f.is_within_tolerance),
        total_chars=sum(f.char_count for f in all_fields),
        total_edits=sum(f.edit_distance for f in all_fields),
        total_items=sum(r.total_items for r in done),
        low_conf_items=sum(r.low_conf_count for r in done),
    )


def evaluate_field(
    key: str,
    expected_text: str,
    items: list[dict],
    tolerances: dict,
) -> FieldResult:
    """
    단일 필드에 대해 find_best_match를 실행하고 FieldResult 반환.

    Args:
        key: 필드 키 (e.g. "name", "rrn")
        expected_text: 답안 text
        items: OCR items (각각 {"text": str, "confidence": float})
        tolerances: answer.json의 tolerances 블록
    """
    matched_text, edit_dist = find_best_match(expected_text, items)
    exp_norm = normalize(expected_text)
    char_count = max(len(exp_norm), 1)  # 0 나누기 방지

    is_exact = edit_dist == 0

    # max_edit_distance 허용치 적용
    max_ed = tolerances.get("max_edit_distance", {}).get(key)
    if max_ed is not None:
        is_within_tolerance = edit_dist <= max_ed
    else:
        is_within_tolerance = is_exact  # 기본: exact만 허용

    # exact_match_required 목록에 있으면 is_within_tolerance도 exact 기준으로 덮어씀
    if key in tolerances.get("exact_match_required", []):
        is_within_tolerance = is_exact

    return FieldResult(
        key=key,
        expected_text=expected_text,
        matched_text=matched_text,
        edit_distance=edit_dist,
        is_exact=is_exact,
        is_within_tolerance=is_within_tolerance,
        char_count=char_count,
        exact_match_required=(key in tolerances.get("exact_match_required", [])),
    )
