.PHONY: verify-rc test-integration

verify-rc:
	./scripts/verify_release_candidate.sh

test-integration:
	flutter test test/integration/lifecycle_matrix_test.dart
