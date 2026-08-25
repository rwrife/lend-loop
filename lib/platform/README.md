# Platform boundary

`PhotoAdapter` isolates optional photo access from the workflow and presentation tests. `ImagePickerPhotoAdapter` invokes the system photo picker only after the user taps the photo action, copies selected bytes to app-private storage, computes a SHA-256 digest, returns only portable metadata, and maps denied/cancelled access to non-fatal results. Notification and explicit file/share adapters remain future milestones.
