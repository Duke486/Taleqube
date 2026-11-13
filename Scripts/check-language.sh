#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
LANGUAGE_TMP="$(mktemp -d)"
trap 'rm -rf "$LANGUAGE_TMP"' EXIT
swiftc -swift-version 5 -module-cache-path "$LANGUAGE_TMP/modules" \
  AniShelf/Core/Models.swift AniShelf/Core/AniListAPI.swift AniShelf/Core/Tracking.swift AniShelf/Core/CloudJournal.swift AniShelf/Core/CloudProjection.swift AniShelf/Core/LibraryDatabase.swift AniShelf/Core/LibraryArchive.swift \
  AniShelf/Core/Intelligence.swift AniShelf/Core/MediaLanguage.swift AniShelf/Core/Artwork.swift AniShelf/Core/Diagnostics.swift AniShelf/Core/LibraryIdentity.swift AniShelf/Core/ContentMapping.swift AniShelf/Core/SeasonMatching.swift AniShelf/Core/MatchingMetadata.swift \
  Tests/LanguageChecks.swift -o "$LANGUAGE_TMP/checks"
"$LANGUAGE_TMP/checks" "$@"
