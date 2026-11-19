#!/bin/zsh
# Builds MultipleSoundOutput.app into ./build.
#   scripts/build.sh            build only
#   scripts/build.sh --install  build, copy to /Applications and relaunch
set -euo pipefail

cd "${0:A:h}/.."
APP_NAME=MultipleSoundOutput

if command -v xcodegen >/dev/null; then
  xcodegen generate --quiet
fi

xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  ${CODE_SIGN_IDENTITY:+CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"} \
  -quiet \
  build

rm -rf "build/$APP_NAME.app"
cp -R "build/DerivedData/Build/Products/Release/$APP_NAME.app" "build/$APP_NAME.app"
echo "Built build/$APP_NAME.app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "build/$APP_NAME.app" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "Installed and launched /Applications/$APP_NAME.app"
fi
