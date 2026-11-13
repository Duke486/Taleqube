#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
LANGUAGE_TMP="$(mktemp -d)"
trap 'rm -rf "$LANGUAGE_TMP"' EXIT
swiftc -swift-version 5 -module-cache-path "$LANGUAGE_TMP/modules" \
  Taleqube/Core/Models.swift Taleqube/Core/AniListAPI.swift Taleqube/Core/Tracking.swift Taleqube/Core/CloudJournal.swift Taleqube/Core/CloudProjection.swift Taleqube/Core/LibraryDatabase.swift Taleqube/Core/LibraryArchive.swift \
  Taleqube/Core/Intelligence.swift Taleqube/Core/MediaLanguage.swift Taleqube/Core/Artwork.swift Taleqube/Core/Diagnostics.swift Taleqube/Core/LibraryIdentity.swift Taleqube/Core/ContentMapping.swift Taleqube/Core/SeasonMatching.swift Taleqube/Core/MatchingMetadata.swift \
  Tests/LanguageChecks.swift -o "$LANGUAGE_TMP/checks"
"$LANGUAGE_TMP/checks" "$@"
