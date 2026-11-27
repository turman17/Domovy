# Crush fixture

Crush is not installed on the development Mac. Everything is read from `charmbracelet/crush` at
`ee51fe87bb306a945bf9057edf94f5574b192fd2`; see docs/research/agent_storage_formats.md, Q9. Rows are synthetic.

- `sql/crush.sql`: `sessions`, `messages`, `files`, `read_files` after all migrations
  (`internal/db/migrations/20250424200609_initial.sql#L4-L82` and later files). The child sessions are a
  title session `title-<id>` and a sub-agent task keyed by its tool call id (`internal/session/session.go#L119-L137`).
  Message parts are `[{type, data}]` (`internal/message/message.go#L626-L660`).
- `projects.json` `{projects: [{path, data_dir, last_accessed}]}` is written by the test with temp paths
  (`internal/projects/projects.go#L24-L34`).
- `stub-crush.sh` mimics `crush session delete <id> --data-dir <dir>` (`internal/cmd/session.go#L71-L78`,
  `#L293-L327`; `internal/cmd/root.go#L58-L66`), which leaves child sessions (`internal/session/session.go#L147-L178`).
