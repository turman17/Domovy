# Cline fixture

Cline is not installed on the development Mac. Everything is read from `cline/cline` at
`34c104e6fc49781cda4adcd73ffdccd8f029fef9`; see docs/research/agent_storage_formats.md, Q9. Content is synthetic.
`3.0/data` is copied to `~/.cline/data` of a temp home; `sql/sessions.sql` becomes `db/sessions.db`.

| Fixture file | Source |
| --- | --- |
| `~/.cline/data`, `db/sessions.db`, `sessions/<id>/` | `sdk/packages/shared/src/storage/paths.ts#L158-L253` |
| `sessions` table columns, `status`, `pid`, `metadata_json.title` | `sdk/packages/shared/src/db/sqlite-db.ts#L188-L217`, `sdk/packages/shared/src/session/records.ts#L1-L22` |
| `<id>.json` manifest, `<id>.messages.json` `{messages: [{role, content}]}`, sub-agent messages in the root folder | `sdk/packages/core/src/services/session-artifacts.ts#L34-L94`, `sdk/packages/core/src/services/session-data.ts#L334-L359` |
| a `running` session whose pid (4242) runs counts as live | `sdk/packages/core/src/session/services/persistence-service.ts#L430-L512` |
| `settings/`, `secrets.json`, `globalState.json` (protected) | `paths.ts#L431-L453`, `apps/vscode/src/sdk/legacy-state-reader.ts#L33-L39` |
| `stub-cline.sh`: `cline history delete --session-id <id>` | `apps/cli/src/commands/history-command.ts#L63-L76`, `persistence-service.ts#L586-L645` |
