"""
테스트용 한글 샘플 이미지 생성. Pillow + macOS 시스템 한글 폰트.

용도: Stage B-0 OCR smoke. PaddleOCR 한국어 모드가 실제 한글을 읽는지 검증.
"""
from __future__ import annotations

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


LINES = [
    ("주민등록증", 60),
    ("홍길동 (洪吉童)", 40),
    ("900101-1234567", 40),
    ("서울특별시 강남구 테헤란로 123", 36),
    ("2020년 03월 15일 발급", 32),
]


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


if __name__ == "__main__":
    main()
