# Amazon Q Developer CLI fixture

Not installed on the development Mac. Read from `aws/amazon-q-developer-cli` at
`15cc8f3cd18c4272925ce1c7053268eedff1ea0a`; see docs/research/agent_storage_formats.md, Q9. Rows are synthetic.

- `sql/data.sql`: `conversations(key, value)` (`crates/chat-cli/src/database/sqlite_migrations/007_conversations_table.sql#L1-L4`)
  next to the sign-in tables `state` and `auth_kv` (`004_state_table.sql`, `005_auth_table.sql`). The test builds
  `~/Library/Application Support/amazon-q/data.sqlite3` (`crates/chat-cli/src/util/paths.rs#L327-L332`).
- `value` is a serialized `ConversationState` with `conversation_id` (`crates/chat-cli/src/cli/chat/conversation.rs#L107-L110`).
