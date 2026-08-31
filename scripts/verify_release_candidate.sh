#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

printf '\n=== TOOLCHAIN AND LOCKED DEPENDENCIES ===\n'
flutter --version
flutter pub get --enforce-lockfile

printf '\n=== FORMATTING ===\n'
dart format --output=none --set-exit-if-changed .

printf '\n=== STATIC ANALYSIS ===\n'
flutter analyze

printf '\n=== AUTOMATED UNIT, WIDGET, AND ADAPTER TESTS ===\n'
flutter test --coverage

printf '\n=== AUTOMATED LIFECYCLE INTEGRATION TEST ===\n'
flutter test test/integration/lifecycle_matrix_test.dart

printf '\n=== UNSIGNED ANDROID DEBUG BUILD ===\n'
flutter build apk --debug

if [[ "$(uname -s)" == "Darwin" ]]; then
  printf '\n=== UNSIGNED IOS SIMULATOR BUILD ===\n'
  flutter build ios --simulator --no-codesign
else
  printf '\n=== IOS SIMULATOR BUILD: NOT RUN ===\n'
  echo 'Not run: flutter build ios requires a macOS host with Xcode.'
fi

echo 'Release-candidate verification passed. Builds are unsigned development/simulator evidence only.'
