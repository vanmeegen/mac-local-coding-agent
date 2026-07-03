# AGENTS.md

Guidance for AI coding agents (and humans) working in this repo.

## What this is

A **local-only, $0** AI coding toolkit. Everything runs against Ollama on
`http://localhost:11434/v1`. No cloud providers, no API keys, nothing leaves the
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
- **Frontend (when applicable):** React + Tailwind CSS, deploy target GitHub Pages.
- **Files:** When emitting a file, output the **complete** file with its path on
  the code-fence info line, e.g. ` ```ts src/foo.ts `.

## Local model map

| Role        | Model              | When to use                                            |
| ----------- | ------------------ | ------------------------------------------------------ |
| Driver      | `qwen3.6-coder`    | Default. 27B dense @ 4-bit — best tool-calling reliability that fits 48 GB. |
| Fast gear   | `qwen3.6:35b-a3b-coding-mxfp8` | MoE (3B active), coding-tuned mxfp8. Faster decode for simple edits; less reliable tool-calling. |

There is **no dedicated small/utility model** — `qwen3.6:8b` does not exist
(Qwen 3.6 only shipped 27B + 35B-A3B). Pick the model per task: in the agent use
`/model dense|moe`, in OpenCode use `/models`.

Notes:
- Ollama 0.30+ is MLX-accelerated on Apple Silicon — fast and stable for long
  agentic sessions. (0.19 was the first MLX preview; 0.30+ has since hardened
  the MLX runner and picked up the M5 Neural Accelerator matmul kernel.)
- `num_ctx` must be raised (we set 65536 in the Modelfile). Ollama's 4K default
  silently breaks tool use.
- `tools: true` is required per-model in `opencode.json` or tools never fire.

## Security & git hygiene

- **Never commit secrets.** No `.env`, tokens, or keys (`.gitignore` covers
  `.env*`). This is a local-only setup; there should be nothing secret to commit
  in the first place — keep it that way.
- **Don't push without asking.** `git commit` and `git push` are set to `ask` in
  `opencode.json`. Confirm with the human before committing or pushing.
- `rm`, `curl`, `wget` prompt; `rm -rf` and `sudo` are denied.
