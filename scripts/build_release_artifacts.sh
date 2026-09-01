#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck disable=SC1091
source release/rc.env

platform="${1:-all}"
case "$platform" in
  android|ios|all) ;;
  *)
    echo "Usage: $0 [android|ios|all]" >&2
    exit 64
    ;;
esac

if [[ "$platform" == ios && "$(uname -s)" != Darwin ]]; then
  echo "iOS packaging requires macOS with Xcode." >&2
  exit 69
fi

artifact_root="${RELEASE_OUTPUT_DIR:-$repo_root/.artifacts/release-candidate}"
if [[ "$artifact_root" != /* ]]; then
  artifact_root="$repo_root/$artifact_root"
fi
artifact_root="$(python3 - "$artifact_root" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
case "$artifact_root" in
  */.artifacts/release-candidate) ;;
  *)
    echo "RELEASE_OUTPUT_DIR must name a dedicated .artifacts/release-candidate directory: $artifact_root" >&2
    exit 64
    ;;
esac
if [[ -L "$artifact_root" ]]; then
  echo "RELEASE_OUTPUT_DIR must not be a symbolic link: $artifact_root" >&2
  exit 64
fi
mkdir -p "$artifact_root"

base_evidence_log="$artifact_root/release-evidence.log"
evidence_log="$base_evidence_log"
: > "$evidence_log"

record_line() {
  printf '%s\n' "$*" | tee -a "$evidence_log"
}

record_command() {
  local rendered
  printf -v rendered '%q ' "$@"
  record_line "Command: ${rendered% }"
}

record_toolchain() {
  record_line "Commit SHA: $(git rev-parse HEAD)"
  if [[ "$(uname -s)" == Darwin ]]; then
    record_line "Host OS: $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
  else
    record_line "Host OS: $(uname -srm)"
  fi
  record_line "Flutter/Dart: $(flutter --version --machine | tr -d '\n')"
  record_line "Java: $(java -version 2>&1 | head -n 1)"
  if [[ "$(uname -s)" == Darwin ]]; then
    record_line "Xcode: $(xcodebuild -version | tr '\n' ' ' | sed 's/ $//')"
  else
    record_line "Xcode: not available (non-macOS host)"
  fi
}

run_logged() {
  local log_path="$1"
  shift
  record_command "$@"
  set -o pipefail
  "$@" 2>&1 | tee "$log_path"
}

copy_first_existing() {
  local destination="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      cp "$candidate" "$destination"
      return 0
    fi
  done
  echo "Expected build output was not found for $destination" >&2
  return 1
}

finalize_checksums() {
  local directory="$1"
  record_line "Checksum policy: SHA256SUMS excludes itself and packaging fails unless every entry and file verifies."
  record_command python3 scripts/sha256_manifest.py create "$directory"
  record_command python3 scripts/sha256_manifest.py verify "$directory"
  python3 scripts/sha256_manifest.py create "$directory"
  python3 scripts/sha256_manifest.py verify "$directory"
  printf 'Checksum verification: passed for %s/SHA256SUMS\n' \
    "$(basename "$directory")" | tee -a "$base_evidence_log"
}

verify_android_signature() {
  local kind="$1"
  local artifact="$2"
  local signing_requested="$3"
  local expected_fingerprint="$4"
  local verifier= result=unsigned actual_fingerprint= verification_output=

  if [[ "$kind" == apk ]] && command -v apksigner >/dev/null 2>&1; then
    verifier=apksigner
    record_command apksigner verify --verbose --print-certs "$artifact"
    if verification_output="$(apksigner verify --verbose --print-certs "$artifact" 2>&1)"; then
      result=signed-verified
    fi
    printf '%s\n' "$verification_output" | tee -a "$evidence_log"
    actual_fingerprint="$(python3 -c 'import re,sys; value=re.search(r"certificate SHA-256 digest:\s*([0-9a-fA-F:]+)", sys.stdin.read()); print(value.group(1).replace(":", "").lower() if value else "")' <<<"$verification_output")"
  elif command -v jarsigner >/dev/null 2>&1; then
    verifier=jarsigner
    record_command jarsigner -verify -verbose -certs "$artifact"
    verification_output="$(jarsigner -verify -verbose -certs "$artifact" 2>&1 || true)"
    printf '%s\n' "$verification_output" | tee -a "$evidence_log"
    if grep -Fq 'jar verified.' <<<"$verification_output"; then
      result=signed-verified
      if command -v keytool >/dev/null 2>&1; then
        record_command keytool -printcert -jarfile "$artifact"
        local certificate_output
        certificate_output="$(keytool -printcert -jarfile "$artifact" 2>&1)"
        printf '%s\n' "$certificate_output" | tee -a "$evidence_log"
        actual_fingerprint="$(python3 -c 'import re,sys; value=re.search(r"SHA256:\s*([0-9a-fA-F:]+)", sys.stdin.read()); print(value.group(1).replace(":", "").lower() if value else "")' <<<"$certificate_output")"
      fi
    fi
  fi

  if [[ "$signing_requested" != true && "$result" == signed-verified ]]; then
    echo "Android signing was not configured, but the $kind has a signature; refusing an unexpected signer." >&2
    return 1
  fi
  if [[ "$signing_requested" == true && "$result" == signed-verified && "$actual_fingerprint" != "$expected_fingerprint" ]]; then
    echo "Android $kind signer fingerprint does not match certificateSha256 in android/key.properties." >&2
    return 1
  fi
  if [[ "$result" != signed-verified && "$signing_requested" == true ]]; then
    if [[ -n "$verifier" ]]; then
      echo "Android signing was requested, but $kind signature verification with $verifier failed." >&2
    else
      echo "Android signing was requested, but no compatible signature verifier is available for $kind." >&2
    fi
    return 1
  fi
  if [[ "$result" == signed-verified ]]; then
    record_line "Signing result ($kind): signed, verified with $verifier"
  elif [[ -n "$verifier" ]]; then
    record_line "Signing result ($kind): unsigned; $verifier found no verifiable signature"
  else
    record_line "Signing result ($kind): unsigned; no compatible verifier available and signing was not requested"
  fi
  printf '%s\n' "$result"
}

read_expected_android_fingerprint() {
  python3 - <<'PY'
from pathlib import Path
import re

path = Path("android/key.properties")
values = {}
for raw_line in path.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", maxsplit=1)
    values[key.strip()] = value.strip()
fingerprint = values.get("certificateSha256", "").replace(":", "").lower()
if re.fullmatch(r"[0-9a-f]{64}", fingerprint) is None:
    raise SystemExit(
        "android/key.properties must contain the intended signer's 64-hex "
        "certificateSha256 fingerprint"
    )
print(fingerprint)
PY
}

build_android() {
  local out="$artifact_root/android"
  rm -rf "$out"
  mkdir -p "$out"
  cp "$base_evidence_log" "$out/release-evidence.log"
  cp "$artifact_root/release-metadata.log" "$out/release-metadata.log"
  cp "$artifact_root/flutter-clean.log" "$out/flutter-clean.log"
  cp "$artifact_root/flutter-pub-get.log" "$out/flutter-pub-get.log"
  evidence_log="$out/release-evidence.log"

  run_logged "$out/android-debug-apk.log" \
    flutter build apk --debug \
      --build-name="$FLUTTER_BUILD_NAME" \
      --build-number="$FLUTTER_BUILD_NUMBER"
  copy_first_existing \
    "$out/lend-loop-${RELEASE_TAG}-android-debug.apk" \
    build/app/outputs/flutter-apk/app-debug.apk

  run_logged "$out/android-release-apk.log" \
    flutter build apk --release \
      --build-name="$FLUTTER_BUILD_NAME" \
      --build-number="$FLUTTER_BUILD_NUMBER"

  local signing_requested=false
  local expected_fingerprint=
  [[ -f android/key.properties ]] && signing_requested=true
  if [[ "$signing_requested" == true ]]; then
    expected_fingerprint="$(read_expected_android_fingerprint)"
  fi
  local apk_staging="$out/release.apk"
  copy_first_existing \
    "$apk_staging" \
    build/app/outputs/flutter-apk/app-release.apk \
    build/app/outputs/apk/release/app-release.apk \
    build/app/outputs/apk/release/app-release-unsigned.apk
  local apk_signing_label
  apk_signing_label="$(verify_android_signature apk "$apk_staging" "$signing_requested" "$expected_fingerprint" | tail -n 1)"
  mv "$apk_staging" "$out/lend-loop-${RELEASE_TAG}-android-${apk_signing_label}.apk"

  run_logged "$out/android-release-aab.log" \
    flutter build appbundle --release \
      --build-name="$FLUTTER_BUILD_NAME" \
      --build-number="$FLUTTER_BUILD_NUMBER"
  local aab_staging="$out/release.aab"
  copy_first_existing \
    "$aab_staging" \
    build/app/outputs/bundle/release/app-release.aab
  local aab_signing_label
  aab_signing_label="$(verify_android_signature aab "$aab_staging" "$signing_requested" "$expected_fingerprint" | tail -n 1)"
  mv "$aab_staging" "$out/lend-loop-${RELEASE_TAG}-android-${aab_signing_label}.aab"

  finalize_checksums "$out"
  echo "Android artifacts: $out"
}

build_ios() {
  local out="$artifact_root/ios"
  rm -rf "$out"
  mkdir -p "$out"
  cp "$base_evidence_log" "$out/release-evidence.log"
  cp "$artifact_root/release-metadata.log" "$out/release-metadata.log"
  cp "$artifact_root/flutter-clean.log" "$out/flutter-clean.log"
  cp "$artifact_root/flutter-pub-get.log" "$out/flutter-pub-get.log"
  evidence_log="$out/release-evidence.log"

  run_logged "$out/ios-unsigned-archive.log" \
    flutter build ipa --release --no-codesign \
      --build-name="$FLUTTER_BUILD_NAME" \
      --build-number="$FLUTTER_BUILD_NUMBER"
  if [[ ! -d build/ios/archive/Runner.xcarchive ]]; then
    echo "Expected build/ios/archive/Runner.xcarchive was not produced." >&2
    return 1
  fi
  record_command ditto -c -k --sequesterRsrc --keepParent \
    build/ios/archive/Runner.xcarchive \
    "$out/lend-loop-${RELEASE_TAG}-ios-unsigned.xcarchive.zip"
  ditto -c -k --sequesterRsrc --keepParent \
    build/ios/archive/Runner.xcarchive \
    "$out/lend-loop-${RELEASE_TAG}-ios-unsigned.xcarchive.zip"

  run_logged "$out/ios-simulator.log" \
    flutter build ios --simulator --no-codesign \
      --build-name="$FLUTTER_BUILD_NAME" \
      --build-number="$FLUTTER_BUILD_NUMBER"
  if [[ ! -d build/ios/iphonesimulator/Runner.app ]]; then
    echo "Expected build/ios/iphonesimulator/Runner.app was not produced." >&2
    return 1
  fi
  record_command ditto -c -k --sequesterRsrc --keepParent \
    build/ios/iphonesimulator/Runner.app \
    "$out/lend-loop-${RELEASE_TAG}-ios-simulator.app.zip"
  ditto -c -k --sequesterRsrc --keepParent \
    build/ios/iphonesimulator/Runner.app \
    "$out/lend-loop-${RELEASE_TAG}-ios-simulator.app.zip"

  record_line "Signing result (iOS archive): unsigned (--no-codesign requested)"
  record_line "Signing result (iOS simulator): unsigned (--no-codesign requested)"
  finalize_checksums "$out"
  echo "iOS artifacts: $out"
}

record_toolchain
run_logged "$artifact_root/release-metadata.log" ./scripts/check_release_metadata.sh
run_logged "$artifact_root/flutter-clean.log" flutter clean
run_logged "$artifact_root/flutter-pub-get.log" flutter pub get --enforce-lockfile

case "$platform" in
  android) build_android ;;
  ios) build_ios ;;
  all)
    build_android
    if [[ "$(uname -s)" == Darwin ]]; then
      build_ios
    else
      echo "iOS archive and simulator build not run: macOS with Xcode is required."
    fi
    ;;
esac
