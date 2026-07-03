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
Homebrew (if needed), Bun, Ollama 0.30+, pulls the models, builds the agent
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
| Fast gear | `qwen3.6:35b-a3b-coding-mxfp8` | MoE, 3B active, coding-tuned mxfp8 quant (37 GB). Faster decode than the dense driver (~61 tok/s vs ~15 tok/s measured on M5 Pro 48 GB) with noticeably better code quality than the plain `q4_K_M`-class default tag — still less reliable tool-calling than dense, so switch to it only when you want speed over reliability. |

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
- **Ollama 0.30+ is MLX-accelerated on M5.** It uses the MLX backend and the GPU
  Neural Accelerators — fast *and* stable for long agentic sessions. 0.19 was
  just the first MLX preview (March 2026); 0.30+ has since hardened the MLX
  runner and picked up the M5 matmul kernel, so keep Ollama current
  (`brew upgrade ollama`).

## Why Ollama over a "raw" MLX server

Several MLX-native servers now exist (**oMLX**, **Rapid-MLX**, **vllm-mlx**), and
it's worth asking whether one beats Ollama's own MLX backend. As of mid-2026,
no — stick with Ollama:

- **Bare `mlx_lm.server` currently can't tool-call with stock Qwen3.5/3.6.** Its
  parser only recognizes the `Coder`-flavored chat template; the plain
  27B/35B-A3B templates aren't auto-detected (open upstream bug,
  [ml-explore/mlx-lm#1293](https://github.com/ml-explore/mlx-lm/issues/1293)).
  This is exactly why the Modelfile pins the Unsloth **MTP/Coder** GGUF — it
  emits explicit `<tool_call>` markers and sidesteps the bug entirely.
- **oMLX** is a nice menu-bar wrapper (SSD-tiered KV cache cutting long-session
  TTFT from 30-90s to 1-3s, a big model catalog browsable in-app, OpenAI +
  Anthropic endpoints). It does *not* fully inherit bare mlx-lm's non-Coder
  tool-calling gap — its engine auto-selects a `qwen3_coder`-style parser for
  plain Qwen3.5/3.6 checkpoints too (see the startup log in
  [jundot/omlx#906](https://github.com/jundot/omlx/issues/906)), so it can
  tool-call against the plain Unsloth MLX quant without needing the
  Coder-flavored build. The `developer`-role issue this repo previously hit —
  [jundot/omlx#1966](https://github.com/jundot/omlx/issues/1966), "Qwen3.6
  false-positive mid-system preservation with leading developer block" (same
  root cause as [#1908](https://github.com/jundot/omlx/issues/1908) and
  [#1923](https://github.com/jundot/omlx/issues/1923): oMLX's
  `/v1/responses` adapter merges leading `system`/`developer` messages in a
  way that violates Qwen3.6's strict "system message only at position 0"
  chat template) — **has a confirmed one-line fix**: set
  `server.preserve_mid_system_cache: false` in `~/.omlx/settings.json` and
  restart oMLX. That said, oMLX's issue tracker (655 open, vs. Ollama's 2,434
  on a much larger project) still has other open tool-calling reliability
  issues unrelated to this fix — silently dropped tool calls, parser
  mismatches on non-standard formats, scheduler crashes under load, and a
  report of Qwen3.6-35B failing under one of oMLX's batched-execution engines
  while working under another. No published Ollama-comparison numbers either.
  Worth trialling on a second port (default 8000) for its TTFT win on long
  sessions with the fix applied, but not a replacement for the Ollama driver
  model yet.
- **vllm-mlx**'s big win is continuous batching for many concurrent requests —
  irrelevant for one person driving one agent session locally.
- **Rapid-MLX** is the most credible throughput claim (its own benchmarks show
  ~2.4x over Ollama on Qwen3.5-27B, with a Hermes tool parser and malformed-
  output recovery) — but that comparison number predates Ollama's current MLX
  backend, so it's likely overstated today. If you want to chase more
  throughput, benchmark Rapid-MLX yourself against current Ollama (same model,
  same quant, same prompts) and stress-test tool-calling over a long session
  before switching — quantized MLX servers have been reported to degrade tool
  calls after 5-10 rounds.
- **At 27B+, the framework gap shrinks anyway.** The dramatic "MLX is 2-4x
  Ollama" numbers floating around are mostly measured on small (0.6B-8B)
  models where kernel overhead dominates. At 27B/35B, Apple Silicon is memory-
  bandwidth bound, so Ollama-MLX and other MLX servers converge.

Net: Ollama's MLX backend already gets you native Apple Silicon acceleration
*and* the most mature, most-issue-tracked tool-calling story for these model
sizes. Revisit this if Rapid-MLX or oMLX close the Coder-template tool-calling
gap with published, apples-to-apples benchmarks against current Ollama.

## License

See [LICENSE](./LICENSE).
