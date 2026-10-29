#!/usr/bin/env python3
"""Render the 1000-row file-round charts from the versionCode 2009 phone sample.

Bars are linear inside each row: length is that engine's measurement divided
by the larger measurement on the same row. A shared axis would hide the
microsecond rows next to a 327 ms insert, and a log axis would shrink the gap.
The separate-delete file is 603.6 KB because the size is taken before close
and still includes the redo.
"""

import os

from PIL import Image, ImageDraw, ImageFont

REGULAR = "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"
BOLD = "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf"

BG = (16, 20, 24)
INK = (244, 241, 234)
MUTED = (154, 167, 178)
TRACK = (32, 40, 48)
NATIVE = (126, 182, 217)
PLUS = (224, 164, 90)
PILL = (46, 36, 24)

# File round, versionCode 2009, Asia/Hebron 14:00 on 2026-10-29.
# name, native microseconds, sqlite_plus microseconds, native label, plus label
ROWS = [
    ("Separate insert", 326_800, 162_200, "326.8 ms", "162.2 ms"),
    ("Transaction insert", 81_000, 72_600, "81.0 ms", "72.6 ms"),
    ("Separate update", 477_600, 381_200, "477.6 ms", "381.2 ms"),
    ("Bulk update", 915, 246, "915 µs", "246 µs"),
    ("Search", 129_400, 11_700, "129.4 ms", "11.7 ms"),
    ("Point lookup", 105_900, 7_600, "105.9 ms", "7.6 ms"),
    ("VACUUM", 923, 13, "923 µs", "13 µs"),
    ("Separate delete", 413_800, 345_500, "413.8 ms", "345.5 ms"),
    ("Delete all", 773, 259, "773 µs", "259 µs"),
]

SIZES = [
    ("Separate insert", 36.0, 115.0),
    ("Transaction insert", 36.0, 28.4),
    ("Separate update", 36.0, 82.9),
    ("Bulk update", 36.0, 28.5),
    ("Search", 52.0, 64.7),
    ("Point lookup", 36.0, 28.4),
    ("VACUUM", 36.0, 28.4),
    ("Separate delete", 16.0, 603.6),
    ("Delete all", 16.0, 28.5),
]


def font(path, size):
    return ImageFont.truetype(path, size)


def text_width(draw, face, value):
    return draw.textlength(value, font=face)


def rounded(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def speedup(native_us, plus_us):
    value = native_us / plus_us
    if value >= 10:
        return f"{value:.0f}×"
    return f"{value:.1f}×"


def render_time(path):
    scale = 2
    width, height = 1280, 980
    image = Image.new("RGB", (width * scale, height * scale), BG)
    draw = ImageDraw.Draw(image)
    title = font(BOLD, 34 * scale)
    sub = font(REGULAR, 16 * scale)
    label = font(BOLD, 15 * scale)
    value = font(REGULAR, 14 * scale)
    badge = font(BOLD, 16 * scale)
    legend = font(BOLD, 14 * scale)

    def s(n):
        return n * scale

    draw.text((s(48), s(32)), "File round, 1000 rows", font=title, fill=INK)
    draw.text(
        (s(48), s(78)),
        "One arm64 phone. Same SQL. Checksums matched. Bar length is measured time.",
        font=sub,
        fill=MUTED,
    )

    def legend_item(right_edge, color, name, face):
        width_px = text_width(draw, face, name)
        text_x = right_edge - width_px
        swatch_right = text_x - s(8)
        swatch_left = swatch_right - s(18)
        draw.rounded_rectangle(
            (swatch_left, legend_y, swatch_right, legend_y + s(14)),
            radius=s(4),
            fill=color,
        )
        draw.text((text_x, legend_y - s(3)), name, font=face, fill=INK)
        return swatch_left - s(22)

    legend_y = s(42)
    cursor = legend_item(s(width - 48), PLUS, "sqlite_plus", legend)
    legend_item(cursor, NATIVE, "native", legend)

    plot_left = s(240)
    plot_right = s(820)
    row_top = s(128)
    row_h = s(86)
    span = plot_right - plot_left

    for index, (name, native_us, plus_us, native_text, plus_text) in enumerate(ROWS):
        y = row_top + index * row_h
        draw.text((s(40), y + s(24)), name, font=label, fill=INK)
        slower = max(native_us, plus_us)
        bar_h = s(16)
        gap = s(8)
        native_y = y + s(12)
        plus_y = native_y + bar_h + gap
        rounded(draw, (plot_left, native_y, plot_right, native_y + bar_h), s(5), TRACK)
        rounded(draw, (plot_left, plus_y, plot_right, plus_y + bar_h), s(5), TRACK)
        for bar_y, us, color, caption in (
            (native_y, native_us, NATIVE, native_text),
            (plus_y, plus_us, PLUS, plus_text),
        ):
            length = span * (us / slower)
            end = plot_left + max(length, scale)
            rounded(draw, (plot_left, bar_y, end, bar_y + bar_h), s(5), color)
            draw.text((plot_right + s(12), bar_y - s(2)), caption, font=value, fill=color)
        mark = speedup(native_us, plus_us)
        mw = text_width(draw, badge, mark)
        pill_w = max(mw + s(22), s(72))
        pill_x = s(width - 48) - pill_w
        rounded(draw, (pill_x, y + s(22), pill_x + pill_w, y + s(56)), s(14), PILL)
        draw.text(
            (pill_x + (pill_w - mw) / 2, y + s(28)),
            mark,
            font=badge,
            fill=PLUS,
        )

    note = "Each row has its own linear scale. The gold figure is native time ÷ sqlite_plus time."
    draw.text((s(40), s(height - 48)), note, font=sub, fill=MUTED)
    image = image.resize((width, height), Image.Resampling.LANCZOS)
    image.save(path, "PNG", optimize=True)


def render_size(path):
    scale = 2
    width, height = 1280, 980
    image = Image.new("RGB", (width * scale, height * scale), BG)
    draw = ImageDraw.Draw(image)
    title = font(BOLD, 34 * scale)
    sub = font(REGULAR, 16 * scale)
    label = font(BOLD, 15 * scale)
    value = font(REGULAR, 14 * scale)
    legend = font(BOLD, 14 * scale)

    def s(n):
        return n * scale

    draw.text((s(48), s(32)), "File size, before close", font=title, fill=INK)
    draw.text(
        (s(48), s(78)),
        "Same file round. The sqlite_plus size includes the redo. Each row has its own scale.",
        font=sub,
        fill=MUTED,
    )

    def legend_item(right_edge, color, name, face):
        width_px = text_width(draw, face, name)
        text_x = right_edge - width_px
        swatch_right = text_x - s(8)
        swatch_left = swatch_right - s(18)
        draw.rounded_rectangle(
            (swatch_left, legend_y, swatch_right, legend_y + s(14)),
            radius=s(4),
            fill=color,
        )
        draw.text((text_x, legend_y - s(3)), name, font=face, fill=INK)
        return swatch_left - s(22)

    legend_y = s(42)
    cursor = legend_item(s(width - 48), PLUS, "sqlite_plus", legend)
    legend_item(cursor, NATIVE, "native", legend)

    plot_left = s(240)
    plot_right = s(900)
    row_top = s(128)
    row_h = s(86)
    span = plot_right - plot_left

    for index, (name, native_kb, plus_kb) in enumerate(SIZES):
        y = row_top + index * row_h
        draw.text((s(40), y + s(24)), name, font=label, fill=INK)
        larger = max(native_kb, plus_kb)
        bar_h = s(16)
        gap = s(8)
        native_y = y + s(12)
        plus_y = native_y + bar_h + gap
        rounded(draw, (plot_left, native_y, plot_right, native_y + bar_h), s(5), TRACK)
        rounded(draw, (plot_left, plus_y, plot_right, plus_y + bar_h), s(5), TRACK)
        for bar_y, kb, color in (
            (native_y, native_kb, NATIVE),
            (plus_y, plus_kb, PLUS),
        ):
            length = span * (kb / larger)
            end = plot_left + max(length, scale)
            rounded(draw, (plot_left, bar_y, end, bar_y + bar_h), s(5), color)
            caption = f"{kb:.1f} KB"
            draw.text((plot_right + s(12), bar_y - s(2)), caption, font=value, fill=color)

    note = "Separate delete stays large because close has not truncated the redo yet."
    draw.text((s(40), s(height - 48)), note, font=sub, fill=MUTED)
    image = image.resize((width, height), Image.Resampling.LANCZOS)
    image.save(path, "PNG", optimize=True)


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    doc = os.path.join(root, "doc")
    os.makedirs(doc, exist_ok=True)
    render_time(os.path.join(doc, "bench-time.png"))
    render_size(os.path.join(doc, "bench-size.png"))
    print("wrote", doc)
