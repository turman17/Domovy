-- aws/amazon-q-developer-cli@15cc8f3c crates/chat-cli/src/database/sqlite_migrations/004-007. Rows are synthetic.
CREATE TABLE state (key TEXT PRIMARY KEY, value BLOB);
CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE conversations (key TEXT PRIMARY KEY, value TEXT);
INSERT INTO auth_kv VALUES ('codewhisperer:odic:token', 'synthetic-not-a-token');
INSERT INTO conversations VALUES ('/Users/dev/code/orbit-api', '{"conversation_id":"q1q1q1q1-1111-4111-8111-111111111111","history":[]}');
