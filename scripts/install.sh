#!/bin/bash
# Builds NotchLite and installs it into /Applications, replacing the installed copy.
#   scripts/install.sh              build + install + relaunch
#   VERSION=0.2.0 scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/NotchLite.app"
case "$DEST" in
    /Applications/NotchLite.app) ;;
    *) echo "error: unexpected install path '$DEST', refusing" >&2; exit 1 ;;
esac

scripts/build-app.sh

# Replace only once the running copy has exited, so we never swap a bundle in use.
pkill -x NotchLite 2>/dev/null || true
for _ in $(seq 1 50); do
    pgrep -x NotchLite >/dev/null || break
    sleep 0.1
done
if pgrep -x NotchLite >/dev/null; then
    echo "error: NotchLite is still running, not replacing it" >&2
    exit 1
fi

rm -rf "$DEST"
ditto build/NotchLite.app "$DEST"
open "$DEST"
echo "Installed $DEST"
