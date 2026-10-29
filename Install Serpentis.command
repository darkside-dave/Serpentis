#!/bin/bash
# Serpentis installer: builds the app from source on this Mac and puts it in /Applications.
cd "$(dirname "$0")/app" || exit 1
LOG="$(pwd)/build-log.txt"

# macOS 13 or newer
major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$major" -lt 13 ]; then echo "Serpentis needs macOS 13 (Ventura) or newer."; read -n 1 -s -r -p "Press any key to close."; exit 1; fi

# Apple's free developer tools
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Serpentis is built on your Mac, which needs Apple's free Command Line Developer Tools."
  echo "A window will open to install them (about 1 GB). When that finishes, double-click this installer again."
  xcode-select --install
  read -n 1 -s -r -p "Press any key to close."
  exit 1
fi

{
  echo "Building Serpentis... $(date)"
  echo "(this takes about a minute)"
  rm -rf build && mkdir -p build/Serpentis.app/Contents/MacOS
  if ! swiftc -O -swift-version 5 Sources/*.swift -o build/Serpentis.app/Contents/MacOS/Serpentis; then
    echo "BUILD FAILED - please open an issue on GitHub and attach app/build-log.txt"
    exit 1
  fi
  cp Info.plist build/Serpentis.app/Contents/Info.plist
  codesign --force -s - build/Serpentis.app && echo "Signed (local signature)"
  pkill -x Serpentis 2>/dev/null; sleep 1
  rm -rf /Applications/Serpentis.app
  cp -R build/Serpentis.app /Applications/ && echo "Installed to /Applications/Serpentis.app"
  open /Applications/Serpentis.app && echo "Launched"
  echo "BUILD OK"
} 2>&1 | tee "$LOG"
echo
echo "Done. You can close this window."
