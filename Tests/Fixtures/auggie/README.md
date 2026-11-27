# Auggie fixture

Auggie (Augment CLI) is not installed on the development Mac. The layout is read from the shipped npm
bundle `@augmentcode/auggie@1.2.2` (`auggie-v2.mjs`, build `6f24c7b3c15045713c7b3938b5e6c9bf117d1ff6`,
2026-11-17); see docs/research/agent_storage_formats.md, Q9. Auggie is a fork of pi's coding agent; the
bundle is minified, so sources are named by function. All content is synthetic.

| Fixture file | Source in the bundle |
| --- | --- |
| `~/.augment` root, `AUGMENT_CACHE_DIR` / `AUGGIE_CODING_AGENT_DIR` overrides | `rI`, `Rr` |
| `sessions-v2/--<cwd, leading slash dropped, / \\ : as ->--/` | `Bb`, constant `ele="sessions-v2"` |
| `<id>.jsonl`, header `{type: session, version: 3, id, timestamp, cwd}` | `newSession`, `HB=3`, `ade`, `HZs` |
| `message` records `{message: {role, content}}`, `toolCall` parts, `session_info` names | `xcr`, `getSessionName` |
| `<id>.files/` (pasted images), removed by Auggie's own delete after `trash <file>` | `pasteClipboardImage`, `ava`, `lva` |
| `settings.json`, `session.json` (sign-in), legacy `sessions/` (protected / measured only) | `ykn`, CLI help `auth login` |

The assistant text of the first session is padded so the transcript is large enough to compress.
