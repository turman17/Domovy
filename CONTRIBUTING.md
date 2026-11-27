# Contributing to Domovy

Thanks for your interest! Bug reports, agent reports and pull requests are all welcome.

## Reporting bugs

Open an issue. The most useful reports include:

- macOS version and Mac model (Apple Silicon or Intel)
- Domovy version (`domo --version`) and the agent and its version (`claude --version`, `codex --version`, ...)
- What happened vs. what you expected
- For a storage problem: folder and file **names and sizes only** (`ls -la`, `du -sh`)

**Never paste transcript content, prompts, titles or real paths you would not publish.** Transcripts often contain secrets. Domovy never needs their content to diagnose a layout problem.

### Experimental agents

Agents marked *Experimental* were built from the agent's docs and source code, not a real install. If you use one, a report saying "works on version X" or "goes read-only with this message" helps the most.

## Building from source

Requirements: macOS 14+, Xcode 16+, Swift 6.

```bash
swift test                       # DomovyCore tests
make run                         # Debug app against .devhome (a synthetic fake home)
make reset-devhome               # restore .devhome after trying deletes
bash scripts/build-and-sign.sh   # signed Release build in .local/DerivedData
```

The layout is described in the README's Architecture section. The short version:

- `Sources/DomovyCore/` — all logic, no UI imports. Most changes happen here.
- `App/` — the SwiftUI app, a thin shell over the core.
- `Sources/domo/` — the CLI, another thin shell.

## Rules for changes

These come from Domovy's safety rules and are not negotiable:

- **Tests never touch your real home directory.** Build a fake home from fixtures (`Tests/Fixtures/<agent>/<version>/`) with synthetic sessions and point adapters at it through the injected root URL.
- **Every adapter change needs a fixture test** covering list, artifacts, delete plan and archive plan.
- **Never run delete or archive against `~` during development**, including from the CLI. Use `--root <fixture-home>`.
- **Fixtures are synthetic.** Fake project names, fake titles, plausible sizes. Never real transcript content or real paths from your machine.
- **When researching a real install**, list names and sizes only; do not open transcript contents. Record what you verified, and against which version, in `docs/research/agent_storage_formats.md`.
- **Unknown layout or version: read-only.** An adapter that meets something it does not know goes read-only and says why. Never guess.
- **Every mutating action is a `Plan`**: compute the exact file and database changes first, show them, then execute the same object.
- **Prefer the agent's own command** over editing its files, and verify the result afterwards. Never write an app's database while the app runs; back it up first.
- **Never log transcript content.** Use `os.Logger` with `.private` for paths and content; no `print` in shipping code.
- No new dependencies without a reason in the PR (allowed: swift-argument-parser, the vendored zstd, system `libsqlite3`). No network, no telemetry.

## Pull requests

- Keep PRs focused — one fix, agent or feature per PR.
- Match the surrounding code: naming, comment density, file layout. Small types, value semantics, `async`/`await` for scans, typed user-explainable errors, no force unwraps outside tests.
- Commit messages follow Conventional Commits: `type(scope): summary` (types: feat, fix, refactor, chore, docs, test).
- Run `swift test` and `make app` before opening the PR.

## Licensing

Domovy is GPL-3.0. By contributing, you agree your contributions are licensed under the same terms.
