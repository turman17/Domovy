-- crush.db after Crush's migrations at charmbracelet/crush@ee51fe87 (internal/db/migrations/*.sql;
-- names only, tables Domovy does not read left out), with synthetic rows. Times are unix seconds.
PRAGMA journal_mode = WAL;
CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT NOT NULL, message_count INTEGER NOT NULL DEFAULT 0 CHECK (message_count >= 0), prompt_tokens INTEGER NOT NULL DEFAULT 0, completion_tokens INTEGER NOT NULL DEFAULT 0, cost REAL NOT NULL DEFAULT 0.0, updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL, summary_message_id TEXT, todos TEXT, channel TEXT);
CREATE TABLE files (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, path TEXT NOT NULL, content TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE, UNIQUE(path, session_id, version));
CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, parts TEXT NOT NULL DEFAULT '[]', model TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, finished_at INTEGER, provider TEXT, is_summary_message INTEGER DEFAULT 0 NOT NULL, FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE);
CREATE TABLE read_files (session_id TEXT NOT NULL CHECK (session_id != ''), path TEXT NOT NULL CHECK (path != ''), read_at INTEGER NOT NULL, FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE, PRIMARY KEY (path, session_id));
CREATE TABLE mcp_disabled_servers (name TEXT PRIMARY KEY);

INSERT INTO sessions (id, parent_session_id, title, message_count, updated_at, created_at) VALUES
  ('7c1d0a2e-1111-4111-8111-111111111111', NULL, 'Add retry to the uploader', 2, 1795500600, 1795500000),
  ('title-7c1d0a2e-1111-4111-8111-111111111111', '7c1d0a2e-1111-4111-8111-111111111111', 'Generate a title', 1, 1795500010, 1795500005),
  ('toolu_01SyntheticTask', '7c1d0a2e-1111-4111-8111-111111111111', 'Explore the uploader', 1, 1795500300, 1795500200),
  ('7c1d0a2e-2222-4222-8222-222222222222', NULL, 'Rename the CLI flags', 1, 1795400000, 1795399000);
INSERT INTO messages (id, session_id, role, parts, created_at, updated_at) VALUES
  ('m1', '7c1d0a2e-1111-4111-8111-111111111111', 'user', '[{"type":"text","data":{"text":"Add retry with backoff to the uploader"}}]', 1795500000, 1795500000),
  ('m2', '7c1d0a2e-1111-4111-8111-111111111111', 'assistant', '[{"type":"reasoning","data":{"thinking":"synthetic"}},{"type":"text","data":{"text":"I will wrap the upload in a retry loop."}},{"type":"tool_call","data":{"id":"call_1","name":"edit","input":"{}","finished":true}}]', 1795500010, 1795500020),
  ('m3', 'title-7c1d0a2e-1111-4111-8111-111111111111', 'user', '[{"type":"text","data":{"text":"Generate a title"}}]', 1795500005, 1795500005),
  ('m4', 'toolu_01SyntheticTask', 'user', '[{"type":"text","data":{"text":"Find where uploads start"}}]', 1795500200, 1795500200),
  ('m5', '7c1d0a2e-2222-4222-8222-222222222222', 'user', '[{"type":"text","data":{"text":"Rename the CLI flags"}}]', 1795399000, 1795399000);
INSERT INTO files (id, session_id, path, content, version, created_at, updated_at) VALUES
  ('f1', '7c1d0a2e-1111-4111-8111-111111111111', '/Users/dev/code/orbit-api/upload.ts', 'synthetic file content', 0, 1795500020, 1795500020);
INSERT INTO mcp_disabled_servers VALUES ('synthetic');
