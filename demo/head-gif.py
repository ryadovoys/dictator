# Renders the talking Dictator head (no bubble) as a looping, transparent GIF for the README.
# Faces come from demo.html (copied from PixelArt.swift). Run: python3 head-gif.py
import json, re
from pathlib import Path
from PIL import Image

HERE = Path(__file__).parent
PIXELS = json.loads(re.search(r"const PIXELS = (\{.*?\});", (HERE / "demo.html").read_text()).group(1))
CELL = 8
MOUTH_STEP = 110  # ms, as CharacterIndicator.mouthStep
TALK = [2, 4, 1, 5, 3, 1, 4, 2, 5, 3]  # CharacterIndicator.talkSequence
# Phrases separated by closed-mouth pauses: (talking frames, pause ms).
PHRASES = [(14, 450), (9, 300), (17, 800)]


def frame(face):
    grid = PIXELS["faces"][face]
    image = Image.new("P", (len(grid[0]) * CELL, len(grid) * CELL), 0)
    image.putpalette([0, 0, 0, 0, 0, 0, 255, 255, 255])  # 0 transparent, 1 black, 2 white
    for y, row in enumerate(grid):
        for x, cell in enumerate(row):
            if cell != ".":
                image.paste(1 if cell == "k" else 2, (x * CELL, y * CELL, (x + 1) * CELL, (y + 1) * CELL))
    return image


frames, durations, step = [], [], 0
for talking, pause in PHRASES:
    for _ in range(talking):
        frames.append(frame(TALK[step % len(TALK)])); durations.append(MOUTH_STEP); step += 1
    frames.append(frame(0)); durations.append(pause)

frames[0].save(HERE.parent / "assets" / "dictator-head.gif", save_all=True, append_images=frames[1:],
               duration=durations, loop=0, transparency=0, disposal=2, optimize=False)
