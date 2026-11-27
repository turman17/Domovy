-- Zed 1.29 db/0-stable/db.sqlite: the tables Domovy reads, as verified, plus two of the
-- workspace tables it must never touch. Synthetic rows only.
CREATE TABLE workspaces (workspace_id INTEGER PRIMARY KEY, paths TEXT, timestamp TEXT);
CREATE TABLE kv_store (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE "sidebar_threads" (
  thread_id BLOB PRIMARY KEY,
  session_id TEXT,
  agent_id TEXT,
  title TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  created_at TEXT,
  folder_paths TEXT,
  folder_paths_order TEXT,
  archived INTEGER DEFAULT 0,
  main_worktree_paths TEXT,
  main_worktree_paths_order TEXT,
  remote_connection TEXT
, interacted_at TEXT, title_override TEXT) STRICT;
CREATE TABLE archived_git_worktrees (
  id INTEGER PRIMARY KEY,
  worktree_path TEXT NOT NULL,
  main_repo_path TEXT NOT NULL,
  branch_name TEXT,
  staged_commit_hash TEXT,
  unstaged_commit_hash TEXT,
  original_commit_hash TEXT
) STRICT;
CREATE TABLE "thread_archived_worktrees" (
  thread_id BLOB NOT NULL,
  archived_worktree_id INTEGER NOT NULL REFERENCES archived_git_worktrees (id),
  PRIMARY KEY (thread_id, archived_worktree_id)
) STRICT;
INSERT INTO workspaces VALUES (1, '/Users/dev/code/orbit-api', '2026-11-12 21:00:00');
INSERT INTO kv_store VALUES ('agent_panel', '{"width":420}');
INSERT INTO sidebar_threads VALUES (X'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', '2ed00001-1111-4111-8111-111111111111', NULL, 'Fix the flaky upload test',
  '2026-11-12T21:53:12.250000+00:00', '2026-11-12T20:10:00.000000+00:00', '/Users/dev/code/orbit-api', '0', 0, '/Users/dev/code/orbit-api', '0', NULL, '2026-11-12T21:53:12.250000+00:00', NULL);
INSERT INTO sidebar_threads VALUES (X'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2', '2ed00002-2222-4222-8222-222222222222', NULL, 'Lazy load hero',
  '2026-11-20T09:15:00.500000+00:00', '2026-11-20T09:00:00.000000+00:00', '/Users/dev/code/landing-site', '0', 1, NULL, NULL, NULL, NULL, 'Make the hero image lazy load');
-- Started from Zed with codex-acp: a Codex thread, listed under Codex, not here.
INSERT INTO sidebar_threads VALUES (X'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3', '01a1f011-1111-7111-8111-111111111111', 'codex-acp', 'Add retries to the orbit API client',
  '2026-11-20T09:15:00.000000+00:00', NULL, '/Users/dev/code/orbit-api', '0', 0, NULL, NULL, NULL, NULL, NULL);
-- A draft nothing was sent from: no session.
INSERT INTO sidebar_threads VALUES (X'd4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4', NULL, NULL, '', '2026-11-21T10:00:00.000000+00:00', NULL, '/Users/dev/code/orbit-api', '0', 0, NULL, NULL, NULL, NULL, NULL);
INSERT INTO archived_git_worktrees VALUES (1, '/Users/dev/code/orbit-api-wt1', '/Users/dev/code/orbit-api', 'zed/upload-fix', 'aaa111', 'bbb222', 'ccc333');
INSERT INTO archived_git_worktrees VALUES (2, '/Users/dev/code/shared-wt', '/Users/dev/code/orbit-api', 'zed/shared', NULL, NULL, 'ddd444');
INSERT INTO thread_archived_worktrees VALUES (X'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', 1);
INSERT INTO thread_archived_worktrees VALUES (X'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', 2);
INSERT INTO thread_archived_worktrees VALUES (X'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2', 2);
