.PHONY: verify-rc verify-release-metadata package-android package-ios test-integration

verify-rc:
	./scripts/verify_release_candidate.sh

verify-release-metadata:
	./scripts/check_release_metadata.sh

package-android:
	./scripts/build_release_artifacts.sh android

package-ios:
	./scripts/build_release_artifacts.sh ios

test-integration:
	flutter test test/integration/lifecycle_matrix_test.dart
