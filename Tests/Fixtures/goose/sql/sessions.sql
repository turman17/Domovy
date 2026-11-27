-- Subset of block/goose@059fee25 crates/goose/src/session/session_manager.rs#L1165-L1240 (schema 18). Rows are synthetic.
CREATE TABLE schema_version (version INTEGER PRIMARY KEY);
INSERT INTO schema_version VALUES (18);
CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '', user_set_name BOOLEAN DEFAULT FALSE, session_type TEXT NOT NULL DEFAULT 'user', working_dir TEXT NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, extension_data TEXT DEFAULT '{}', archived_at TIMESTAMP, parent_session_id TEXT);
CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT, session_id TEXT NOT NULL REFERENCES sessions(id), role TEXT NOT NULL, content_json TEXT NOT NULL, created_timestamp INTEGER NOT NULL, timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, tokens INTEGER, metadata_json TEXT);
INSERT INTO sessions (id, name, working_dir, created_at, updated_at) VALUES ('20261120_1', 'Uploader retries', '/Users/dev/code/orbit-api', '2026-11-20 10:00:00', '2026-11-20 10:05:00');
INSERT INTO sessions (id, name, working_dir, created_at, updated_at, archived_at) VALUES ('20261101_2', 'Old spike', '/Users/dev/code/landing-site', '2026-11-01 10:00:00', '2026-11-01 10:05:00', '2026-11-02 08:00:00');
INSERT INTO messages (session_id, role, content_json, created_timestamp) VALUES ('20261120_1', 'user', '[{"type":"text","text":"Add retries to the uploader"}]', 1795600801);
INSERT INTO messages (session_id, role, content_json, created_timestamp) VALUES ('20261120_1', 'assistant', '[{"type":"text","text":"Done."},{"type":"toolRequest","id":"t1"}]', 1795600805);
