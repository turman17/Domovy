# Goose fixture

Goose is not installed on the development Mac. Everything is read from `block/goose` at
`059fee25f13fa92be561a7d42cdd04ececef5a98`; see docs/research/agent_storage_formats.md, Q9. Rows are synthetic.

- `sql/sessions.sql`: the columns of `sessions` and `messages` Domovy reads, from
  `crates/goose/src/session/session_manager.rs#L1165-L1240` (schema 18, `#L32`). The test builds
  `sessions/sessions.db` under `~/.local/share/goose/` (XDG strategy, `crates/goose/src/config/paths.rs#L8-L38`).
- `goose session remove` asks for confirmation (`crates/goose-cli/src/cli.rs#L519-L559`), so Goose stays read-only.
