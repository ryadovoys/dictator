<p align="center">
  <img src="assets/dictator-head.gif" width="128" alt="The pixel Dictator, looking at you and blinking">
</p>

<h1 align="center">Dictator</h1>

<p align="center"><b>A local dictation CLI for Mac. Rule your agents with your voice.</b></p>

<p align="center">A free, open-source alternative to Superwhisper, Wispr Flow and Granola, powered by NVIDIA Parakeet
running locally on your Mac. Lives in Terminal. Takes commands.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-black" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1%2B-black" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/100%25-offline-black" alt="100% offline">
  <img src="https://img.shields.io/badge/license-MIT-black" alt="MIT license">
</p>

---

<p align="center">
  <a href="assets/dictator-demo.mp4">
    <img src="assets/dictator-demo.gif" width="800" alt="Dictating to an agent: the pixel Dictator appears at the chat composer, the text is inserted and sent, the agent answers, and each dictation shows up in the Dictator Terminal window">
  </a>
</p>

<p align="center"><b>Tap Right Command, speak, tap again.</b> The text lands where you were typing:<br>
your coding agent's prompt, a chat, an email, a doc.</p>

## Get it

Open Terminal, go to the folder where you want it, and paste:

```bash
curl -fsSL -o dictator.zip https://github.com/ryadovoys/dictator/releases/latest/download/dictator.zip && unzip -oq dictator.zip && rm dictator.zip && ./dictator/dictator
```

That's the whole installation. The same command updates it later; `./dictator/dictator` starts it
again. The first start downloads the speech model once (about 470 MB).

Requires a Mac with Apple Silicon (M1 or later) and macOS 15 or later.

## Why Dictator

|  | Dictator | Typical dictation apps |
|---|---|---|
| Price | Free, MIT | Often a subscription |
| Installation | None: a folder you run from Terminal | An app, often admin rights |
| Works on a locked-down work Mac | Yes, nothing to install | Often blocked by IT |
| Where your audio goes | Nowhere. Transcribed on your Mac, then deleted | Often a cloud service |
| Hallucinated "Thank you." in silence | Filtered out before transcription | Common with Whisper-based apps |

## The regime in brief

- **One leader, one key.** Tap Right Command and the Dictator takes the floor. Tap it again and
  your words are decreed into whatever field you were typing in. Or hold it while you speak.
- **No foreign interference.** The speech model lives on your Mac. Not a syllable crosses the
  border.
- **No paperwork.** The palace is a folder. Run it from Terminal, close the tab to dissolve
  parliament.
- **The ministry of commands.** `/mic` reassigns the microphone, `/copy` recovers any of your
  last five speeches for the archives. Type `/` to see the full constitution.
- **Silence is not consent.** A clip with no voice in it stays silent: no phantom "Thank you"
  or "Yeah". Silence before and after your words is cut before transcription.
- **Failures are erased from history.** The audio is deleted, and the Dictator apologises.
  In his own way.

> *"Something went wrong, and heads will roll. Not yours. Try again."*
> *"Treason! The microphone refuses to cooperate. Try another with /mic."*
> *"Even my secret police heard nothing. Try again."*
>
> — the Dictator, when a dictation fails

## Use

- **Tap Right Command** (by itself) to start talking. The pixel Dictator appears under your text
  cursor and mouths along while you speak, pauses included. Tap again to stop and insert the text.
- **Or hold Right Command** while you speak and let go to insert (push-to-talk).
  Right Command + another key stays a normal shortcut.
- **⌃Space** does the same (tap or hold) and works even without any permission.
- **Esc** cancels. Or hover over the Dictator and click his pixel cross. He will not like it.

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
| Accessibility (optional) | Typing the text into the field; Dictator at the text cursor; Right Command | Text goes to the clipboard: press **⌘V**. The Dictator appears at the mouse pointer. |
| Input Monitoring (optional) | Right Command without Accessibility | Use **⌃Space** instead. |

On the first start Dictator asks macOS to show the Accessibility prompt; until it is on, a note
at the top explains clipboard mode and how to enable automatic insertion. `/accessibility`
opens that setting, and Dictator notices the change by itself, no restart needed. On a managed
Mac, Accessibility may need IT. Everything else works without it.

## If something goes wrong

- **“cannot be opened” / “killed”**: you downloaded the zip in a browser. Run
  `xattr -dr com.apple.quarantine dictator` once, or use the curl command above.
- **Model download fails** (blocked network): ask a teammate for their
  `Dictator Terminal/Models` folder and start with `DICTATOR_MODELS=/path/to/Models ./dictator/dictator`.
- **No speech heard / microphone silent**: pick another microphone with `/mic`.
- **Right Command does nothing**: turn on Accessibility (or Input Monitoring) for Terminal, or use
  ⌃Space. `/status` shows whether Right Command can be read. If ⌃Space switches your keyboard
  layout instead, that shortcut belongs to macOS (Keyboard → Keyboard Shortcuts → Input Sources).

`./dictator/dictator --help` lists the options. The model lives in
`~/Library/Application Support/Dictator Terminal/Models`.

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

## Contributing

The easiest way in: write the Dictator a new apology. They live in
[`Sources/Dictator/DictatorQuips.swift`](Sources/Dictator/DictatorQuips.swift), grouped by what
went wrong. Bug reports and pull requests are welcome too.

## License

MIT. See [LICENSE](LICENSE).
