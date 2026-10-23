#!/bin/zsh
# Builds Nav.app, installs it to /Applications and (re)starts it.
# Running from /Applications keeps the login item stable across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh
pkill -x Nav || true
sleep 0.5
rm -rf /Applications/Nav.app
ditto build/Nav.app /Applications/Nav.app
open /Applications/Nav.app
echo "Installed /Applications/Nav.app"
