#!/bin/bash
# Dev loop: rebuild the debug binary and restart it in a Terminal tab titled "Dictator".
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$ROOT/.build/debug/Dictator"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

# Stop the running copy first, so the build never replaces a binary that is executing.
# Ctrl+C uses Dictator's graceful quit path, finishing an active dictation first.
PIDS=$(ps -axo pid=,comm= | awk -v executable="$BINARY" '$2 == executable { print $1 }')
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

swift build --disable-sandbox --package-path "$ROOT" --product Dictator
STATUS=$?
# A failed build leaves the previous binary in place; restart that one.
[ -x "$BINARY" ] || exit "$STATUS"

osascript - "$BINARY" <<'APPLESCRIPT'
on run arguments
    -- Keep the status colours visible even when Terminal sets NO_COLOR.
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
[ "$STATUS" -eq 0 ] && echo "Dictator restarted in Terminal: $BINARY" || echo "Build failed; the previous build was restarted." >&2
exit "$STATUS"
