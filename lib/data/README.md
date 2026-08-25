# Data boundary

The Drift schema, migrations, and repository implementation persist people, items, exchanges, append-only events, attachments, and reminder metadata. `database_factory.dart` opens SQLite in the platform application-support directory. Record creation plus optional attachment metadata is transactional; return/reopen event and projection changes are transactional. Portable backup codecs remain a future milestone.
