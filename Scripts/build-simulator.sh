#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun --sdk iphonesimulator --show-sdk-version >/dev/null 2>&1; then
  print -u2 '请先安装完整 Xcode 27+，首次打开并安装 iOS 平台组件。'
  exit 1
fi
TALEQUBE_SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
if (( ${TALEQUBE_SDK_VERSION%%.*} < 27 )); then
  print -u2 "当前 iOS Simulator SDK 为 $TALEQUBE_SDK_VERSION，请安装 Xcode 27+。"
  exit 1
fi
xcodebuild -project Taleqube.xcodeproj -scheme Taleqube \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "${TMPDIR:-/tmp/}Taleqube-DerivedData" \
  CODE_SIGNING_ALLOWED=NO build
