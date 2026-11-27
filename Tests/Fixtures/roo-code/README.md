# Roo Code fixture

Roo Code is not installed on the development Mac. The layout is read from `RooCodeInc/Roo-Code` at
`b867ec9145750d0ae1ff7f02d35406e9bf2a0b16`; see docs/research/agent_storage_formats.md, Q9. All content is
synthetic. `3.x/Code` is copied to `~/Library/Application Support/Code` of a temp home.

| Fixture file | Source |
| --- | --- |
| `globalStorage/rooveterinaryinc.roo-cline/` | `src/package.json#L2-L5`, `src/utils/storage.ts#L14-L58` |
| `tasks/<uuid v7>/` with `api_conversation_history.json`, `ui_messages.json`, `task_metadata.json`, `history_item.json` | `src/shared/globalFileNames.ts#L1-L9`, `src/core/task/Task.ts#L454` |
| `history_item.json` fields (`id, number, ts, task, workspace, parentTaskId, childIds, …`) | `packages/types/src/history.ts#L7-L29`, `src/core/task-persistence/TaskHistoryStore.ts#L160-L185` |
| `tasks/_index.json` `{version: 1, updatedAt, entries}` (a cache, never edited) | `TaskHistoryStore.ts#L14-L18`, `#L244-L290`, `#L390-L421` |
| `tasks/<id>/checkpoints/` (per-task git repo) | `src/services/checkpoints/RepoPerTaskCheckpointService.ts#L10` |
| `ui_messages.json` `[{ts, type: say/ask, say, text}]` | `packages/types/src/message.ts#L144-L275`, `Task.ts#L1908`, `#L2029` |
| a folder without `history_item.json` (skipped, as Roo's reconcile does) | `TaskHistoryStore.ts#L244-L290` |
| `settings/mcp_settings.json`, `settings/custom_modes.yaml` (protected) | `src/shared/globalFileNames.ts#L1-L9`, `src/services/mcp/McpHub.ts#L487-L507` |

Delete with child tasks mirrors `deleteTaskWithId` (`src/core/webview/ClineProvider.ts#L1736-L1821`).
