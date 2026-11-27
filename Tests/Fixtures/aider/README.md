# Aider fixture

Aider is not installed on the development Mac. The layout is read from `Aider-AI/aider` at
`5dc9490bb35f9729ef2c95d00a19ccd30c26339c`; see docs/research/agent_storage_formats.md, Q9. All content is synthetic.

| Fixture file | Source |
| --- | --- |
| `<repo>/.aider.chat.history.md`, `<repo>/.aider.input.history` (git root, else cwd) | `aider/args.py#L270-L288` |
| `# aider chat started at <time>` per run, `#### ` prompts, `> ` tool output | `aider/io.py#L336`, `#L779-L789`, `#L1117-L1135` |
| input history in prompt_toolkit `FileHistory` format | `aider/io.py` (`FileHistory`) |
| `<repo>/.aider.tags.cache.v4/` (rebuildable diskcache) | `aider/repomap.py#L35-L43` |
| `~/.aider/oauth-keys.env` (credential, protected), `analytics.json` | `aider/main.py#L370`, `aider/onboarding.py#L361-L365`, `aider/analytics.py#L139` |

`code/orbit-api` is found through a project path another agent knows; `projects/landing-site` through a
search folder. The test adds `code/orbit-api/.git/` at run time (git does not store a `.git` folder). The reply is padded so the history is large enough to compress.
