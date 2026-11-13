#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
CHECK_TMP="$(mktemp -d)"
trap 'rm -rf "$CHECK_TMP"' EXIT
swiftc -swift-version 5 -module-cache-path "$CHECK_TMP/modules" \
  Taleqube/Core/Models.swift Taleqube/Core/AniListAPI.swift Tests/CoreChecks.swift \
  -o "$CHECK_TMP/core-checks"
"$CHECK_TMP/core-checks" "$@"
