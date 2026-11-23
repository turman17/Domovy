-- Synthetic subset of Codex 0.169 thread_history_1.sqlite.
CREATE TABLE thread_items (
    thread_id TEXT NOT NULL,
    turn_id TEXT NOT NULL,
    item_id TEXT NOT NULL,
    rollout_ordinal INTEGER NOT NULL,
    PRIMARY KEY (thread_id, turn_id, item_id)
);
INSERT INTO thread_items VALUES ('01a1f011-1111-7111-8111-111111111111', 't1', 'i1', 1);
INSERT INTO thread_items VALUES ('01a1f011-1111-7111-8111-111111111111', 't1', 'i2', 2);
INSERT INTO thread_items VALUES ('01a1f033-3333-7333-8333-333333333333', 't1', 'i1', 1);
