# Database migration fixtures

Every committed `LendLoopDatabase.schemaVersion` has a seeded SQL fixture in
`test/fixtures/database/vN.sql`. The migration test opens each historical seed
through the current database, checks preservation of identity/history, checks
the expected attachment/reminder policy, runs `foreign_key_check`, and asserts
the resulting `user_version`.

## Updating fixtures

When changing the schema:

1. Increment `schemaVersion` and add an explicit forward-only `onUpgrade` step.
2. Do not edit old fixtures to resemble the new schema. They are immutable
   representations of releases already in users' hands.
3. Copy the exact post-migration schema into a new `vN.sql`, add distinctive
   seeded people, item, exchange, event, attachment, and reminder rows where
   those tables exist, and set `PRAGMA user_version = N`.
4. Add `N` to the version list in
   `test/data/database_migration_fixture_test.dart`. Extend its assertions for
   intentional preservation, transformation, or fail-closed behavior.
5. Run the migration test from v1 through current, then the full test suite.

Fixtures contain invented records and no exported user data, file paths,
photos, device identifiers, or notification payloads from real installations.
