# mac-local-coding-agent

A **fully local, private, $0** AI coding setup for an Apple Silicon Mac. No cloud
providers, no API keys, nothing leaves the machine.

It gives you three things:

1. **`src/local-llm.ts`** — a dependency-free TypeScript client for a local,
   OpenAI-compatible LLM server (Ollama), using only Bun's native `fetch`.
2. **`src/agent.ts`** — a minimal terminal coding agent (REPL) built on that client.
3. **`opencode.json`** — a ready-to-use [OpenCode](https://opencode.ai) config
   wired to your local Ollama, with one provider and no cloud block.

Everything talks to Ollama's OpenAI-compatible endpoint at
`http://localhost:11434/v1`.

## One-shot install

On a fresh Mac (Apple Silicon), clone and run the bootstrap script. It installs
Homebrew (if needed), Bun, Ollama 0.19+, pulls the models, builds the agent
model, installs OpenCode, and copies the config into place:

```sh
git clone https://github.com/vanmeegen/mac-local-coding-agent
cd mac-local-coding-agent
./setup.sh
```

`setup.sh` is **idempotent** — re-running it skips anything already installed.

Heads-up on downloads: the driver model (27B dense @ 4-bit) is **~16 GB**, and
the optional MoE adds more. Toggle the optional parts with env vars:

```sh
INSTALL_MOE=0 INSTALL_OPENCODE=0 ./setup.sh   # driver model only
```

Prefer to install by hand? `setup.sh` is short and readable — it documents every
step it automates (Homebrew → Bun → Ollama → `ollama create qwen3.6-coder` →
OpenCode).

## Quickstart

**Terminal agent:**

```sh
bun src/agent.ts                 # start the REPL
bun src/agent.ts src/foo.ts      # preload files into context
```

Inside the REPL: `@path` inlines a file, `/run <cmd>` feeds command output back
to the model, `/write <path>` saves the last code block, `/model dense|moe`
switches models, `/help` lists everything.

**OpenCode:**

```sh
cp opencode.json ~/.config/opencode/   # setup.sh already does this
opencode
```

Restart OpenCode after editing `opencode.json` — config changes are read at
startup.

## The models

| Role      | Model             | Notes                                                       |
| --------- | ----------------- | ----------------------------------------------------------- |
| Driver    | `qwen3.6-coder`   | **Default.** 27B dense @ 4-bit (~16 GB). Built from the Unsloth MTP GGUF (adds the `developer` role OpenCode needs + MTP speculative decoding). Best tool-calling reliability that fits 48 GB. |
| Fast gear | `qwen3.6:35b-a3b` | MoE, 3B active. Faster decode for simple edits, but less reliable tool-calling — switch to it only when you want speed over reliability. |

There is no dedicated small/utility model: **`qwen3.6:8b` does not exist** (the
3.6 series only shipped 27B + 35B-A3B), so OpenCode just reuses the main model
and you pick per task.

## Gotchas

- **`tools: true` is required.** Each model in `opencode.json` must set it or
  tools never fire.
- **Raise `num_ctx` or tool use silently breaks.** Ollama defaults to 4096,
  which truncates the system prompt + tool schemas with no error. The Modelfile
  sets `65536`.
- **Dense 27B is the reliable default; MoE is the fast gear.** Reach for the MoE
  only when tool calls are simple and you want throughput.
- **Ollama 0.19+ is MLX-accelerated on M5.** It uses the MLX backend and the GPU
  Neural Accelerators — fast *and* stable for long agentic sessions.

## Optional: max-throughput upgrade

If you ever want more raw throughput than Ollama gives, `vllm-mlx` is an optional
upgrade path — same local-only, OpenAI-compatible idea, higher ceiling.

## License

See [LICENSE](./LICENSE).
