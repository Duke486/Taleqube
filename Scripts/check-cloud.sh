#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
CLOUD_TMP="$(mktemp -d)"
trap 'rm -rf "$CLOUD_TMP"' EXIT
python3 - "$CLOUD_TMP/types.swift" <<'PY'
from pathlib import Path
import sys
text=Path('AniShelf/Core/CloudJournal.swift').read_text()
Path(sys.argv[1]).write_text(text.split('\nextension LibraryDatabase')[0] + text[text.index('\n/// Codable Set'):])
PY
swiftc -module-cache-path "$CLOUD_TMP/modules" AniShelf/Core/S3Transport.swift "$CLOUD_TMP/types.swift" Tests/CloudProtocolChecks.swift -o "$CLOUD_TMP/checks"
"$CLOUD_TMP/checks"
swiftc -module-cache-path "$CLOUD_TMP/modules" AniShelf/Core/S3Transport.swift Tests/S3TransportChecks.swift -o "$CLOUD_TMP/transport-checks"
"$CLOUD_TMP/transport-checks"
