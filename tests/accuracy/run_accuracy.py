#!/usr/bin/env python3
"""
run_accuracy.py — OCR 정확도 측정 harness

사용법:
  python3 tests/accuracy/run_accuracy.py \
      --endpoint http://localhost:18080 \
      --token "$TOKEN" \
      --fixtures tests/accuracy/fixtures \
      --out tests/accuracy/reports \
      [--commit $(git rev-parse --short HEAD)]

흐름:
  1. fixtures/*.answer.json 로드
  2. 각 샘플: POST /documents → GET 폴링(60s) → items 수집
  3. 필드별 find_best_match → FieldResult 생성
  4. 전체 집계 → stdout 테이블 출력
  5. reports/baseline-<commit>.json 저장
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Optional

import urllib.request
import urllib.error

# metrics 모듈 (동일 디렉터리)
sys.path.insert(0, str(Path(__file__).parent))
from metrics import (
    SampleResult,
    FieldResult,
    evaluate_field,
    summarize,
    normalize,
)

# ── 상수 ──────────────────────────────────────────────────────────────────────
POLL_INTERVAL = 2          # GET 폴링 간격 (초)
POLL_TIMEOUT = 90          # 최대 대기 시간 (초)
CONF_THRESHOLD = 0.5       # low_conf 판단 기준


# ── HTTP 헬퍼 ─────────────────────────────────────────────────────────────────

def http_post_multipart(url: str, token: str, filepath: Path) -> dict[str, Any]:
    """
    multipart/form-data로 파일 업로드. urllib 사용 (requests 미설치 환경 대응).
    """
    boundary = "----OCRAccBoundary8675309"
    filename = filepath.name
    mime_type = "image/png"

    with open(filepath, "rb") as fh:
        file_data = fh.read()

    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {mime_type}\r\n\r\n"
    ).encode() + file_data + f"\r\n--{boundary}--\r\n".encode()

    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Authorization": f"Bearer {token}",
            "Content-Length": str(len(body)),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body_bytes = e.read()
        raise RuntimeError(
            f"POST {url} → HTTP {e.code}: {body_bytes.decode(errors='replace')}"
        ) from e


def http_get_json(url: str, token: str) -> tuple[int, dict[str, Any]]:
    """GET 요청 → (status_code, json_body)."""
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body_bytes = e.read()
        return e.code, {"error": body_bytes.decode(errors="replace")}


# ── 문서 처리 ─────────────────────────────────────────────────────────────────

def upload_and_poll(
    endpoint: str,
    token: str,
    image_path: Path,
) -> tuple[str, list[dict]]:
    """
    이미지를 업로드하고 OCR 완료까지 폴링.

    Returns:
        (status, items)
        status: "done" | "timeout" | "failed"
        items: OCR items 목록 (done일 때만 유효)

    Raises:
        RuntimeError: 업로드 실패
    """
    upload_url = f"{endpoint}/documents"
    resp = http_post_multipart(upload_url, token, image_path)
    doc_id = resp.get("id")
    if not doc_id:
        raise RuntimeError(f"업로드 응답에 id 없음: {resp}")

    get_url = f"{endpoint}/documents/{doc_id}"
    deadline = time.time() + POLL_TIMEOUT

    while time.time() < deadline:
        _, body = http_get_json(get_url, token)
        status = body.get("status", "UNKNOWN")

        if status == "OCR_DONE":
            items = body.get("items", [])
            return "done", items
        elif status == "OCR_FAILED":
            return "failed", []
        elif status in ("UPLOADED", "OCR_RUNNING"):
            time.sleep(POLL_INTERVAL)
        else:
            time.sleep(POLL_INTERVAL)

    return "timeout", []


# ── 샘플 평가 ─────────────────────────────────────────────────────────────────

def evaluate_sample(
    answer: dict,
    endpoint: str,
    token: str,
    fixtures_dir: Path,
    verbose: bool = False,
) -> SampleResult:
    image_name = answer["image"]
    category = answer.get("category", "unknown")
    image_path = fixtures_dir / image_name

    result = SampleResult(
        image=image_name.replace(".png", ""),
        category=category,
        status="failed",
    )

    if not image_path.exists():
        result.fail_reason = f"이미지 파일 없음: {image_path}"
        return result

    try:
        status, items = upload_and_poll(endpoint, token, image_path)
    except Exception as exc:
        result.fail_reason = str(exc)
        return result

    result.status = status
    result.total_items = len(items)
    result.low_conf_count = sum(
        1 for it in items if it.get("confidence", 1.0) < CONF_THRESHOLD
    )

    if status != "done":
        result.fail_reason = f"OCR 상태: {status}"
        return result

    tolerances = answer.get("tolerances", {})
    for ef in answer.get("expected_fields", []):
        key = ef["key"]
        expected_text = ef["text"]
        fr = evaluate_field(key, expected_text, items, tolerances)
        result.fields.append(fr)

        if verbose:
            mark = "✓" if fr.is_exact else ("≈" if fr.is_within_tolerance else "✗")
            print(
                f"    [{mark}] {key:20s} "
                f"exp={normalize(expected_text)!r:25s} "
                f"got={normalize(fr.matched_text)!r:25s} "
                f"d={fr.edit_distance}"
            )

    return result


# ── 테이블 출력 ───────────────────────────────────────────────────────────────

def _bar(width: int, char: str = "═") -> str:
    return char * width


def print_table(results: list[SampleResult], summary: Any) -> None:
    # 컬럼 너비 동적 계산
    name_w = max(
        len("SUMMARY (총 {} 이미지)".format(len(results))),
        max((len(r.image) for r in results), default=10),
        20,
    )
    col_widths = {
        "image": name_w,
        "cat":   15,
        "exact": 9,
        "tol":   9,
        "avg_d": 7,
        "char":  9,
        "items": 6,
        "status": 10,
    }

    def cell(s: str, w: int, align: str = "<") -> str:
        return f"{str(s):{align}{w}}"

    sep_top    = "╔" + "═" * (col_widths["image"] + 2) + "╤" + \
                 "═" * (col_widths["cat"] + 2) + "╤" + \
                 "═" * (col_widths["exact"] + 2) + "╤" + \
                 "═" * (col_widths["tol"] + 2) + "╤" + \
                 "═" * (col_widths["avg_d"] + 2) + "╤" + \
                 "═" * (col_widths["char"] + 2) + "╤" + \
                 "═" * (col_widths["items"] + 2) + "╤" + \
                 "═" * (col_widths["status"] + 2) + "╗"
    sep_mid    = "╠" + "═" * (col_widths["image"] + 2) + "╪" + \
                 "═" * (col_widths["cat"] + 2) + "╪" + \
                 "═" * (col_widths["exact"] + 2) + "╪" + \
                 "═" * (col_widths["tol"] + 2) + "╪" + \
                 "═" * (col_widths["avg_d"] + 2) + "╪" + \
                 "═" * (col_widths["char"] + 2) + "╪" + \
                 "═" * (col_widths["items"] + 2) + "╪" + \
                 "═" * (col_widths["status"] + 2) + "╣"
    sep_bot    = "╚" + "═" * (col_widths["image"] + 2) + "╧" + \
                 "═" * (col_widths["cat"] + 2) + "╧" + \
                 "═" * (col_widths["exact"] + 2) + "╧" + \
                 "═" * (col_widths["tol"] + 2) + "╧" + \
                 "═" * (col_widths["avg_d"] + 2) + "╧" + \
                 "═" * (col_widths["char"] + 2) + "╧" + \
                 "═" * (col_widths["items"] + 2) + "╧" + \
                 "═" * (col_widths["status"] + 2) + "╝"

    def row(image, cat, exact, tol, avg_d, char, items, status) -> str:
        return (
            "║ " + cell(image,  col_widths["image"]) +
            " │ " + cell(cat,   col_widths["cat"]) +
            " │ " + cell(exact, col_widths["exact"], ">") +
            " │ " + cell(tol,   col_widths["tol"], ">") +
            " │ " + cell(avg_d, col_widths["avg_d"], ">") +
            " │ " + cell(char,  col_widths["char"], ">") +
            " │ " + cell(items, col_widths["items"], ">") +
            " │ " + cell(status, col_widths["status"]) +
            " ║"
        )

    print(sep_top)
    print(row("image", "category", "exact", "tol", "avg_d", "char_acc", "items", "status"))
    print(sep_mid)

    for r in results:
        if r.status == "done":
            exact_str = f"{r.exact_matched}/{r.total_fields}"
            tol_str   = f"{sum(1 for f in r.fields if f.is_within_tolerance)}/{r.total_fields}"
            avg_d_str = f"{r.avg_edit_distance:.1f}"
            char_str  = f"{r.char_accuracy * 100:.1f}%"
            items_str = str(r.total_items)
            st_str    = "OK"
        else:
            exact_str = tol_str = avg_d_str = char_str = items_str = "-"
            st_str    = r.status.upper()[:10]

        print(row(r.image, r.category, exact_str, tol_str, avg_d_str, char_str, items_str, st_str))

    print(sep_mid)
    label = f"SUMMARY ({summary.done_images}/{summary.total_images} 성공)"
    print(row(
        label, "",
        f"{summary.exact_matched}/{summary.total_fields}",
        f"{summary.within_tolerance}/{summary.total_fields}",
        f"{summary.avg_edit_distance:.2f}",
        f"{summary.char_accuracy * 100:.1f}%",
        str(summary.total_items),
        "",
    ))
    print(sep_bot)

    # 추가 통계
    print()
    print(f"  exact_match_rate  : {summary.exact_match_rate * 100:.1f}%")
    print(f"  tolerance_rate    : {summary.tolerance_match_rate * 100:.1f}%")
    print(f"  avg_edit_distance : {summary.avg_edit_distance:.2f}")
    print(f"  char_accuracy     : {summary.char_accuracy * 100:.1f}%")
    print(f"  field_recall      : {summary.field_recall * 100:.1f}%")
    print(f"  low_conf_rate     : {summary.low_conf_rate * 100:.1f}%")
    print()


# ── 카테고리별 분석 ───────────────────────────────────────────────────────────

def print_category_breakdown(results: list[SampleResult]) -> None:
    from collections import defaultdict

    cats: dict[str, list[SampleResult]] = defaultdict(list)
    for r in results:
        cats[r.category].append(r)

    print("── 카테고리별 요약 ─────────────────────────────────")
    print(f"  {'category':<20} {'n':>3} {'char_acc':>9} {'exact_rate':>11}")
    print(f"  {'-'*20} {'---':>3} {'---------':>9} {'-----------':>11}")

    for cat in sorted(cats):
        samples = cats[cat]
        done = [r for r in samples if r.status == "done"]
        if not done:
            print(f"  {cat:<20} {len(samples):>3} {'N/A':>9} {'N/A':>11}")
            continue
        total_chars = sum(f.char_count for r in done for f in r.fields)
        total_edits = sum(f.edit_distance for r in done for f in r.fields)
        total_fields = sum(r.total_fields for r in done)
        exact = sum(r.exact_matched for r in done)
        char_acc = (1 - total_edits / total_chars) * 100 if total_chars else 100.0
        exact_rate = exact / total_fields * 100 if total_fields else 0.0
        print(f"  {cat:<20} {len(done):>3} {char_acc:>8.1f}% {exact_rate:>10.1f}%")

    print()


# ── 최악 샘플 ─────────────────────────────────────────────────────────────────

def print_worst_samples(results: list[SampleResult], n: int = 3) -> None:
    done = [r for r in results if r.status == "done"]
    worst = sorted(done, key=lambda r: r.char_accuracy)[:n]

    print(f"── 최저 char_accuracy {n}개 ──────────────────────────")
    for r in worst:
        print(f"  {r.image:<30} char_acc={r.char_accuracy*100:.1f}%  exact={r.exact_matched}/{r.total_fields}")
        for f in sorted(r.fields, key=lambda f: f.edit_distance, reverse=True)[:3]:
            print(
                f"    key={f.key:<20} d={f.edit_distance:2d}  "
                f"exp={normalize(f.expected_text)!r}  "
                f"got={normalize(f.matched_text)!r}"
            )
    print()


# ── JSON 저장 ─────────────────────────────────────────────────────────────────

def save_json(
    results: list[SampleResult],
    summary: Any,
    out_dir: Path,
    commit: str,
) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"baseline-{commit}.json"

    data = {
        "meta": {
            "commit": commit,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "engine": "EasyOCR",
            "langs": ["ko", "en"],
        },
        "summary": {
            "total_images": summary.total_images,
            "done_images": summary.done_images,
            "failed_images": summary.failed_images,
            "total_fields": summary.total_fields,
            "exact_matched": summary.exact_matched,
            "within_tolerance": summary.within_tolerance,
            "exact_match_rate": round(summary.exact_match_rate, 4),
            "field_recall": round(summary.field_recall, 4),
            "tolerance_match_rate": round(summary.tolerance_match_rate, 4),
            "avg_edit_distance": round(summary.avg_edit_distance, 4),
            "char_accuracy": round(summary.char_accuracy, 4),
            "low_conf_rate": round(summary.low_conf_rate, 4),
        },
        "samples": [],
    }

    for r in results:
        sample_data: dict = {
            "image": r.image,
            "category": r.category,
            "status": r.status,
            "fail_reason": r.fail_reason,
            "total_items": r.total_items,
            "low_conf_count": r.low_conf_count,
        }
        if r.status == "done":
            sample_data.update({
                "exact_matched": r.exact_matched,
                "total_fields": r.total_fields,
                "avg_edit_distance": round(r.avg_edit_distance, 4),
                "char_accuracy": round(r.char_accuracy, 4),
                "fields": [
                    {
                        "key": f.key,
                        "expected": f.expected_text,
                        "matched": f.matched_text,
                        "edit_distance": f.edit_distance,
                        "is_exact": f.is_exact,
                        "is_within_tolerance": f.is_within_tolerance,
                        "char_count": f.char_count,
                        "exact_match_required": f.exact_match_required,
                    }
                    for f in r.fields
                ],
            })
        data["samples"].append(sample_data)

    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)

    return out_path


# ── 메인 ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="OCR 정확도 harness — upload-api E2E 측정"
    )
    parser.add_argument("--endpoint", required=True, help="upload-api base URL")
    parser.add_argument("--token", required=True, help="Keycloak Bearer 토큰")
    parser.add_argument(
        "--fixtures",
        default="tests/accuracy/fixtures",
        help="fixtures 디렉터리 경로",
    )
    parser.add_argument(
        "--out",
        default="tests/accuracy/reports",
        help="리포트 출력 디렉터리",
    )
    parser.add_argument("--commit", default="unknown", help="git commit hash (short)")
    parser.add_argument("--verbose", "-v", action="store_true", help="필드별 상세 출력")
    parser.add_argument(
        "--min-success-rate",
        type=float,
        default=1.0,
        help="전체 성공률 임계값 (default 1.0 = 모든 샘플 OCR_DONE). 미달 시 exit 1",
    )
    args = parser.parse_args()

    fixtures_dir = Path(args.fixtures)
    out_dir = Path(args.out)

    answer_files = sorted(fixtures_dir.glob("*.answer.json"))
    if not answer_files:
        print(f"ERROR: fixtures 디렉터리에 answer.json 없음: {fixtures_dir}", file=sys.stderr)
        return 2

    print(f"\n OCR 정확도 harness 시작 — {len(answer_files)}개 샘플\n")
    print(f"  endpoint : {args.endpoint}")
    print(f"  fixtures : {fixtures_dir}")
    print(f"  commit   : {args.commit}\n")

    results: list[SampleResult] = []

    for af in answer_files:
        with open(af, encoding="utf-8") as fh:
            answer = json.load(fh)

        image_name = answer["image"]
        print(f"  처리 중: {image_name} ...", end=" ", flush=True)

        r = evaluate_sample(
            answer=answer,
            endpoint=args.endpoint,
            token=args.token,
            fixtures_dir=fixtures_dir,
            verbose=args.verbose,
        )
        results.append(r)

        if r.status == "done":
            print(
                f"done  char_acc={r.char_accuracy*100:.1f}%  "
                f"exact={r.exact_matched}/{r.total_fields}  "
                f"items={r.total_items}"
            )
        else:
            print(f"FAIL  ({r.fail_reason})")

        # worker 안정화 대기 (OOM / 재시작 방지)
        time.sleep(2)

    print()
    sm = summarize(results)
    print_table(results, sm)
    print_category_breakdown(results)
    print_worst_samples(results)

    json_path = save_json(results, sm, out_dir, args.commit)
    print(f"  JSON 저장: {json_path}")
    print()

    # exit code: 성공률 < min-success-rate 면 실패 (CI gate)
    success_rate = sm.done_images / sm.total_images if sm.total_images else 0.0
    if success_rate < args.min_success_rate:
        print(
            f"  FAIL: 성공률 {success_rate*100:.1f}% < 임계값 {args.min_success_rate*100:.1f}%",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
