-- Synthetic subset of Codex 0.169 state_5.sqlite (column names from a real schema; no real data).
CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    rollout_path TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    source TEXT NOT NULL,
    cwd TEXT NOT NULL,
    title TEXT NOT NULL,
    archived INTEGER NOT NULL DEFAULT 0,
    archived_at INTEGER
);
CREATE TABLE thread_spawn_edges (
    parent_thread_id TEXT NOT NULL,
    child_thread_id TEXT NOT NULL PRIMARY KEY,
    status TEXT NOT NULL
);
CREATE TABLE thread_attachments (
    id TEXT PRIMARY KEY,
    thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    attachment_type TEXT NOT NULL,
    identity_key TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
INSERT INTO threads VALUES ('01a1f011-1111-7111-8111-111111111111', 'sessions/2026/11/20/rollout-2026-11-20T09-15-00-01a1f011-1111-7111-8111-111111111111.jsonl', 1795166100, 1795174860, 'cli', '/Users/dev/code/orbit-api', 'Add retries to the orbit API client', 0, NULL);
INSERT INTO threads VALUES ('01a1f033-3333-7333-8333-333333333333', 'sessions/2026/10/30/rollout-2026-10-30T14-05-00-01a1f033-3333-7333-8333-333333333333.jsonl.zst', 1793455500, 1793459100, 'cli', '/Users/dev/code/ledger', 'Migrate cron jobs to the queue', 0, NULL);
INSERT INTO threads VALUES ('01a1f044-4444-7444-8444-444444444444', 'archived_sessions/rollout-2026-11-15T22-41-43-01a1f044-4444-7444-8444-444444444444.jsonl', 1794785503, 1794785700, 'cli', '/Users/dev/code/orbit-api', 'Draft release notes for 2.4', 1, 1794790000);
INSERT INTO thread_spawn_edges VALUES ('01a1f011-1111-7111-8111-111111111111', '01a1f0bb-bbbb-7bbb-8bbb-bbbbbbbbbbbb', 'completed');
INSERT INTO thread_attachments VALUES ('att-1', '01a1f011-1111-7111-8111-111111111111', 'browser_preview', 'http://localhost:3000', '{}', 1795166200);
