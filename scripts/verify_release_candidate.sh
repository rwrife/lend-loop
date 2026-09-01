#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

printf '\n=== TOOLCHAIN AND LOCKED DEPENDENCIES ===\n'
flutter --version
flutter pub get --enforce-lockfile

printf '\n=== RELEASE METADATA AND SIGNING-MATERIAL BOUNDARY ===\n'
./scripts/check_release_metadata.sh

printf '\n=== FORMATTING ===\n'
dart format --output=none --set-exit-if-changed .

printf '\n=== STATIC ANALYSIS ===\n'
flutter analyze

printf '\n=== AUTOMATED UNIT, WIDGET, AND ADAPTER TESTS ===\n'
flutter test --coverage

printf '\n=== AUTOMATED LIFECYCLE INTEGRATION TEST ===\n'
flutter test test/integration/lifecycle_matrix_test.dart

printf '\n=== RELEASE-CANDIDATE PACKAGING ===\n'
./scripts/build_release_artifacts.sh all

echo 'Release-candidate verification passed. Inspect artifact signing labels, logs, and SHA256SUMS before publication.'
