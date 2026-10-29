#!/usr/bin/env python3
"""Facebook post for sqlite_plus. Numbers are the measured 1000-row sample."""

import os
import re

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1080, 1350
S = 2

INTER = "/usr/share/fonts/truetype/macos/Inter-Regular.ttf"
INTER_MED = "/usr/share/fonts/truetype/macos/Inter-Medium.ttf"
INTER_SEMI = "/usr/share/fonts/truetype/macos/Inter-SemiBold.ttf"
INTER_BOLD = "/usr/share/fonts/truetype/macos/Inter-Bold.ttf"
MONO = "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf"
AR_BOLD = "/usr/share/fonts/truetype/noto/NotoSansArabic-Bold.ttf"

BG = (11, 13, 16)
INK = (244, 241, 234)
MUTED = (154, 164, 172)
GOLD = (224, 164, 90)
BLUE = (126, 182, 217)
VIOLET = (186, 168, 224)
LINE = (46, 56, 66)
CARD = (20, 25, 31)
STRING = (232, 201, 154)

# sqlite_plus time, sqflite time, native/sqlite_plus rounded from the sample.
STATS = [
    ("Separate insert", "6.5 ms", "514.9 ms", "79×"),
    ("Transaction insert", "3.5 ms", "104.6 ms", "30×"),
    ("Separate update", "247.5 ms", "508.2 ms", "2.1×"),
    ("Bulk update", "92 µs", "1.3 ms", "14×"),
    ("Search", "7.6 ms", "126.3 ms", "17×"),
    ("Point lookup", "9.6 ms", "116.2 ms", "12×"),
    ("VACUUM", "9 µs", "1.2 ms", "133×"),
    ("Separate delete", "168.0 ms", "352.7 ms", "2.1×"),
    ("Delete all", "105 µs", "732 µs", "7.0×"),
]

SQL = [
    "final db = await",
    "  MutableSqliteDatabase.create();",
    "",
    "await db.execute(",
    "  'CREATE TABLE books ('",
    "  'id INTEGER PRIMARY KEY,'",
    "  'title TEXT NOT NULL)');",
    "",
    "await db.execute(",
    "  'INSERT INTO books(id, title)'",
    "  ' VALUES (?, ?)',",
    "  [1, 'Kept Garden']);",
    "",
    "final kept = await db.query(",
    "  'SELECT title FROM books'",
    "  ' WHERE id = ?',",
    "  [1]);",
]

ORM = [
    "final db = await",
    "  MutableDatabaseConnection",
    "      .openMemory();",
    "final context = DbContext(",
    "  db, DbModel([bookType]));",
    "await context.migrations",
    "    .ensureCreated();",
    "",
    "final books = context.set(bookType);",
    "books.add(Book(BigInt.one,",
    "  'Kept Garden',",
    "  '{\"shelf\":\"north\"}', 0));",
    "await context.saveChanges();",
    "",
    "final kept = await books.query",
    "  .where(title.eq('Kept Garden'))",
    "  .single();",
]

PACKAGES = [
    ("sqlite_plus", "SQL, JSON, FTS5, and R-tree."),
    ("sqlite_plus_orm", "Typed queries and migrations."),
    ("sqlite_plus_generator", "Mappings, JSON, FTS, and R-tree."),
]

TOKEN = re.compile(
    r"'(?:\\.|[^'])*'"
    r"|\b(?:final|await)\b"
    r"|\b(?:MutableSqliteDatabase|MutableDatabaseConnection|DbContext|DbModel|BigInt|Book)\b"
    r"|\d+(?:\.\d+)?"
)


def face(path, size):
    return ImageFont.truetype(path, size * S)


def rounded(draw, box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def paint_code(draw, lines, x, y, font, line_h, max_x):
    keywords = {"final", "await"}
    types = {
        "MutableSqliteDatabase",
        "MutableDatabaseConnection",
        "DbContext",
        "DbModel",
        "BigInt",
        "Book",
    }
    widest = 0
    for line in lines:
        cursor = x
        pos = 0
        for match in TOKEN.finditer(line):
            if match.start() > pos:
                chunk = line[pos : match.start()]
                draw.text((cursor, y), chunk, font=font, fill=MUTED)
                cursor += draw.textlength(chunk, font=font)
            chunk = match.group(0)
            if chunk.startswith("'"):
                color = STRING
            elif chunk in keywords:
                color = VIOLET
            elif chunk in types:
                color = GOLD
            elif chunk[0].isdigit():
                color = INK
            else:
                color = MUTED
            draw.text((cursor, y), chunk, font=font, fill=color)
            cursor += draw.textlength(chunk, font=font)
            pos = match.end()
        if pos < len(line):
            chunk = line[pos:]
            draw.text((cursor, y), chunk, font=font, fill=MUTED)
            cursor += draw.textlength(chunk, font=font)
        widest = max(widest, cursor)
        if cursor > max_x:
            raise SystemExit(f"code overflow by {cursor - max_x}px: {line}")
        y += line_h
    return y, widest


def main():
    image = Image.new("RGB", (W * S, H * S), BG)
    glow = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((-180 * S, -240 * S, 640 * S, 480 * S), fill=(224, 164, 90, 36))
    gd.ellipse((620 * S, 980 * S, 1280 * S, 1600 * S), fill=(126, 182, 217, 28))
    glow = glow.filter(ImageFilter.GaussianBlur(64 * S))
    image = Image.alpha_composite(image.convert("RGBA"), glow).convert("RGB")
    draw = ImageDraw.Draw(image)

    def s(n):
        return int(round(n * S))

    draw.rectangle((0, 0, s(8), s(H)), fill=GOLD)

    kicker = face(AR_BOLD, 30)
    title = face(INTER_BOLD, 64)
    sub = face(INTER, 20)
    section = face(INTER_SEMI, 20)
    small = face(INTER, 15)
    legend_font = face(INTER_MED, 16)
    name_f = face(INTER_MED, 15)
    mult_f = face(INTER_BOLD, 42)
    time_f = face(INTER_SEMI, 16)
    mono = face(MONO, 18)
    mono_h = s(26)
    card_title = face(INTER_SEMI, 16)
    pkg_name = face(INTER_SEMI, 16)
    pkg_body = face(INTER, 14)
    pkg_kicker = face(INTER_MED, 13)

    draw.text(
        (s(40), s(28)),
        "محرك قواعد بيانات خالص",
        font=kicker,
        fill=GOLD,
        direction="rtl",
        language="ar",
    )

    draw.text((s(40), s(78)), "sqlite", font=title, fill=INK)
    plus_x = s(40) + draw.textlength("sqlite", font=title)
    draw.text((plus_x, s(78)), "_plus", font=title, fill=GOLD)

    draw.text(
        (s(40), s(156)),
        "SQL     JSON     FTS5     R-tree     ORM",
        font=sub,
        fill=MUTED,
    )

    draw.text((s(40), s(204)), "1000 rows", font=section, fill=INK)
    draw.text(
        (s(168), s(208)),
        "same SQL    ·    checksums matched    ·    × faster",
        font=small,
        fill=MUTED,
    )

    # Swatch sits to the left of its label. sqlite_plus is the right-hand chip.
    ly = s(206)
    right = s(W - 40)

    def legend_chip(right_edge, label, color):
        text_w = draw.textlength(label, font=legend_font)
        text_x = right_edge - text_w
        draw.text((text_x, ly), label, font=legend_font, fill=INK)
        swatch_right = text_x - s(8)
        swatch_left = swatch_right - s(14)
        draw.rounded_rectangle(
            (swatch_left, ly + s(5), swatch_right, ly + s(19)),
            radius=s(3),
            fill=color,
        )
        return swatch_left

    native_right = legend_chip(right, "sqlite_plus", GOLD) - s(22)
    legend_chip(native_right, "sqflite", BLUE)

    grid_x, grid_y = 40, 248
    cell_w, cell_h, gap = 324, 112, 12
    for index, (name, plus, native, mult) in enumerate(STATS):
        col, row = index % 3, index // 3
        x = s(grid_x + col * (cell_w + gap))
        y = s(grid_y + row * (cell_h + gap))
        rounded(draw, (x, y, x + s(cell_w), y + s(cell_h)), s(16), CARD, LINE, S)
        draw.text((x + s(16), y + s(12)), name, font=name_f, fill=MUTED)
        mw = draw.textlength(mult, font=mult_f)
        draw.text((x + (s(cell_w) - mw) / 2, y + s(34)), mult, font=mult_f, fill=INK)
        draw.text((x + s(16), y + s(84)), plus, font=time_f, fill=GOLD)
        nw = draw.textlength(native, font=time_f)
        draw.text((x + s(cell_w - 16) - nw, y + s(84)), native, font=time_f, fill=BLUE)

    code_top = grid_y + 3 * cell_h + 2 * gap + 22
    draw.text((s(40), s(code_top)), "The same books", font=section, fill=INK)
    panels_y = code_top + 32
    panel_w = (W - 80 - 16) // 2
    body_lines = max(len(SQL), len(ORM))
    panel_h = 56 + body_lines * 26 + 20
    panels = (
        (40, "sqlite_plus", GOLD, SQL),
        (40 + panel_w + 16, "sqlite_plus_orm", GOLD, ORM),
    )
    for x0, heading, accent, lines in panels:
        x = s(x0)
        y = s(panels_y)
        rounded(
            draw,
            (x, y, x + s(panel_w), y + s(panel_h)),
            s(18),
            (16, 20, 26),
            LINE,
            S,
        )
        draw.text((x + s(16), y + s(14)), heading, font=card_title, fill=accent)
        rule_y = y + s(40)
        draw.rectangle((x + s(16), rule_y, x + s(52), rule_y + s(3)), fill=accent)
        paint_code(
            draw,
            lines,
            x + s(16),
            y + s(52),
            mono,
            mono_h,
            x + s(panel_w - 12),
        )

    band_h = 124
    band_y = panels_y + panel_h + 18
    if band_y + band_h > H - 24:
        raise SystemExit(f"band overflows: y={band_y} h={band_h}")
    rounded(
        draw,
        (s(40), s(band_y), s(W - 40), s(band_y + band_h)),
        s(18),
        CARD,
        LINE,
        S,
    )
    draw.text((s(58), s(band_y + 16)), "pub.dev", font=pkg_kicker, fill=GOLD)
    col_w = (W - 80) / 3
    for index, (name, blurb) in enumerate(PACKAGES):
        cx = s(40 + index * col_w + 18)
        if index:
            divider = s(40 + index * col_w)
            draw.rectangle(
                (divider, s(band_y + 48), divider + S, s(band_y + band_h - 18)),
                fill=LINE,
            )
        draw.text((cx, s(band_y + 46)), name, font=pkg_name, fill=INK)
        draw.text((cx, s(band_y + 74)), blurb, font=pkg_body, fill=MUTED)

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sqlite_plus_facebook.png")
    image.convert("RGB").save(out, "PNG", optimize=True)
    print(out, image.size)


if __name__ == "__main__":
    main()
