# Continue fixture

Continue is not installed on the development Mac. Everything is read from `continuedev/continue` at
`5522c6f44ca0ac3528b37244818fbfa39b5af470`; see docs/research/agent_storage_formats.md, Q9. Content is synthetic.

| Fixture file | Source |
| --- | --- |
| `~/.continue/sessions/<uuid>.json` `{sessionId, title, workspaceDirectory, history: [{message: {role, content}, contextItems}], mode, chatModelTitle}` | `core/util/paths.ts#L78-L104`, `core/index.d.ts#L279-L354`, `core/util/history.ts#L115-L134` |
| `sessions/sessions.json` `[{sessionId, title, dateCreated: "<ms>", workspaceDirectory, messageCount}]` | `core/index.d.ts#L292-L298`, `core/util/history.ts#L154-L171` |
| a session file the list does not name (Continue does not show it) | `core/util/history.ts#L33-L39`, `#L91-L109` |
| `config.yaml`, `.env`, `index/` (protected) | `core/util/paths.ts#L114-L125`, `#L326-L339`, `#L378` |

Delete mirrors `HistoryManager.delete` (`core/util/history.ts#L60-L85`): unlink the file, drop the list entry.
