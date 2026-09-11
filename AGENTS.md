# AGENTS.md

Guidance for AI coding agents (and humans) working in this repo.

## What this is

A **local-only, $0** AI coding toolkit. Everything runs against oMLX on
`http://localhost:8000/v1` (OpenAI-compatible) / `http://localhost:8000/v1/messages`
(Anthropic-compatible). No cloud providers, no API keys, nothing leaves the
machine. Keep it that way.

## Stack & conventions

- **Runtime:** Bun (not Node). Use `Bun.file`, `Bun.write`, `Bun.spawn`, and
  Bun's native `fetch` rather than reaching for libraries.
- **Language:** TypeScript, strict mode. No `any`, no implicit `any`, no
  unchecked index access. Prefer `readonly` and explicit return types.
- **Style:** Functional and dependency-free. Do **not** add runtime dependencies
  unless explicitly asked — this project ships with none.
- **Errors:** Handle them explicitly. Surface failures with clear messages;
  don't swallow exceptions silently.
- **Shell:** `setup.sh` and `bench.sh` must stay `bash -n` clean, idempotent,
  and must never require `sudo` (print the command instead).
- **Frontend (when applicable):** React + Tailwind CSS, deploy target GitHub Pages.
- **Files:** When emitting a file, output the **complete** file with its path on
  the code-fence info line, e.g. ` ```ts src/foo.ts `.

## Local model map

| Key (`/model`) | oMLX model id | When to use |
| --- | --- | --- |
| `fast` | `Qwen3.8-27B-oQ4e-mtp` | Default driver. 27B dense, oQ4 + Lightning MTP — best tool-calling that fits 48 GB. |
| `quality` | `Qwen3.8-27B-oQ6e-mtp` | Same model, near-lossless, ~10 % slower. Hard refactors. (`INSTALL_QUALITY=1`) |
| `moe` | `Qwen3.6-35B-A3B-oQ4e-mtp` | MoE, 3B active + MTP. 2–3x decode speed, weaker tools. Simple edits. (`INSTALL_MOE=1`) |

Notes:
- Server = **oMLX 0.6.4+** (brew tap `jundot/omlx`). Lightning MTP, the
  RAM+SSD prefix cache and Qwen-recommended sampling are configured per model in
  `~/.omlx/model_settings.json` by `setup.sh`; the admin UI is at `/admin`.
- **Do not lower the temperature** for "reliability": Qwen 3.8's tool calls are
  stable at the model-card defaults (1.0 / 0.95 / top_k 20) and MTP acceptance
  drops at low temperature.
- Ollama is a **fallback only** (`INSTALL_OLLAMA_FALLBACK=1`): since 0.32 it
  re-prefills the whole prompt on every request for Qwen's hybrid attention.
- `tools: true` is required per-model in `opencode.json` or tools never fire.

## Security & git hygiene

- **Never commit secrets.** No `.env`, tokens, or keys (`.gitignore` covers
  `.env*`). This is a local-only setup; there should be nothing secret to commit
  in the first place — keep it that way.
- **Don't push without asking.** `git commit` and `git push` are set to `ask` in
  `opencode.json`. Confirm with the human before committing or pushing.
- `rm`, `curl`, `wget` prompt; `rm -rf` and `sudo` are denied.
