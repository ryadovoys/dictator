# Renders the resting Dictator head (looking straight at you, blinking now and then) as a looping,
# transparent GIF for the README. Pixels come from demo.html (copied from PixelArt.swift and
# CharacterEyes.swift). Run: python3 head-gif.py
import json, re
from pathlib import Path
from PIL import Image

HERE = Path(__file__).parent
SOURCE = (HERE / "demo.html").read_text()
PIXELS = json.loads(re.search(r"const PIXELS = (\{.*?\});", SOURCE).group(1))
CELL = 8
BLINK = 160  # ms, as CharacterEyeAnimation.silent
# Open-eye stretches between blinks, varied like the app so it never feels mechanical (ms).
GAPS = [2600, 3700, 450, 3100]


def eyes(name):
    return json.loads(re.search(rf"const {name} = (\[.*?\]);", SOURCE, re.S).group(1))


def face(eye_rows):
    # Eyes are pasted at cell (15, 18), as in demo.html's withEyes.
    return [row[:15] + eye_rows[y - 18] + row[35:] if 0 <= y - 18 < len(eye_rows) else row
            for y, row in enumerate(PIXELS["faces"][0])]


def frame(grid):
    image = Image.new("P", (len(grid[0]) * CELL, len(grid) * CELL), 0)
    image.putpalette([0, 0, 0, 0, 0, 0, 255, 255, 255])  # 0 transparent, 1 black, 2 white
    for y, row in enumerate(grid):
        for x, cell in enumerate(row):
            if cell != ".":
                image.paste(1 if cell == "k" else 2, (x * CELL, y * CELL, (x + 1) * CELL, (y + 1) * CELL))
    return image


forward, blink = frame(face(eyes("FORWARD_EYES"))), frame(face(eyes("BLINK_EYES")))
frames, durations = [], []
for gap in GAPS:
    frames += [forward, blink]; durations += [gap, BLINK]

frames[0].save(HERE.parent / "assets" / "dictator-head.gif", save_all=True, append_images=frames[1:],
               duration=durations, loop=0, transparency=0, disposal=2, optimize=False)
