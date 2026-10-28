#!/usr/bin/env python3
"""Render the 1000-row comparison charts. Times are the measured statement intervals."""

import math
import os

from PIL import Image, ImageDraw, ImageFont

REGULAR = "/usr/share/fonts/truetype/macos/Inter-Regular.ttf"
MEDIUM = "/usr/share/fonts/truetype/macos/Inter-Medium.ttf"
SEMIBOLD = "/usr/share/fonts/truetype/macos/Inter-SemiBold.ttf"
BOLD = "/usr/share/fonts/truetype/macos/Inter-Bold.ttf"

BG = (16, 20, 24)
CARD = (22, 28, 35)
INK = (244, 241, 234)
MUTED = (154, 167, 178)
LINE = (44, 56, 68)
NATIVE = (126, 182, 217)
PLUS = (224, 164, 90)
TRACK = (32, 40, 48)

# name, native microseconds, sqlite_plus microseconds, native label, plus label
ROWS = [
    ("Separate insert", 514_900, 6_500, "514.9 ms", "6.5 ms"),
    ("Transaction insert", 104_600, 3_500, "104.6 ms", "3.5 ms"),
    ("Separate update", 508_200, 247_500, "508.2 ms", "247.5 ms"),
    ("Bulk update", 1_300, 92, "1.3 ms", "92 µs"),
    ("Search", 126_300, 7_600, "126.3 ms", "7.6 ms"),
    ("Point lookup", 116_200, 9_600, "116.2 ms", "9.6 ms"),
    ("VACUUM", 1_200, 9, "1.2 ms", "9 µs"),
    ("Separate delete", 352_700, 168_000, "352.7 ms", "168.0 ms"),
    ("Delete all", 732, 105, "732 µs", "105 µs"),
]

SIZES = [
    ("Separate insert", 36.0, 28.0),
    ("Transaction insert", 36.0, 28.0),
    ("Separate update", 36.0, 28.0),
    ("Bulk update", 36.0, 28.0),
    ("Search", 52.0, 44.0),
    ("Point lookup", 36.0, 28.0),
    ("VACUUM", 36.0, 28.0),
    ("Separate delete", 16.0, 8.0),
    ("Delete all", 16.0, 8.0),
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
    width, height = 1280, 860
    image = Image.new("RGB", (width * scale, height * scale), BG)
    draw = ImageDraw.Draw(image)
    title = font(BOLD, 34 * scale)
    sub = font(REGULAR, 16 * scale)
    label = font(MEDIUM, 15 * scale)
    tick = font(REGULAR, 12 * scale)
    value = font(MEDIUM, 13 * scale)
    badge = font(SEMIBOLD, 15 * scale)
    legend = font(MEDIUM, 14 * scale)

    def s(n):
        return n * scale

    draw.text((s(48), s(36)), "1000 rows", font=title, fill=INK)
    draw.text(
        (s(48), s(80)),
        "Same SQL. Every checksum matched. Shorter bar is faster.",
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

    legend_y = s(48)
    cursor = legend_item(s(width - 48), PLUS, "sqlite_plus", legend)
    legend_item(cursor, NATIVE, "native", legend)

    plot_left = s(236)
    plot_right = s(860)
    row_top = s(140)
    row_h = s(72)
    lo, hi = math.log10(1), math.log10(1_000_000)

    def x_of(us):
        t = (math.log10(max(us, 1)) - lo) / (hi - lo)
        return plot_left + t * (plot_right - plot_left)

    ticks = [
        (1, "1 µs"),
        (10, "10 µs"),
        (100, "100 µs"),
        (1_000, "1 ms"),
        (10_000, "10 ms"),
        (100_000, "100 ms"),
        (1_000_000, "1 s"),
    ]
    axis_y = row_top + len(ROWS) * row_h + s(8)
    for us, name in ticks:
        x = x_of(us)
        draw.line((x, row_top - s(8), x, axis_y), fill=LINE, width=scale)
        tw = text_width(draw, tick, name)
        draw.text((x - tw / 2, axis_y + s(8)), name, font=tick, fill=MUTED)

    for index, (name, native_us, plus_us, native_text, plus_text) in enumerate(ROWS):
        y = row_top + index * row_h
        draw.text((s(40), y + s(18)), name, font=label, fill=INK)
        bar_h = s(16)
        gap = s(6)
        native_y = y + s(10)
        plus_y = native_y + bar_h + gap
        for bar_y, us, color, caption, column in (
            (native_y, native_us, NATIVE, native_text, s(878)),
            (plus_y, plus_us, PLUS, plus_text, s(878)),
        ):
            end = max(min(x_of(us), plot_right), plot_left + s(6))
            rounded(draw, (plot_left, bar_y, end, bar_y + bar_h), s(5), color)
            draw.text((column, bar_y - s(1)), caption, font=value, fill=color)
        mark = speedup(native_us, plus_us)
        mw = text_width(draw, badge, mark)
        pill_w = max(mw + s(22), s(72))
        pill_x = s(1168)
        pill = (pill_x, y + s(16), pill_x + pill_w, y + s(46))
        rounded(draw, pill, s(12), (46, 36, 24))
        draw.text(
            (pill_x + (pill_w - mw) / 2, y + s(20)),
            mark,
            font=badge,
            fill=PLUS,
        )

    note = "Log scale. The gold figure is native time ÷ sqlite_plus time."
    draw.text((s(40), s(height - 42)), note, font=sub, fill=MUTED)
    image = image.resize((width, height), Image.Resampling.LANCZOS)
    image.save(path, "PNG", optimize=True)


def render_size(path):
    scale = 2
    width, height = 1280, 780
    image = Image.new("RGB", (width * scale, height * scale), BG)
    draw = ImageDraw.Draw(image)
    title = font(BOLD, 34 * scale)
    sub = font(REGULAR, 16 * scale)
    label = font(MEDIUM, 15 * scale)
    tick = font(REGULAR, 12 * scale)
    value = font(MEDIUM, 13 * scale)
    legend = font(MEDIUM, 14 * scale)

    def s(n):
        return n * scale

    draw.text((s(48), s(36)), "Stored size", font=title, fill=INK)
    draw.text(
        (s(48), s(80)),
        "1000 rows, same statements. Native file beside the sqlite_plus image.",
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

    legend_y = s(48)
    cursor = legend_item(s(width - 48), PLUS, "sqlite_plus", legend)
    legend_item(cursor, NATIVE, "native", legend)

    plot_left = s(250)
    plot_right = s(1080)
    row_top = s(140)
    row_h = s(64)
    maximum = 60.0

    def x_of(kb):
        return plot_left + (kb / maximum) * (plot_right - plot_left)

    axis_y = row_top + len(SIZES) * row_h + s(6)
    for kb in (0, 16, 32, 48, 60):
        x = x_of(kb)
        draw.line((x, row_top - s(8), x, axis_y), fill=LINE, width=scale)
        name = f"{kb} KB"
        tw = text_width(draw, tick, name)
        anchor = x - tw / 2
        draw.text((anchor, axis_y + s(8)), name, font=tick, fill=MUTED)

    for index, (name, native_kb, plus_kb) in enumerate(SIZES):
        y = row_top + index * row_h
        draw.text((s(40), y + s(14)), name, font=label, fill=INK)
        bar_h = s(14)
        native_y = y + s(8)
        plus_y = native_y + bar_h + s(6)
        for kb, bar_y, color in (
            (native_kb, native_y, NATIVE),
            (plus_kb, plus_y, PLUS),
        ):
            end = max(x_of(kb), plot_left + s(4))
            rounded(draw, (plot_left, bar_y, end, bar_y + bar_h), s(4), color)
            caption = f"{kb:.1f} KB"
            draw.text((end + s(8), bar_y - s(2)), caption, font=value, fill=color)

    image = image.resize((width, height), Image.Resampling.LANCZOS)
    image.save(path, "PNG", optimize=True)


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    doc = os.path.join(root, "doc")
    os.makedirs(doc, exist_ok=True)
    render_time(os.path.join(doc, "bench-time.png"))
    render_size(os.path.join(doc, "bench-size.png"))
    print("wrote", doc)
