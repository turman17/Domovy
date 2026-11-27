-- Zed 1.29 threads/threads.db, schema as verified on a real install. Synthetic rows only.
CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    summary TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    data_type TEXT NOT NULL,
    data BLOB NOT NULL
, parent_id TEXT, folder_paths TEXT, folder_paths_order TEXT, created_at TEXT);
CREATE INDEX threads_list_metadata ON threads (
    updated_at, created_at, id, parent_id, folder_paths, folder_paths_order, summary
);
-- A native thread stored as plain JSON (older rows), with a subagent thread.
INSERT INTO threads VALUES ('2ed00001-1111-4111-8111-111111111111', 'Fix the flaky upload test', '2026-11-12T21:53:12.250000+00:00', 'json',
  CAST('{"title":"Fix the flaky upload test","messages":[{"User":{"id":"m1","content":[{"Text":"The upload test fails one run in ten. Find out why."}]}},{"Agent":{"content":[{"Text":"Looking at the retry loop first."},{"ToolUse":{"id":"t1","name":"read_file","input":{}}}]}},{"Agent":{"content":[{"Text":"The timeout races the retry; fixed in upload.rs."}]}}],"version":"0.3.0"}' AS BLOB),
  NULL, '/Users/dev/code/orbit-api', '0', '2026-11-12T20:10:00.000000+00:00');
INSERT INTO threads VALUES ('2ed00003-3333-4333-8333-333333333333', 'Read the upload module', '2026-11-12T21:00:00.000000+00:00', 'zstd',
  zeroblob(2048), '2ed00001-1111-4111-8111-111111111111', '/Users/dev/code/orbit-api', '0', '2026-11-12T20:30:00.000000+00:00');
-- A zstd-compressed thread (the usual case): real zstd (level 3) of a synthetic thread JSON.
-- The zeroblob rows are not valid zstd and stand for damaged data.
INSERT INTO threads VALUES ('2ed00002-2222-4222-8222-222222222222', 'Make the hero image lazy load', '2026-11-20T09:15:00.500000+00:00', 'zstd',
  X'28b52ffd64a0001508008610352420abb60df0f34c6834d451b1fe5837926684dc9388091e9212b7b7cd274ea6008400c40128002b002900677b693da24f716961fd2994efe9e3cb5972c3ca433654281f8b1cd108356ad4864cf8bab6debe14cd968289cc257ef14501e496b1c4d6001024c8e0d2324d8c0982905be6b2396e077dda693b66f8f246f2158c3a3e98ae6d1d8d5ea65fd747ba4bebfa148df939d38e8d1eb6842bd9902d4f12b9b12368350a8802d31523c0a8af3bde17d1c9972b289560945a896611a8473988a6410c38cac906d34e06917c613095b68fc2eec10f001b1ba96a473d6b7763ed9859d96461e47ac696942da8312162414513c249439e33045c854a501094192dcffba7', NULL, '/Users/dev/code/landing-site', '0', '2026-11-20T09:00:00.000000+00:00');
-- A thread the sidebar does not list (written before the sidebar backfill).
INSERT INTO threads VALUES ('2ed00004-4444-4444-8444-444444444444', 'Rename the CLI flags', '2026-10-01T08:00:00.000000+00:00', 'zstd',
  zeroblob(4000), NULL, '/Users/dev/code/ledger', '0', '2026-10-01T07:50:00.000000+00:00');
