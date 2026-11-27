# Kilo Code fixture

Kilo Code is not installed on the development Mac. Everything here comes from reading
`Kilo-Org/kilocode` at `bfdec5496922452222223c01b4cc6c89305b0279` (docs/research/agent_storage_formats.md, Q9):

- Data folder `~/.local/share/kilo` (XDG, `packages/core/src/global.ts#L12-L37`), database
  `kilo.db` with `-wal`/`-shm` (`packages/core/src/database/database.ts#L50-L67`,
  `packages/core/src/kilocode/db-preflight.ts#L36`), `auth.json` in the data folder
  (`packages/core/src/credential.ts#L165`).
- Tables `session`, `message`, `part`, `event`, `event_sequence` have OpenCode's columns
  (`packages/core/src/session/sql.ts#L24-L114`, `packages/core/src/event/sql.ts#L4-L25`), so the
  tests build `kilo.db` from `../opencode/sql/opencode.sql` and copy `../opencode/1.18/share/opencode`.
- `stub-kilo.sh` mimics `kilo session delete <id>`
  (`packages/opencode/src/cli/cmd/session.ts#L50-L71`), which deletes child sessions too
  (`packages/opencode/src/session/session.ts#L723-L726`).
