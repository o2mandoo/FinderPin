#!/bin/bash
# Builds FinderPin and installs it to /Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

if pgrep -x FinderPin >/dev/null; then
    pkill -x FinderPin
    sleep 1
fi

rm -rf /Applications/FinderPin.app
cp -R build/FinderPin.app /Applications/FinderPin.app
open /Applications/FinderPin.app
echo "Installed /Applications/FinderPin.app"
