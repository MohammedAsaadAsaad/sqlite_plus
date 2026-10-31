#!/usr/bin/env python3
"""Render the Linux desktop release charts.

Bars are linear inside each row: length is that engine's measurement divided
by the larger measurement on the same row. A shared axis would hide the
microsecond rows next to a multi-second insert.
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

# Linux desktop, release build, 1,000 rows. Native is sqflite through FFI.
# name, native microseconds, sqlite_plus microseconds, native label, plus label
MEMORY = [
    ("Separate insert", 1_896_000, 7_500, "1.896 s", "7.5 ms"),
    ("Transaction insert", 1_841_000, 7_000, "1.841 s", "7.0 ms"),
    ("Separate update", 1_853_000, 20_100, "1.853 s", "20.1 ms"),
    ("Bulk update", 1_800, 71, "1.8 ms", "71 µs"),
    ("Search", 1_864_000, 17_400, "1.864 s", "17.4 ms"),
    ("Point lookup", 1_995_000, 25_400, "1.995 s", "25.4 ms"),
    ("VACUUM", 2_200, 77, "2.2 ms", "77 µs"),
    ("Separate delete", 1_777_000, 13_200, "1.777 s", "13.2 ms"),
    ("Delete all", 1_400, 159, "1.4 ms", "159 µs"),
]

FILE = [
    ("Separate insert", 5_319_000, 1_523_000, "5.319 s", "1.523 s"),
    ("Transaction insert", 1_883_000, 181_500, "1.883 s", "181.5 ms"),
    ("Separate update", 5_452_000, 1_667_000, "5.452 s", "1.667 s"),
    ("Bulk update", 4_500, 1_400, "4.5 ms", "1.4 ms"),
    ("Search", 2_280_000, 16_100, "2.280 s", "16.1 ms"),
    ("Point lookup", 1_801_000, 17_400, "1.801 s", "17.4 ms"),
    ("VACUUM", 6_300, 36, "6.3 ms", "36 µs"),
    ("Separate delete", 5_207_000, 1_749_000, "5.207 s", "1.749 s"),
    ("Delete all", 4_500, 1_100, "4.5 ms", "1.1 ms"),
]

SIZES = [
    ("Separate insert", 28.0, 115.0),
    ("Transaction insert", 28.0, 28.4),
    ("Separate update", 28.0, 82.9),
    ("Bulk update", 28.0, 28.5),
    ("Search", 44.0, 64.7),
    ("Point lookup", 28.0, 28.4),
    ("VACUUM", 28.0, 28.4),
    ("Separate delete", 28.0, 603.6),
    ("Delete all", 28.0, 28.5),
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


def render_time(path, rows, heading, subtitle):
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

    draw.text((s(48), s(32)), heading, font=title, fill=INK)
    draw.text((s(48), s(78)), subtitle, font=sub, fill=MUTED)

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

    for index, (name, native_us, plus_us, native_text, plus_text) in enumerate(rows):
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
        "Linux file round, before close. The sqlite_plus size includes the redo.",
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


def render_migrations(path):
    scale = 2
    width, height = 1280, 560
    image = Image.new("RGB", (width * scale, height * scale), BG)
    draw = ImageDraw.Draw(image)
    title = font(BOLD, 32 * scale)
    sub = font(REGULAR, 16 * scale)
    kicker = font(BOLD, 13 * scale)
    card_title = font(BOLD, 22 * scale)
    body = font(REGULAR, 16 * scale)
    code = font(BOLD, 15 * scale)

    def s(n):
        return n * scale

    draw.text((s(48), s(36)), "The model is the schema", font=title, fill=INK)
    draw.text(
        (s(48), s(82)),
        "Create is automatic. A nullable column is safe. A rename or a drop is a statement you write.",
        font=sub,
        fill=MUTED,
    )

    cards = [
        (
            "01",
            "Create",
            ["An empty database.", "ensureCreated()", "Every mapped table is created."],
        ),
        (
            "02",
            "Add a column",
            ["Add a nullable field.", "plan()  then  applySafe()", "Stored rows stay. The new field is null."],
        ),
        (
            "03",
            "Rename or remove",
            ["plan() will not guess.", "Write the SQL. Approve that plan.", "Down is the reverse statement."],
        ),
    ]
    card_w, card_h = 376, 340
    left, top = 48, 150
    gap = 28
    for index, (number, name, lines) in enumerate(cards):
        x = s(left + index * (card_w + gap))
        y = s(top)
        rounded(draw, (x, y, x + s(card_w), y + s(card_h)), s(22), TRACK)
        draw.text((x + s(28), y + s(28)), number, font=kicker, fill=PLUS)
        draw.text((x + s(28), y + s(62)), name, font=card_title, fill=INK)
        for line_index, line in enumerate(lines):
            face = code if line_index == 1 else body
            color = INK if line_index == 1 else MUTED
            draw.text((x + s(28), y + s(140 + line_index * 52)), line, font=face, fill=color)

    image = image.resize((width, height), Image.Resampling.LANCZOS)
    image.save(path, "PNG", optimize=True)


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    doc = os.path.join(root, "doc")
    os.makedirs(doc, exist_ok=True)
    packages = os.path.dirname(root)
    render_migrations(
        os.path.join(packages, "sqlite_plus_orm", "doc", "migrations.png")
    )
    caption = "Linux desktop, release build. Same SQL. Checksums matched."
    render_time(
        os.path.join(doc, "bench-time.png"),
        MEMORY,
        "Memory round, 1000 rows",
        caption,
    )
    render_time(
        os.path.join(doc, "bench-file.png"),
        FILE,
        "File round, 1000 rows",
        caption,
    )
    render_size(os.path.join(doc, "bench-size.png"))
    print("wrote", doc)
