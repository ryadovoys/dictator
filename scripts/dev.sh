#!/bin/bash
# Dev loop: build a debug copy into ~/Tools/dictator and restart it in a Terminal tab.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_DIR="${DICTATOR_LOCAL_DIR:-$HOME/Tools/dictator}"
CLI_BINARY="$LOCAL_DIR/bin/dictator"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$LOCAL_DIR/bin"
swift build --disable-sandbox --package-path "$ROOT" --product Dictator
STAGED=$(mktemp "$LOCAL_DIR/bin/.dictator-dev.XXXXXX")
trap 'rm -f "$STAGED"' EXIT
cp "$ROOT/.build/debug/Dictator" "$STAGED"
chmod +x "$STAGED"
codesign --force --sign - "$STAGED"
codesign --verify --strict "$STAGED"

# Ctrl+C uses Dictator's graceful quit path, finishing an active dictation first.
PIDS=$(ps -axo pid=,comm= | awk -v executable="$CLI_BINARY" '$2 == executable { print $1 }')
for processID in $PIDS; do
    kill -INT "$processID"
    for ((attempt=0; attempt<200; attempt++)); do
        kill -0 "$processID" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$processID" 2>/dev/null; then
        echo "Dictator is still finishing. Run this script again after it stops." >&2
        exit 1
    fi
done
mv -f "$STAGED" "$CLI_BINARY"
cp "$ROOT/scripts/launcher.sh" "$LOCAL_DIR/dictator"
chmod +x "$LOCAL_DIR/dictator"
osascript - "$LOCAL_DIR/dictator" <<'APPLESCRIPT'
on run arguments
    -- Keep the local colour preview independent of NO_COLOR inherited by Terminal.
    set launchCommand to "env -u NO_COLOR " & quoted form of (item 1 of arguments)
    tell application "Terminal"
        set launchTab to missing value
        repeat with terminalWindow in windows
            repeat with terminalTab in tabs of terminalWindow
                if custom title of terminalTab is "Dictator" and not busy of terminalTab then
                    set launchTab to terminalTab
                    exit repeat
                end if
            end repeat
            if launchTab is not missing value then exit repeat
        end repeat
        if launchTab is missing value then
            set launchTab to do script launchCommand
        else
            do script launchCommand in launchTab
        end if
        set custom title of launchTab to "Dictator"
        activate
    end tell
end run
APPLESCRIPT
echo "Dictator CLI restarted in Terminal: $CLI_BINARY"
