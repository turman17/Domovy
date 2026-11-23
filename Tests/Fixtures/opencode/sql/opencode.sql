-- Schema of opencode.db as verified on OpenCode 1.18.30 (names only; tables Domovy does not
-- read are left out), with synthetic rows. Times are milliseconds since 1970.
PRAGMA journal_mode = WAL;
CREATE TABLE `project` (`id` text PRIMARY KEY, `worktree` text NOT NULL, `vcs` text, `name` text, `icon_url` text, `icon_url_override` text, `icon_color` text, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `time_initialized` integer, `sandboxes` text NOT NULL, `commands` text);
CREATE TABLE `account` (`id` text PRIMARY KEY, `email` text NOT NULL, `url` text NOT NULL, `access_token` text NOT NULL, `refresh_token` text NOT NULL, `token_expiry` integer, `time_created` integer NOT NULL, `time_updated` integer NOT NULL);
CREATE TABLE `credential` (`id` text PRIMARY KEY, `integration_id` text, `label` text NOT NULL, `value` text NOT NULL, `connector_id` text, `method_id` text, `active` integer, `time_created` integer NOT NULL, `time_updated` integer NOT NULL);
CREATE TABLE `event_sequence` (`aggregate_id` text PRIMARY KEY, `seq` integer NOT NULL, `owner_id` text);
CREATE TABLE `event` (`id` text PRIMARY KEY, `aggregate_id` text NOT NULL, `seq` integer NOT NULL, `type` text NOT NULL, `data` text NOT NULL, CONSTRAINT `fk_event_aggregate_id_event_sequence_aggregate_id_fk` FOREIGN KEY (`aggregate_id`) REFERENCES `event_sequence`(`aggregate_id`) ON DELETE CASCADE);
CREATE TABLE `session` (`id` text PRIMARY KEY, `project_id` text NOT NULL, `workspace_id` text, `parent_id` text, `slug` text NOT NULL, `directory` text NOT NULL, `path` text, `title` text NOT NULL, `version` text NOT NULL, `share_url` text, `summary_additions` integer, `summary_deletions` integer, `summary_files` integer, `summary_diffs` text, `metadata` text, `cost` real DEFAULT 0 NOT NULL, `tokens_input` integer DEFAULT 0 NOT NULL, `tokens_output` integer DEFAULT 0 NOT NULL, `tokens_reasoning` integer DEFAULT 0 NOT NULL, `tokens_cache_read` integer DEFAULT 0 NOT NULL, `tokens_cache_write` integer DEFAULT 0 NOT NULL, `revert` text, `permission` text, `agent` text, `model` text, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `time_compacting` integer, `time_archived` integer, CONSTRAINT `fk_session_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE);
CREATE TABLE `message` (`id` text PRIMARY KEY, `session_id` text NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL, CONSTRAINT `fk_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE);
CREATE TABLE `part` (`id` text PRIMARY KEY, `message_id` text NOT NULL, `session_id` text NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL, CONSTRAINT `fk_part_message_id_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `message`(`id`) ON DELETE CASCADE);
CREATE UNIQUE INDEX `event_aggregate_seq_idx` ON `event` (`aggregate_id`,`seq`);
CREATE INDEX `event_aggregate_type_seq_idx` ON `event` (`aggregate_id`,`type`,`seq`);
CREATE INDEX `message_session_time_created_id_idx` ON `message` (`session_id`,`time_created`,`id`);
CREATE INDEX `part_message_id_id_idx` ON `part` (`message_id`,`id`);
CREATE INDEX `part_session_idx` ON `part` (`session_id`);
CREATE INDEX `session_project_idx` ON `session` (`project_id`);
CREATE INDEX `session_parent_idx` ON `session` (`parent_id`);

INSERT INTO project VALUES ('prj_orbit', '/Users/dev/code/orbit-api', 'git', 'orbit-api', NULL, NULL, NULL, 1794993300000, 1795166100000, 1794993300000, '[]', NULL);
INSERT INTO project VALUES ('prj_landing', '/Users/dev/code/landing-site', 'git', 'landing-site', NULL, NULL, NULL, 1793351100000, 1795252500000, 1793351100000, '[]', NULL);
INSERT INTO account VALUES ('acc_1', 'dev@example.invalid', 'https://example.invalid', 'synthetic-access', 'synthetic-refresh', NULL, 1793351100000, 1793351100000);

-- The idle session, with one subagent session.
INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated) VALUES
  ('ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 'prj_orbit', NULL, 'retry-uploader', '/Users/dev/code/orbit-api', 'Add retry to the uploader', '1.18.30', 1794993300000, 1795166100000),
  ('ses_5a1b2c3d5ffeHk3Jm8Pq2Ws6Yz', 'prj_orbit', 'ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 'explore-uploader', '/Users/dev/code/orbit-api', 'Explore the uploader (@explore subagent)', '1.18.30', 1794994000000, 1794994600000),
  ('ses_5a1b2c3e1ffeRt8Yu2Io4Pa6Sd', 'prj_landing', NULL, 'hero-copy', '/Users/dev/code/landing-site', 'Tighten the hero copy', '1.18.30', 1795252500000, 1795252800000);
INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived) VALUES
  ('ses_4f0e9d8c7ffeBn5Cv1Xz7Lk3Gh', 'prj_landing', NULL, 'old-footer', '/Users/dev/code/landing-site', 'Old footer layout', '1.18.30', 1793351100000, 1793351400000, 1793436000000);

INSERT INTO message VALUES
  ('msg_a1', 'ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 1794993300000, 1794993300000, '{"role":"user","time":{"created":1794993300000},"agent":"build"}'),
  ('msg_a2', 'ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 1794993310000, 1794993320000, '{"role":"assistant","time":{"created":1794993310000},"modelID":"synthetic","providerID":"synthetic"}'),
  ('msg_c1', 'ses_5a1b2c3d5ffeHk3Jm8Pq2Ws6Yz', 1794994000000, 1794994000000, '{"role":"user","time":{"created":1794994000000}}'),
  ('msg_l1', 'ses_5a1b2c3e1ffeRt8Yu2Io4Pa6Sd', 1795252500000, 1795252500000, '{"role":"user","time":{"created":1795252500000}}'),
  ('msg_o1', 'ses_4f0e9d8c7ffeBn5Cv1Xz7Lk3Gh', 1793351100000, 1793351100000, '{"role":"user","time":{"created":1793351100000}}');
INSERT INTO part VALUES
  ('prt_a1', 'msg_a1', 'ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 1794993300000, 1794993300000, '{"type":"text","text":"Add retry with backoff to the uploader"}'),
  ('prt_a2', 'msg_a2', 'ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 1794993310000, 1794993310000, '{"type":"step-start"}'),
  ('prt_a3', 'msg_a2', 'ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 1794993311000, 1794993311000, '{"type":"text","text":"I will wrap the upload call in a retry loop."}'),
  ('prt_a4', 'msg_a2', 'ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 1794993312000, 1794993312000, '{"type":"tool","tool":"edit","callID":"call_1","state":{"status":"completed"}}'),
  ('prt_c1', 'msg_c1', 'ses_5a1b2c3d5ffeHk3Jm8Pq2Ws6Yz', 1794994000000, 1794994000000, '{"type":"text","text":"Find where uploads start"}'),
  ('prt_l1', 'msg_l1', 'ses_5a1b2c3e1ffeRt8Yu2Io4Pa6Sd', 1795252500000, 1795252500000, '{"type":"text","text":"Make the hero copy shorter"}'),
  ('prt_o1', 'msg_o1', 'ses_4f0e9d8c7ffeBn5Cv1Xz7Lk3Gh', 1793351100000, 1793351100000, '{"type":"text","text":"Rework the footer"}');
INSERT INTO event_sequence VALUES
  ('ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 3, NULL), ('ses_5a1b2c3d5ffeHk3Jm8Pq2Ws6Yz', 1, NULL),
  ('ses_5a1b2c3e1ffeRt8Yu2Io4Pa6Sd', 1, NULL), ('ses_4f0e9d8c7ffeBn5Cv1Xz7Lk3Gh', 1, NULL);
INSERT INTO event VALUES
  ('evt_a1', 'ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 1, 'session.created.1', '{"synthetic":"session created event payload"}'),
  ('evt_a2', 'ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 2, 'message.updated.1', '{"synthetic":"message updated event payload with a longer body to weigh more"}'),
  ('evt_a3', 'ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw', 3, 'message.part.updated.1', '{"synthetic":"part updated event payload"}'),
  ('evt_c1', 'ses_5a1b2c3d5ffeHk3Jm8Pq2Ws6Yz', 1, 'session.created.1', '{"synthetic":"child session created"}'),
  ('evt_l1', 'ses_5a1b2c3e1ffeRt8Yu2Io4Pa6Sd', 1, 'session.created.1', '{"synthetic":"landing session created"}'),
  ('evt_o1', 'ses_4f0e9d8c7ffeBn5Cv1Xz7Lk3Gh', 1, 'session.created.1', '{"synthetic":"old session created"}');
