#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck disable=SC1091
source release/rc.env

expected_version="${FLUTTER_BUILD_NAME}+${FLUTTER_BUILD_NUMBER}"
python3 - "$expected_version" <<'PY'
from pathlib import Path
import re
import sys

expected = sys.argv[1]
pubspec = Path("pubspec.yaml").read_text(encoding="utf-8")
match = re.search(r"(?m)^version:\s*([^\s#]+)\s*$", pubspec)
if match is None:
    raise SystemExit("release metadata check failed: pubspec.yaml has no version")
if match.group(1) != expected:
    raise SystemExit(
        f"release metadata check failed: pubspec version {match.group(1)!r} "
        f"does not match release/rc.env {expected!r}"
    )
PY

case "$RELEASE_TAG" in
  "v${FLUTTER_BUILD_NAME}-rc."*) ;;
  *)
    echo "release metadata check failed: RELEASE_TAG must match v${FLUTTER_BUILD_NAME}-rc.N" >&2
    exit 1
    ;;
esac

required_files=(
  CHANGELOG.md
  THIRD_PARTY_NOTICES.md
  docs/privacy.md
  docs/release-checklist.md
  docs/releasing.md
  docs/store-metadata.md
  docs/user-guide.md
  scripts/sha256_manifest.py
)
for path in "${required_files[@]}"; do
  if [[ ! -s "$path" ]]; then
    echo "release metadata check failed: missing or empty $path" >&2
    exit 1
  fi
done

if ! python3 - "$RELEASE_TAG" <<'PY'
from pathlib import Path
import sys

needle = f"## [{sys.argv[1].removeprefix('v')}]"
raise SystemExit(0 if needle in Path("CHANGELOG.md").read_text(encoding="utf-8") else 1)
PY
then
  echo "release metadata check failed: CHANGELOG.md has no section for $RELEASE_TAG" >&2
  exit 1
fi

shopt -s nocasematch
while IFS= read -r tracked; do
  case "$tracked" in
    android/key.properties|*.jks|*.keystore|*.jceks|*.bks|*.p12|*.pfx|*.pkcs12|*.p8|*.pk8|*.pkcs8|*.key|*.pem|*.ppk|*.der|*.cer|*.crt|*.cert|*.asc|*.gpg|*.mobileprovision|*.provisionprofile|*.credential|*.credentials)
      echo "release metadata check failed: signing material filename is tracked: $tracked" >&2
      exit 1
      ;;
  esac
done < <(git ls-files)
shopt -u nocasematch

echo "Release metadata valid for $RELEASE_TAG ($expected_version); no tracked filename matches the signing-material denylist."
