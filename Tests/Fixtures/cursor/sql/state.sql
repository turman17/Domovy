-- Synthetic Cursor global state.vscdb, shaped like the verified layout (2026-11-23): two
-- key-value tables, chats as composerData:/bubbleId:/checkpointId:/... rows, plus the 3.0+ chat
-- list composer.composerHeaders (reported shape). Every value is made up.
PRAGMA journal_mode = WAL;
CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);

INSERT INTO ItemTable VALUES ('workbench.panel.composerChatViewPane.0f0f0f0f-9999-4999-8999-999999999999.hidden', '[{"id":"workbench.panel.aichat.view","isHidden":false}]');
INSERT INTO ItemTable VALUES ('cursor/memoriesEnabled', 'false');
INSERT INTO ItemTable VALUES ('cursorAuth/cachedSignUpType', '"Auth_0"');
-- Odd spacing on purpose: a delete must leave the other entries byte for byte.
INSERT INTO ItemTable VALUES ('composer.composerHeaders', '{"allComposers":[{"composerId":"ca11ab1e-1111-4111-8111-111111111111","name":"Fix the flaky upload test","createdAt":1795100000000,"lastUpdatedAt":1795166100000,"unifiedMode":"agent","workspaceIdentifier":{"id":"9a8b7c6d","uri":{"fsPath":"/Users/dev/code/orbit-api","scheme":"file"}}},  {"composerId": "cafe0002-2222-4222-8222-222222222222", "createdAt": 1795000000000, "lastUpdatedAt": 1795050000000, "workspaceIdentifier": {"id": "1c2d3e4f", "uri": "file:///Users/dev/code/landing-site"}},{"composerId":"cab00003-3333-4333-8333-333333333333","name":"Explain the cache layer","createdAt":1794900000000,"lastUpdatedAt":1794950000000}],"selectedComposerId":"cafe0002-2222-4222-8222-222222222222"}');

-- Chat A: named, three messages and one of every per-chat kind of row.
INSERT INTO cursorDiskKV VALUES ('composerData:ca11ab1e-1111-4111-8111-111111111111', json_object('_v', 10, 'composerId', 'ca11ab1e-1111-4111-8111-111111111111', 'createdAt', 1795100000000, 'status', 'completed', 'subComposerIds', json_array(), 'fullConversationHeadersOnly', json_array(json_object('bubbleId', 'a0000001-0000-4000-8000-000000000001', 'type', 1), json_object('bubbleId', 'a0000002-0000-4000-8000-000000000002', 'type', 2), json_object('bubbleId', 'a0000003-0000-4000-8000-000000000003', 'type', 1))));
INSERT INTO cursorDiskKV VALUES ('bubbleId:ca11ab1e-1111-4111-8111-111111111111:a0000001-0000-4000-8000-000000000001', json_object('_v', 3, 'type', 1, 'bubbleId', 'a0000001-0000-4000-8000-000000000001', 'text', 'The upload test fails one run in ten. Find out why.', 'createdAt', '2026-11-18T09:15:00.000Z', 'padding', hex(randomblob(6000))));
INSERT INTO cursorDiskKV VALUES ('bubbleId:ca11ab1e-1111-4111-8111-111111111111:a0000002-0000-4000-8000-000000000002', json_object('_v', 3, 'type', 2, 'bubbleId', 'a0000002-0000-4000-8000-000000000002', 'text', 'The test races the retry timer. I will inject a clock.', 'createdAt', '2026-11-18T09:16:00.000Z', 'padding', hex(randomblob(6000))));
INSERT INTO cursorDiskKV VALUES ('bubbleId:ca11ab1e-1111-4111-8111-111111111111:a0000003-0000-4000-8000-000000000003', json_object('_v', 3, 'type', 1, 'bubbleId', 'a0000003-0000-4000-8000-000000000003', 'text', 'Good, do it.', 'createdAt', '2026-11-18T09:20:00.000Z', 'padding', hex(randomblob(6000))));
INSERT INTO cursorDiskKV VALUES ('checkpointId:ca11ab1e-1111-4111-8111-111111111111:a9000001-0000-4000-8000-000000000001', json_object('files', json_array(), 'nonExistentFiles', json_array(), 'padding', hex(randomblob(3000))));
INSERT INTO cursorDiskKV VALUES ('messageRequestContext:ca11ab1e-1111-4111-8111-111111111111:a0000001-0000-4000-8000-000000000001', json_object('gitStatusRaw', '', 'todos', json_array()));
INSERT INTO cursorDiskKV VALUES ('codeBlockDiff:ca11ab1e-1111-4111-8111-111111111111:a8000001-0000-4000-8000-000000000001', json_object('newModelDiffWrtV0', json_array()));
INSERT INTO cursorDiskKV VALUES ('agentKv:ca11ab1e-1111-4111-8111-111111111111:state', json_object('step', 3));

-- Chat B: no name, so the title is its first prompt; its workspace comes from the chat list.
INSERT INTO cursorDiskKV VALUES ('composerData:cafe0002-2222-4222-8222-222222222222', json_object('_v', 10, 'composerId', 'cafe0002-2222-4222-8222-222222222222', 'createdAt', 1795000000000, 'subComposerIds', json_array(), 'fullConversationHeadersOnly', json_array(json_object('bubbleId', 'b0000001-0000-4000-8000-000000000001', 'type', 1), json_object('bubbleId', 'b0000002-0000-4000-8000-000000000002', 'type', 2))));
INSERT INTO cursorDiskKV VALUES ('bubbleId:cafe0002-2222-4222-8222-222222222222:b0000001-0000-4000-8000-000000000001', json_object('_v', 3, 'type', 1, 'text', 'Make the hero image lazy load
and keep the layout stable.', 'createdAt', '2026-11-17T12:00:00.000Z'));
INSERT INTO cursorDiskKV VALUES ('bubbleId:cafe0002-2222-4222-8222-222222222222:b0000002-0000-4000-8000-000000000002', json_object('_v', 3, 'type', 2, 'text', 'Added loading="lazy" and fixed dimensions.', 'createdAt', '2026-11-17T12:01:00.000Z'));
INSERT INTO cursorDiskKV VALUES ('checkpointId:cafe0002-2222-4222-8222-222222222222:b9000001-0000-4000-8000-000000000001', json_object('files', json_array()));

-- Chat C: named in the chat list only, one message.
INSERT INTO cursorDiskKV VALUES ('composerData:cab00003-3333-4333-8333-333333333333', json_object('_v', 10, 'composerId', 'cab00003-3333-4333-8333-333333333333', 'createdAt', 1794900000000, 'subComposerIds', json_array(), 'fullConversationHeadersOnly', json_array(json_object('bubbleId', 'c0000001-0000-4000-8000-000000000001', 'type', 1))));
INSERT INTO cursorDiskKV VALUES ('bubbleId:cab00003-3333-4333-8333-333333333333:c0000001-0000-4000-8000-000000000001', json_object('_v', 3, 'type', 1, 'text', 'How does the cache layer evict?', 'createdAt', '2026-11-16T08:00:00.000Z'));

-- An empty draft (a new tab never used): not listed.
INSERT INTO cursorDiskKV VALUES ('composerData:cade0004-4444-4444-8444-444444444444', json_object('_v', 10, 'composerId', 'cade0004-4444-4444-8444-444444444444', 'createdAt', 1795200000000, 'subComposerIds', json_array(), 'fullConversationHeadersOnly', json_array()));

-- Shared rows that belong to no one chat.
INSERT INTO cursorDiskKV VALUES ('agentKv:blob:5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e', hex(randomblob(500)));
INSERT INTO cursorDiskKV VALUES ('composer.content.7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f', 'shared content blob');
INSERT INTO cursorDiskKV VALUES ('inlineDiffs-1', '[]');
