#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
TRACKING_TMP="$(mktemp -d)"
trap 'rm -rf "$TRACKING_TMP"' EXIT
swiftc -swift-version 5 -module-cache-path "$TRACKING_TMP/modules" Taleqube/Core/Models.swift Taleqube/Core/AniListAPI.swift Taleqube/Core/Tracking.swift Taleqube/Core/CloudJournal.swift Taleqube/Core/CloudProjection.swift Taleqube/Core/LibraryDatabase.swift Taleqube/Core/LibraryArchive.swift Taleqube/Core/Intelligence.swift Taleqube/Core/MediaLanguage.swift Taleqube/Core/Artwork.swift Taleqube/Core/Diagnostics.swift Taleqube/Core/LibraryIdentity.swift Taleqube/Core/ContentMapping.swift Taleqube/Core/SeasonMatching.swift Taleqube/Core/MatchingMetadata.swift Tests/CloudStorageChecks.swift -o "$TRACKING_TMP/checks"
"$TRACKING_TMP/checks"
