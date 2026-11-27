# Grok CLI fixture

The community Grok CLI (`grok-dev`) is not installed on the development Mac. Everything is read from
`superagent-ai/grok-cli` at `fb97af83f06dca873281d60168430f06c8de6324`; see docs/research/agent_storage_formats.md, Q9.
Rows are synthetic.

- `sql/grok.sql`: every table of `src/storage/migrations.ts#L28-L134` at `user_version` 3 (`#L3-L26`); the test
  builds `~/.grok/grok.db` from it. Session `status` is `active|archived` (`src/types/index.ts#L245`).
- `message_json` holds an AI SDK `ModelMessage` (`src/storage/transcript.ts#L1-L50`).
- `wallet.json` and `user-settings.json` are written by the test as protected files (`src/wallet/manager.ts`).
