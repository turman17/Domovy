-- Synthetic session-store.db. Its real schema is not verified; Domovy counts rows whose
-- session_id, sessionId or id equals a session's id, and never writes to it.
CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, summary TEXT, updated_at TEXT);
CREATE TABLE turns (turn_id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, role TEXT, text TEXT);
INSERT INTO sessions VALUES ('c0c0c0c0-1111-4111-8111-111111111111', '/Users/dev/code/orbit-api', 'Uploads table migration', '2026-11-20T09:15:20Z');
INSERT INTO turns (session_id, role, text) VALUES ('c0c0c0c0-1111-4111-8111-111111111111', 'user', 'synthetic'), ('c0c0c0c0-1111-4111-8111-111111111111', 'assistant', 'synthetic');
