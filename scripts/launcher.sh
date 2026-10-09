#!/bin/bash
# Starts Dictator from this folder. Runs until Ctrl+C.
DIR="$(cd "$(dirname "$0")" && pwd)"
# A browser download marks files as quarantined and macOS refuses to run them; clearing our own
# folder needs no admin rights. (curl, unzip and git downloads are not marked.)
xattr -dr com.apple.quarantine "$DIR" 2>/dev/null
exec "$DIR/bin/dictator" "$@"
