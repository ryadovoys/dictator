# Renders the README badges as pixel-art SVGs: a 3×5 bitmap font drawn as rectangles, so they look
# the same everywhere (GitHub does not load fonts inside SVG images). Run: python3 badges.py
from pathlib import Path

OUT = Path(__file__).parent.parent / "assets" / "badges"
PX = 2          # screen pixels per font pixel
PAD_X, PAD_Y = 3, 2
LABEL, VALUE, TEXT = "#3a3a3a", "#000000", "#f2f2f2"

FONT = {
    "A": [".#.", "#.#", "###", "#.#", "#.#"],
    "C": [".##", "#..", "#..", "#..", ".##"],
    "E": ["###", "#..", "##.", "#..", "###"],
    "F": ["###", "#..", "##.", "#..", "#.."],
    "I": ["###", ".#.", ".#.", ".#.", "###"],
    "L": ["#..", "#..", "#..", "#..", "###"],
    "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"],
    "N": ["#..#", "##.#", "#.##", "#..#", "#..#"],
    "O": [".##.", "#..#", "#..#", "#..#", ".##."],
    "P": ["##.", "#.#", "##.", "#..", "#.."],
    "S": [".##", "#..", ".#.", "..#", "##."],
    "T": ["###", ".#.", ".#.", ".#.", ".#."],
    "0": [".#.", "#.#", "#.#", "#.#", ".#."],
    "1": [".#.", "##.", ".#.", ".#.", "###"],
    "5": ["###", "#..", "##.", "..#", "##."],
    "%": ["#.#", "..#", ".#.", "#..", "#.#"],
    "+": ["...", ".#.", "###", ".#.", "..."],
    " ": ["..", "..", "..", "..", ".."],
}

BADGES = {
    "macos-15": ("MACOS", "15+"),
    "apple-silicon-m1": ("APPLE SILICON", "M1+"),
    "offline-100": ("100%", "OFFLINE"),
    "license-mit": ("LICENSE", "MIT"),
}


def text_width(text):
    return sum(len(FONT[c][0]) for c in text) + len(text) - 1


def text_rects(text, x0, y0):
    rects, x = [], x0
    for c in text:
        glyph = FONT[c]
        for y, row in enumerate(glyph):
            for gx, cell in enumerate(row):
                if cell == "#":
                    rects.append((x + gx, y0 + y, 1, 1))
        x += len(glyph[0]) + 1
    return rects


def badge(label, value):
    lw, vw = text_width(label) + 2 * PAD_X, text_width(value) + 2 * PAD_X
    w, h = lw + vw, len(FONT["A"]) + 2 * PAD_Y
    rect = lambda x, y, rw, rh, fill: f'<rect x="{x * PX}" y="{y * PX}" width="{rw * PX}" height="{rh * PX}" fill="{fill}"/>'
    # Segments with one pixel notched out of each outer corner.
    parts = [rect(1, 0, lw - 1, h, LABEL), rect(0, 1, 1, h - 2, LABEL),
             rect(lw, 0, vw - 1, h, VALUE), rect(w - 1, 1, 1, h - 2, VALUE)]
    parts += [rect(*r, TEXT) for r in text_rects(label, PAD_X, PAD_Y)]
    parts += [rect(*r, TEXT) for r in text_rects(value, lw + PAD_X, PAD_Y)]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w * PX}" height="{h * PX}" shape-rendering="crispEdges" '
            f'role="img" aria-label="{label.lower()}: {value.lower()}">' + "".join(parts) + "</svg>\n")


OUT.mkdir(parents=True, exist_ok=True)
for name, (label, value) in BADGES.items():
    (OUT / f"{name}.svg").write_text(badge(label, value))
