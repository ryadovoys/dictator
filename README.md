<p align="center"><b>A local dictation CLI for Mac. Take control of your agents.</b></p>

<p align="center"><i>Tap Right Command, speak, and the text lands in any app: your agent's prompt, a chat, a doc.
Speech is turned into text on your Mac by NVIDIA Parakeet. It runs in a Terminal tab, with nothing to install.</i></p>

<p align="center">
  <a href="assets/dictator-demo.mp4">
    <img src="assets/dictator-demo.gif" width="800" alt="Dictator in a Terminal window: two dictations, switching the microphone with /mic, copying an earlier dictation with /copy">
  </a>
</p>

### The regime in brief

- **One leader, one key.** Tap Right Command and the Dictator takes the floor. Tap it again and
  your words are decreed into whatever field you were typing in. Or hold it while you speak.
- **No foreign interference.** The speech model lives on your Mac. Not a syllable crosses the
  border.
- **No installation, no paperwork.** The palace is a folder. Unzip it, run it from Terminal,
  close the tab to dissolve parliament.
- **The ministry of commands.** `/mic` reassigns the microphone, `/copy` recovers any of your
  last five speeches for the archives. Type `/` to see the full constitution.
- **Silence is not consent.** A clip with no voice in it stays silent: no phantom "Thank you"
  or "Yeah". Silence before and after your words is cut before transcription.
- **Failures are erased from history.** When something goes wrong, the Dictator apologises
  (in its own way) and tells you why.

Requires a Mac with Apple Silicon (M1 or later) and macOS 15 or later.

## Get it (and update it later)

Open Terminal, go to the folder where you want it, and paste:

```bash
curl -fsSL -o dictator.zip https://github.com/ryadovoys/dictator/releases/latest/download/dictator.zip && unzip -oq dictator.zip && rm dictator.zip && ./dictator/dictator
```

The same command updates an existing copy. To start it again later:

```bash
./dictator/dictator
```

The first start downloads the speech model (about 470 MB, once) into
`~/Library/Application Support/Dictator Terminal/Models`.

## Use

- **Tap Right Command** (by itself) to start talking. A small pixel Dictator
  appears with an animated mouth and speech bubble. They keep moving through pauses of up to
  0.7 seconds. Tap Right Command again to stop and insert the text.
- **Or hold Right Command** while you speak and let go to insert (push-to-talk).
  Right Command + another key stays a normal shortcut.
- **⌃Space** does the same (tap or hold) and works even without any permission.
- **Esc** cancels. You can also hover over the character and click its pixel cross to cancel,
  including while it is transcribing.

Everything else happens in the Terminal tab. Each dictation appears there, and the box at the
bottom takes commands: type `/` to see them, or just start typing (`mi` → `mic`, `mic 2`, …;
the `/` is optional). ↑↓ choose, Tab completes, Enter runs.

| Command | Does |
|---|---|
| `/mic` | choose a microphone (↑↓ and Enter, or its number); `/mic 2` picks number 2 directly |
| `/copy` | copy the last dictation; typing `copy` lists your last five to pick from |
| `/status` | model, microphone, permissions |
| `/clear` | clear the screen |
| `/accessibility` | ask macOS to let Dictator type the text for you |
| `/quit` | quit (Ctrl+C works too) |

### Run in the background

```bash
./dictator/dictator --background
```

Dictator keeps running after you close the tab (it still uses the tab's Terminal permissions).
Stop it with `./dictator/dictator --stop`. Its output goes to `~/Library/Logs/Dictator.log`.

The terminal interface is monochrome, with a red Recording dot and a green Ready dot.
Start with `--menu` to also get a menu-bar icon. `NO_COLOR=1` turns those colours off too.

## Permissions

macOS asks **Terminal** (not Dictator) for these, because Terminal started it:

| Permission | Needed for | Without it |
|---|---|---|
| Microphone | Recording | Dictator cannot work. Allow it when macOS asks. |
| Accessibility (optional) | Typing the text into the field; bubble at the text cursor; Right Command | Text goes to the clipboard: press **⌘V**. The bubble appears at the mouse pointer. |
| Input Monitoring (optional) | Right Command without Accessibility | Use **⌃Space** instead. |

On the first start Dictator asks macOS to show the Accessibility prompt; until it is on, a note
at the top explains clipboard mode and how to enable automatic insertion. `/accessibility`
opens that setting. Dictator notices
the change by itself, no restart needed. On a managed Mac, Accessibility may need IT. Everything
else works without it.

## If something goes wrong

- **“cannot be opened” / “killed”**: you downloaded the zip in a browser. Run
  `xattr -dr com.apple.quarantine dictator` once, or use the curl command above.
- **Model download fails** (blocked network): ask a teammate for their
  `Dictator Terminal/Models` folder and start with `DICTATOR_MODELS=/path/to/Models ./dictator/dictator`.
- **No speech heard / microphone silent**: pick another microphone with `/mic`.
- **Right Command does nothing**: turn on Accessibility (or Input Monitoring) for Terminal, or use
  ⌃Space. `/status` shows whether Right Command can be read. If ⌃Space switches your keyboard
  layout instead, that shortcut belongs to macOS (Keyboard → Keyboard Shortcuts → Input Sources).
- A failed dictation is not kept: Dictator apologises (in its own way), says why, and you try again.

`./dictator/dictator --help` lists the options.

## Build from source

Needs Xcode 16 or later (Swift 6 toolchain).

```bash
git clone https://github.com/ryadovoys/dictator.git && cd dictator
swift build -c release && .build/release/Dictator
```

| Path | What |
|---|---|
| `Sources/Dictator/` | the app: key handling, recording, transcription, terminal interface, pixel character |
| `Sources/DictationKit/` | microphone capture |
| `scripts/release.sh` | builds `dist/dictator.zip`, the download in the command above |
| `scripts/dev.sh` | dev loop: rebuild and restart the debug build in a Terminal tab |
| `tools/keytest.swift` | shows whether this Mac lets a terminal see Right Command |

Speech recognition is [FluidAudio](https://github.com/FluidInference/FluidAudio) running NVIDIA
Parakeet TDT 0.6b v3 and Silero VAD on device.

## License

MIT. See [LICENSE](LICENSE).
