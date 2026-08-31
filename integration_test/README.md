# Integration tests

`../test/integration/lifecycle_matrix_test.dart` is a deterministic, headless
integration of the real workflow, Drift repository, backup service, and fake
notification boundary.
It covers record → schedule → return → export → clean restore without accessing
a plugin, network, or user storage. Run it with `make test-integration`.

Real plugin observations are intentionally separate and are documented in
`docs/release-test-matrix.md`; this test must never be reported as simulator or
physical-device evidence.
