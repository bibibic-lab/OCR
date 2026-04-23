"""
테스트용 한글 샘플 이미지 생성. Pillow + macOS 시스템 한글 폰트.

용도:
  - Stage B-0 OCR smoke: tests/images/sample-id-korean.png (기존 유지)
  - Stage B-2 accuracy harness: tests/accuracy/fixtures/*.png (10종 다양한 문서 샘플)
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def find_korean_font() -> str:
    candidates = [
        "/System/Library/Fonts/AppleSDGothicNeo.ttc",  # macOS
        "/System/Library/Fonts/Supplemental/AppleGothic.ttf",  # macOS older
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",  # Linux
        "/usr/share/fonts/truetype/nanum/NanumGothic.ttf",
    ]
    for p in candidates:
        if os.path.exists(p):
            return p
    raise FileNotFoundError("no Korean font found; install Noto Sans CJK or run on macOS")


# B-0 / B-1 smoke 용 기존 라인 구성 (변경 금지)
LINES = [
    ("주민등록증", 60),
    ("홍길동 (洪吉童)", 40),
    ("900101-1234567", 40),
    ("서울특별시 강남구 테헤란로 123", 36),
    ("2020년 03월 15일 발급", 32),
]

# B-2 accuracy harness 10종 샘플 정의
# 각 항목: name → {category, size, lines, expected_fields, tolerances}
SAMPLES: dict[str, dict] = {
    # ── 1. 주민등록증 01 ─────────────────────────────────────────────
    "id-korean-01": {
        "category": "id-card",
        "size": (900, 500),
        "lines": [
            ("주민등록증", 60),
            ("홍길동", 40),
            ("900101-1234567", 40),
            ("서울특별시 강남구 테헤란로 123", 36),
            ("2020년 03월 15일 발급", 32),
        ],
        "expected_fields": [
            {"key": "doc_title",  "text": "주민등록증",                       "required": True},
            {"key": "name",       "text": "홍길동",                            "required": True},
            {"key": "rrn",        "text": "900101-1234567",                    "required": True},
            {"key": "address",    "text": "서울특별시 강남구 테헤란로 123",         "required": True},
            {"key": "issue_date", "text": "2020년 03월 15일 발급",              "required": True},
        ],
        "tolerances": {
            "exact_match_required": ["doc_title", "rrn"],
            "whitespace_normalized": True,
            "max_edit_distance": {"name": 1, "address": 3},
        },
    },

    # ── 2. 주민등록증 02 ─────────────────────────────────────────────
    "id-korean-02": {
        "category": "id-card",
        "size": (900, 500),
        "lines": [
            ("주민등록증", 60),
            ("김영수", 40),
            ("830515-1987654", 40),
            ("부산광역시 해운대구 센텀2로 45", 36),
            ("2018년 11월 02일 발급", 32),
        ],
        "expected_fields": [
            {"key": "doc_title",  "text": "주민등록증",                       "required": True},
            {"key": "name",       "text": "김영수",                            "required": True},
            {"key": "rrn",        "text": "830515-1987654",                    "required": True},
            {"key": "address",    "text": "부산광역시 해운대구 센텀2로 45",        "required": True},
            {"key": "issue_date", "text": "2018년 11월 02일 발급",              "required": True},
        ],
        "tolerances": {
            "exact_match_required": ["doc_title", "rrn"],
            "whitespace_normalized": True,
            "max_edit_distance": {"name": 1, "address": 3},
        },
    },

    # ── 3. 운전면허증 ─────────────────────────────────────────────────
    "driver-license-01": {
        "category": "driver-license",
        "size": (900, 560),
        "lines": [
            ("운전면허증", 60),
            ("이지은", 40),
            ("950712-2345678", 38),
            ("면허번호: 11-00-123456-79", 34),
            ("면허종별: 1종 보통", 34),
            ("유효기간: 2025년 07월 11일", 32),
        ],
        "expected_fields": [
            {"key": "doc_title",    "text": "운전면허증",                     "required": True},
            {"key": "name",         "text": "이지은",                          "required": True},
            {"key": "rrn",          "text": "950712-2345678",                  "required": True},
            {"key": "license_no",   "text": "11-00-123456-79",                 "required": True},
            {"key": "license_type", "text": "1종 보통",                        "required": True},
            {"key": "expiry_date",  "text": "2025년 07월 11일",               "required": True},
        ],
        "tolerances": {
            "exact_match_required": ["doc_title", "rrn", "license_no"],
            "whitespace_normalized": True,
            "max_edit_distance": {"name": 1, "license_type": 1},
        },
    },

    # ── 4. 사업자등록증 (법인) ────────────────────────────────────────
    "biz-license-01": {
        "category": "biz-license",
        "size": (1000, 600),
        "lines": [
            ("사업자등록증", 60),
            ("법인명: 주식회사 한빛소프트",         40),
            ("등록번호: 123-45-67890",             36),
            ("대표자: 박철수",                      36),
            ("업태: 정보통신업  종목: 소프트웨어 개발", 32),
            ("소재지: 서울특별시 마포구 와우산로 94",   32),
            ("개업연월일: 2015년 06월 01일",          30),
        ],
        "expected_fields": [
            {"key": "doc_title",      "text": "사업자등록증",                    "required": True},
            {"key": "company_name",   "text": "주식회사 한빛소프트",              "required": True},
            {"key": "reg_no",         "text": "123-45-67890",                   "required": True},
            {"key": "ceo_name",       "text": "박철수",                          "required": True},
            {"key": "business_type",  "text": "정보통신업",                      "required": True},
            {"key": "address",        "text": "서울특별시 마포구 와우산로 94",     "required": True},
            {"key": "open_date",      "text": "2015년 06월 01일",               "required": True},
        ],
        "tolerances": {
            "exact_match_required": ["doc_title", "reg_no"],
            "whitespace_normalized": True,
            "max_edit_distance": {"company_name": 2, "address": 4},
        },
    },

    # ── 5. 사업자등록증 (개인) ────────────────────────────────────────
    "biz-license-02": {
        "category": "biz-license",
        "size": (1000, 580),
        "lines": [
            ("사업자등록증",                          60),
            ("상호: 더나은떡볶이",                    40),
            ("등록번호: 456-78-90123",               36),
            ("대표자: 정미래",                        36),
            ("업태: 음식점업  종목: 분식점",            32),
            ("소재지: 경기도 수원시 팔달구 행궁로 11",   32),
            ("개업연월일: 2021년 03월 20일",           30),
        ],
        "expected_fields": [
            {"key": "doc_title",      "text": "사업자등록증",                       "required": True},
            {"key": "company_name",   "text": "더나은떡볶이",                       "required": True},
            {"key": "reg_no",         "text": "456-78-90123",                      "required": True},
            {"key": "ceo_name",       "text": "정미래",                             "required": True},
            {"key": "business_type",  "text": "음식점업",                           "required": True},
            {"key": "address",        "text": "경기도 수원시 팔달구 행궁로 11",       "required": True},
            {"key": "open_date",      "text": "2021년 03월 20일",                  "required": True},
        ],
        "tolerances": {
            "exact_match_required": ["doc_title", "reg_no"],
            "whitespace_normalized": True,
            "max_edit_distance": {"company_name": 2, "address": 4},
        },
    },

    # ── 6. 영수증 (단품) ─────────────────────────────────────────────
    "receipt-01": {
        "category": "receipt",
        "size": (600, 700),
        "lines": [
            ("영수증",                50),
            ("카페 블루문",            36),
            ("2026-04-15  14:32",    32),
            ("아메리카노            4,500", 30),
            ("부가세 (10%)            450", 30),
            ("합계                  4,950", 32),
            ("감사합니다",            28),
        ],
        "expected_fields": [
            {"key": "doc_title",    "text": "영수증",          "required": True},
            {"key": "store_name",   "text": "카페 블루문",      "required": True},
            {"key": "date",         "text": "2026-04-15",      "required": True},
            {"key": "item_name",    "text": "아메리카노",       "required": True},
            {"key": "item_price",   "text": "4,500",           "required": True},
            {"key": "total",        "text": "4,950",           "required": True},
        ],
        "tolerances": {
            "exact_match_required": ["doc_title", "total"],
            "whitespace_normalized": True,
            "max_edit_distance": {"store_name": 2, "item_name": 1},
        },
    },

    # ── 7. 영수증 (다품목) ───────────────────────────────────────────
    "receipt-02": {
        "category": "receipt",
        "size": (620, 820),
        "lines": [
            ("영수증",                       50),
            ("편의점 24시 강남점",             34),
            ("2026-04-18  09:05",           30),
            ("생수 500mL               800", 28),
            ("삼각김밥(참치)           1,200", 28),
            ("바나나우유               1,500", 28),
            ("껌 (스피아민트)            900", 28),
            ("────────────────────────────", 20),
            ("소계                    4,400", 28),
            ("부가세 (10%)               440", 28),
            ("합계                    4,840", 30),
        ],
        "expected_fields": [
            {"key": "doc_title",   "text": "영수증",             "required": True},
            {"key": "store_name",  "text": "편의점 24시 강남점",  "required": True},
            {"key": "date",        "text": "2026-04-18",         "required": True},
            {"key": "item1_name",  "text": "생수 500mL",         "required": True},
            {"key": "item1_price", "text": "800",                "required": True},
            {"key": "item4_name",  "text": "껌 (스피아민트)",     "required": False},
            {"key": "subtotal",    "text": "4,400",              "required": True},
            {"key": "total",       "text": "4,840",              "required": True},
        ],
        "tolerances": {
            "exact_match_required": ["doc_title", "total", "subtotal"],
            "whitespace_normalized": True,
            "max_edit_distance": {"store_name": 3, "item1_name": 2},
        },
    },

    # ── 8. 계약서 조각 ─────────────────────────────────────────────
    "contract-01": {
        "category": "contract",
        "size": (1200, 500),
        "lines": [
            ("용역 계약서",                                        50),
            ("갑: 주식회사 알파테크  (이하 \"갑\")",                  34),
            ("을: 프리랜서 최수진     (이하 \"을\")",                  34),
            ("계약금액: 금 오백만원정 (₩5,000,000)",                  34),
            ("계약기간: 2026년 05월 01일 ~ 2026년 07월 31일",         32),
            ("2026년 04월 22일  당사자 쌍방 서명함",                   30),
        ],
        "expected_fields": [
            {"key": "doc_title",      "text": "용역 계약서",                              "required": True},
            {"key": "party_a",        "text": "주식회사 알파테크",                         "required": True},
            {"key": "party_b",        "text": "프리랜서 최수진",                           "required": True},
            {"key": "contract_amount","text": "₩5,000,000",                             "required": True},
            {"key": "start_date",     "text": "2026년 05월 01일",                        "required": True},
            {"key": "end_date",       "text": "2026년 07월 31일",                        "required": True},
        ],
        "tolerances": {
            "exact_match_required": ["doc_title", "contract_amount"],
            "whitespace_normalized": True,
            "max_edit_distance": {"party_a": 2, "party_b": 2},
        },
    },

    # ── 9. 송장 (Invoice) ─────────────────────────────────────────
    "invoice-01": {
        "category": "invoice",
        "size": (1000, 680),
        "lines": [
            ("거래 명세서 (Invoice)",                                    50),
            ("공급자: 주식회사 베스트부품  사업자: 789-01-23456",          34),
            ("공급받는자: 한국전자(주)    담당: 이현우",                    34),
            ("발행일: 2026-03-31",                                       32),
            ("품목            단가      수량    금액",                     28),
            ("CPU 쿨러 A형   35,000원  × 10   350,000원",                28),
            ("써멀 패드 B형    8,500원  × 20   170,000원",                28),
            ("합계 (VAT 포함)                  572,000원",               32),
        ],
        "expected_fields": [
            {"key": "doc_title",    "text": "거래 명세서 (Invoice)",      "required": True},
            {"key": "supplier",     "text": "주식회사 베스트부품",          "required": True},
            {"key": "supplier_reg", "text": "789-01-23456",              "required": True},
            {"key": "buyer",        "text": "한국전자(주)",               "required": True},
            {"key": "issue_date",   "text": "2026-03-31",                "required": True},
            {"key": "item1_name",   "text": "CPU 쿨러 A형",              "required": True},
            {"key": "item1_price",  "text": "35,000원",                  "required": True},
            {"key": "item1_qty",    "text": "10",                        "required": True},
            {"key": "total",        "text": "572,000원",                 "required": True},
        ],
        "tolerances": {
            "exact_match_required": ["doc_title", "supplier_reg", "total"],
            "whitespace_normalized": True,
            "max_edit_distance": {"supplier": 2, "buyer": 2, "item1_name": 2},
        },
    },

    # ── 10. 혼합 (한영숫자 + 특수문자) ──────────────────────────────
    "mixed-01": {
        "category": "mixed",
        "size": (1000, 600),
        "lines": [
            ("혼합 문서 / Mixed Document",                               50),
            ("고객번호: KR-2026-ABC-00789",                              36),
            ("제품명: Ultra HD 모니터 27인치 (UHD-2700K)",               34),
            ("가격: ₩ 399,000  /  USD $ 289.99",                        32),
            ("규격: 3840×2160 @ 144Hz, HDR10+, sRGB 99%",              30),
            ("보증기간: 제조일로부터 36개월 (A/S 포함)",                   30),
            ("문의: support@bestelectronics.co.kr  ☎ 1588-0000",        28),
        ],
        "expected_fields": [
            {"key": "doc_title",     "text": "혼합 문서 / Mixed Document",              "required": True},
            {"key": "customer_no",   "text": "KR-2026-ABC-00789",                      "required": True},
            {"key": "product_name",  "text": "Ultra HD 모니터 27인치 (UHD-2700K)",      "required": True},
            {"key": "price_krw",     "text": "₩ 399,000",                             "required": True},
            {"key": "price_usd",     "text": "USD $ 289.99",                           "required": False},
            {"key": "resolution",    "text": "3840×2160",                              "required": True},
            {"key": "warranty",      "text": "36개월",                                 "required": True},
        ],
        "tolerances": {
            "exact_match_required": ["customer_no", "price_krw"],
            "whitespace_normalized": True,
            "max_edit_distance": {"product_name": 3, "resolution": 1},
        },
    },
}


def render_sample(name: str, config: dict, out_dir: Path) -> None:
    """샘플 이미지 한 장 렌더링."""
    W, H = config["size"]
    img = Image.new("RGB", (W, H), "white")
    draw = ImageDraw.Draw(img)
    font_path = find_korean_font()

    y = 40
    for text, size in config["lines"]:
        font = ImageFont.truetype(font_path, size)
        draw.text((60, y), text, fill="black", font=font)
        y += size + 24

    out = out_dir / f"{name}.png"
    img.save(out)
    print(f"wrote {out}  size={out.stat().st_size}B  dim={W}x{H}")


def write_answer(name: str, config: dict, out_dir: Path) -> None:
    """답안 JSON 파일 생성."""
    answer = {
        "image": f"{name}.png",
        "category": config["category"],
        "expected_fields": config["expected_fields"],
        "tolerances": config.get("tolerances", {}),
    }
    out = out_dir / f"{name}.answer.json"
    out.write_text(json.dumps(answer, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {out}")


# ── B-0 / B-1 smoke 용 기존 이미지 생성 ──────────────────────────────
def main() -> None:
    out_dir = Path(__file__).parent
    font_path = find_korean_font()

    W, H = 900, 500
    img = Image.new("RGB", (W, H), "white")
    draw = ImageDraw.Draw(img)

    y = 40
    for text, size in LINES:
        font = ImageFont.truetype(font_path, size)
        draw.text((60, y), text, fill="black", font=font)
        y += size + 24

    out = out_dir / "sample-id-korean.png"
    img.save(out)
    print(f"wrote {out}  size={out.stat().st_size}B  dim={W}x{H}  font={font_path}")


# ── B-2 accuracy harness 용 10종 샘플 생성 ───────────────────────────
def gen_fixtures(out_dir: Path | None = None) -> None:
    """10종 샘플 이미지 + 답안 JSON을 out_dir 에 생성."""
    if out_dir is None:
        out_dir = Path(__file__).parent.parent / "accuracy" / "fixtures"
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, config in SAMPLES.items():
        render_sample(name, config, out_dir)
        write_answer(name, config, out_dir)
    print(f"\n총 {len(SAMPLES)}종 샘플 이미지 + 답안 JSON 생성 완료 → {out_dir}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="OCR 테스트 샘플 이미지 생성")
    parser.add_argument(
        "--mode",
        choices=["smoke", "fixtures", "all"],
        default="smoke",
        help="smoke: B-0 단일 이미지, fixtures: B-2 10종 샘플, all: 둘 다",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="fixtures 출력 디렉터리 (기본: tests/accuracy/fixtures)",
    )
    args = parser.parse_args()

    if args.mode in ("smoke", "all"):
        main()
    if args.mode in ("fixtures", "all"):
        gen_fixtures(args.out)
