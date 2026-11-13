#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
CHECK_TMP="$(mktemp -d)"
trap 'rm -rf "$CHECK_TMP"' EXIT
python3 - "$CHECK_TMP/ArtworkCacheChecks.swift" <<'PY'
import pathlib, sys
source = pathlib.Path('AniShelf/Features/Poster.swift').read_text()
source = source[source.index('// NSCache'):source.index('// A dense color backing')]
source = source.replace('URL.cachesDirectory.appending(path:"AniShelf/Posters")', 'testRoot.appending(path:"Caches/Posters")')
source = source.replace('URL.applicationSupportDirectory.appending(path:"AniShelf/PreferredArtwork")', 'testRoot.appending(path:"Support/PreferredArtwork")')
source = source.replace('"artwork.cacheLimitMB"', '"artwork.tests." + UUID().uuidString')
template = pathlib.Path('Tests/ArtworkCacheChecks.swift').read_text()
pathlib.Path(sys.argv[1]).write_text(template.replace('// PRODUCTION_CACHE', source))
PY
swiftc -parse-as-library -swift-version 5 -module-cache-path "${TMPDIR:-/tmp/}AniShelf-artwork-check-modules" "$CHECK_TMP/ArtworkCacheChecks.swift" -o "$CHECK_TMP/checks"
"$CHECK_TMP/checks"
