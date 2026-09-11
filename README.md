# mac-local-coding-agent

A **fully local, private, $0** AI coding setup for an Apple Silicon Mac,
tuned for an **M5 Pro with 48 GB** (works on any M-series with 32 GB+).
No cloud providers, no API keys, nothing leaves the machine.

It gives you four things:

1. **`src/local-llm.ts`** — a dependency-free TypeScript client for a local,
   OpenAI-compatible LLM server (oMLX), using only Bun's native `fetch`.
2. **`src/agent.ts`** — a minimal terminal coding agent (REPL) built on that client.
3. **`opencode.json`** — a ready-to-use [OpenCode](https://opencode.ai) config
   wired to oMLX, with Qwen 3.8 as the default model.
4. **`bench.sh`** — a 30-second tok/s check (prefill, prefix-cache hit, decode).

Everything talks to oMLX's OpenAI-compatible endpoint at
`http://localhost:8000/v1` (it also serves Anthropic's `/v1/messages`, which
is how Claude Code / the Claude Agent SDK connect — see below).

## One-shot install

On a fresh Mac (Apple Silicon), clone and run the bootstrap script. It installs
Homebrew (if needed), Bun, the Hugging Face CLI, **oMLX 0.6.4+**, OpenCode,
downloads the model, writes the oMLX settings (Lightning MTP on, 128K context,
Qwen-recommended sampling) and restarts the server:

```sh
git clone https://github.com/vanmeegen/mac-local-coding-agent
cd mac-local-coding-agent
./setup.sh
```

`setup.sh` is **idempotent** — re-running it skips anything already installed
and re-applies the settings without clobbering unrelated keys.

Heads-up on downloads: the driver model is **~17 GB**. Optional extras:

```sh
INSTALL_QUALITY=1 ./setup.sh           # + Qwen3.8-27B oQ6e (~24 GB), near-lossless
INSTALL_MOE=1 ./setup.sh               # + Qwen3.6-35B-A3B MoE (~20 GB), fastest decode
INSTALL_OLLAMA_FALLBACK=1 ./setup.sh   # + Ollama 0.34 with qwen3.8-coder (fallback only)
INSTALL_OPENCODE=0 ./setup.sh          # skip OpenCode
```

Prefer to install by hand? `setup.sh` is short and readable — it documents every
step it automates (Homebrew → Bun → hf → oMLX → OpenCode → model download →
`~/.omlx/settings.json` + `~/.omlx/model_settings.json` → `omlx restart`).

## Quickstart

**Benchmark first** (so you know what "normal" looks like on your box):

```sh
./bench.sh                      # driver model
./bench.sh Qwen3.8-27B-oQ6e-mtp # any other oMLX model
```

**Terminal agent:**

```sh
bun src/agent.ts                 # start the REPL
bun src/agent.ts src/foo.ts      # preload files into context
```

Inside the REPL: `@path` inlines a file, `/run <cmd>` feeds command output back
to the model, `/write <path>` saves the last code block, `/model fast|quality|moe`
switches models, `/help` lists everything.

**OpenCode:**

```sh
cp opencode.json ~/.config/opencode/   # setup.sh already does this
opencode
```

Restart OpenCode after editing `opencode.json` — config changes are read at
startup.

**Claude Code against the local model** (oMLX sets all the env vars for you):

```sh
omlx launch claude --model Qwen3.8-27B-oQ4e-mtp
```

Scripted / CI use of OpenCode: close stdin (`opencode run … </dev/null`),
otherwise `opencode run` can sit waiting on the terminal before it sends the
first request.

## The models

| Role | oMLX model id | Notes |
| --- | --- | --- |
| **Driver** | `Qwen3.8-27B-oQ4e-mtp` | **Default.** Qwen3.8-27B (Aug 2026, Apache 2.0, 262K context, vision) in oMLX's calibrated mixed-precision oQ4 (~17 GB) **with its MTP head kept** so Lightning MTP can draft tokens. Best tool-calling reliability of anything that fits 48 GB — testers report zero failed tool calls over multi-hour agent sessions, a clear step up from 3.6. |
| Quality gear | `Qwen3.8-27B-oQ6e-mtp` | Same model at oQ6 (~24 GB), near-lossless. Measured only ~10 % slower decode (28 vs 31 tok/s). Use for hard refactors when speed matters less. |
| Speed gear | `Qwen3.6-35B-A3B-oQ4e-mtp` | MoE, 3 B active (~20 GB). 2–3x the decode speed of the dense 27B, but weaker tool-calling and lower SWE-bench (73 vs 77 for 3.6-27B; 3.8-27B is better still). Reach for it for simple, well-specified edits. |

There is no small Qwen 3.8: the family is 27B dense, a 176B MoE (needs 163 GB)
and an API-only Max. Qwen 3.8 has no "Coder" variant either — the base model
was trained for agentic coding and evaluated with the Claude Code harness
(SWE-bench Pro 61.7, Terminal-Bench 2.1 73.0).

### Why this quant

oQ is oMLX's data-driven mixed-precision format: it calibrates per-layer
sensitivity and spends extra bits where they matter (lm_head, attention
projections) while keeping the bulk at 4 bits. On Qwen3.5-35B it scored
*higher* than plain 4-bit mlx-lm on MMLU/HumanEval/MBPP. The `-mtp` suffix
means the checkpoint keeps the model's own multi-token-prediction head, which
plain mlx-community conversions strip — without it there is no speculative
decoding.

## Why oMLX (and not Ollama) — updated September 2026

This repo used to recommend Ollama. That advice is obsolete for agent work on
Qwen; three things changed:

1. **Ollama ≥ 0.32 lost its prompt cache for Qwen 3.5/3.6/3.8.** Its
   llama.cpp runner cannot checkpoint Qwen's hybrid Gated-DeltaNet attention
   and logs *"forcing full prompt re-processing due to lack of cache data"* on
   every request. An agent harness sends 20–40k tokens per turn, so every turn
   pays a full prefill — minutes of time-to-first-token on an M5 Pro. (Measured
   in the sister project macvibes, which had to pin Ollama 0.30.8.) Ollama
   doesn't pass the llama.cpp flags that would help through.
2. **oMLX has the cache Ollama lost — and then some.** A block-based prefix
   cache in RAM with an SSD cold tier: after the first turn, the system prompt
   and the whole conversation prefix are restored from cache (96 % hit rate in
   a real OpenCode session), so time-to-first-token is seconds, not minutes.
   Copy-on-write means branching conversations don't recompute either.
3. **Lightning MTP.** oMLX 0.6 runs the model's own MTP head as a lossless
   speculative drafter with adaptive depth (1–3 tokens per verify step). On an
   M3 Ultra it took Qwen3.6-27B from 35 → 55 tok/s and 35B-A3B from 90 → 140.
   The verify kernels are ported from MTPLX and use the M5 GPU's tensor units.

On top of that oMLX gives you: native `/v1/messages` (Claude Code / Agent SDK
connect without a LiteLLM shim), a one-click Claude Code / OpenCode / Codex /
Pi integration, per-model settings in a web UI (`http://localhost:8000/admin`),
TurboQuant KV compression for very long contexts, NAX kernels for M5 prefill,
and an INT8-activation prefill path for Qwen on M5 (+34 % prefill, 0.7.0-dev).

What about the others?

- **`mlx_lm.server`** — no. Its KV cache grows unbounded during agent sessions
  and takes the GPU driver down with it (ml-explore/mlx-lm #883, #1390, #1672),
  `--max-kv-size` never made it into the server, tool-call parsing for plain
  Qwen templates is still broken, and its `--draft-model` flag cannot drive
  an MTP head.
- **MTPLX** — the fastest published decode numbers (63 tok/s on Qwen3.8-27B
  4-bit on an M5 Max, 2.24x over baseline, exact rejection sampling so it is
  lossless at any temperature) and the same Anthropic + OpenAI endpoints. It
  has no KV quantization, no multi-model, and a simpler session cache. Worth a
  10-minute A/B if raw tok/s is all you care about: `brew install
  youssofal/mtplx/mtplx && mtplx start`.
- **LM Studio** — fine GUI fallback: MTP stable since 0.4.14, mlx-engine
  1.8.5 checkpoints KV cache to disk for agent workflows, serves both API
  styles. Less control than oMLX's per-model settings.
- **Rapid-MLX** — strong feature list (radix prompt cache, TurboQuant KV, 17
  tool parsers) but no M5 support documented as of August 2026.

## What to expect on an M5 Pro 48 GB

Decode is memory-bandwidth-bound (M5 Pro: 307 GB/s; M5 Max: 614 GB/s), prefill
is compute-bound and 3–4x faster on M5 than M4 thanks to the per-core Neural
Accelerators (needs macOS 26.2+).

<!-- BENCH:START -->
Measured with `./bench.sh` on this repo's reference machine (MacBook Pro
M5 Pro 18-core, 48 GB, macOS 26.6.2, oMLX 0.6.4, Lightning MTP adaptive,
8.2k-token prompt, 256 generated tokens, no `iogpu.wired_limit_mb` tweak):

| Model | Cold prefill | Cached prefill (same prefix) | Decode |
| --- | --- | --- | --- |
| `Qwen3.8-27B-oQ4e-mtp` | 458 tok/s (18.0 s) | 0.57 s (32x) | **30.9–31.9 tok/s** |
| `Qwen3.8-27B-oQ4e-mtp`, MTP off | — | — | 16.5 tok/s |
| `Qwen3.8-27B-oQ6e-mtp` | 412 tok/s (20.0 s) | 0.63 s (32x) | 27.8 tok/s |

So Lightning MTP is worth **1.9x** on decode, and the oQ6e quality gear costs
only ~10 % decode (not the 30 % you'd expect from weight size alone, because
MTP acceptance is slightly higher on the better quant).

Real harness turns against the same server (one file-write task, driver model):

| Harness | Prompt tokens / turn | Turn 1 (cold) | Turn 2 (cache hit) | Total |
| --- | --- | --- | --- | --- |
| OpenCode 1.17 | ~7.5k | 24 s | 5 s | 31 s |
| Claude Code (`claude -p`, Agent SDK) | ~23k | 57 s | 4 s | 61 s, `cache_read_input_tokens: 22528` |

The second turn is fast in both because the whole prefix comes from the
cache; Claude Code's bigger system prompt only costs once per session.
<!-- BENCH:END -->

Rules of thumb: the 35B-A3B MoE decodes ~2–3x faster than the dense 27B; an
M5 Max (2x the memory bandwidth) roughly doubles all decode numbers.

## Gotchas

- **`tools: true` is required.** Each model in `opencode.json` must set it or
  tools never fire.
- **Sampling: leave it at the Qwen3.8 defaults** (temperature 1.0, top_p 0.95,
  top_k 20, thinking mode). Lowering the temperature does not make Qwen 3.8's
  tool calls more reliable, and it *lowers* MTP draft acceptance, i.e. makes
  decode slower. Both the client and the oMLX per-model settings are set
  accordingly by `setup.sh`.
- **Thinking mode is on** and Qwen 3.8 handles it cleanly (3.6 needed it off to
  avoid loops). If a task is simple and you want speed, cap it per model in the
  oMLX admin UI (*thinking budget*) rather than disabling it.
- **Context.** `setup.sh` sets 128K per model (`OMLX_CONTEXT=…` to change).
  Qwen 3.8's KV cache costs only ~64 KB per token (16 of 64 layers are full
  attention), so 128K is ~8 GB — fine next to a 17 GB model. Claude Code
  needs at least 48K.
- **Memory headroom / switching gears.** macOS lets the GPU wire only ~75 %
  of RAM by default (37.4 GB of 48). The driver (16 GB) plus 128K context is
  fine, but the driver and the oQ6e gear (22 GB) do **not** fit side by side, so
  oMLX evicts the idle one when you switch models (LRU, ~5 s reload from SSD).
  That is why `setup.sh` does not pin any model — a pinned model can never be
  evicted and the second one would fail with a 507. If you want both resident
  (instant switching), raise the limit per boot:
  `sudo sysctl iogpu.wired_limit_mb=43008` (leaves 6 GB for macOS).
- **`preserve_mid_system_cache: false`** in `~/.omlx/settings.json` (written by
  `setup.sh`). OpenCode and Claude Code send a leading `developer`/`system`
  pair; with the default `true`, oMLX's cache preservation merges them in a way
  Qwen's "system message only at position 0" template rejects
  (jundot/omlx#1966, #1908, #1923).
- **First request after a restart is slow** (model load ≈ 5 s from SSD plus
  the cold prefill). Models stay resident afterwards until another one needs
  the memory.
- **Ollama fallback** (`INSTALL_OLLAMA_FALLBACK=1`) builds `qwen3.8-coder`
  from the library `qwen3.8:27b-mtp-q4_K_M` tag with `num_ctx 65536`. Use it
  only for tools that speak Ollama-only APIs — not as the agent driver (see
  above).

## Which harness

- **OpenCode** (this repo's default): model-agnostic, per-agent model config,
  LSP, skills, reads Qwen's reasoning fields. Its system prompt is bigger than
  Pi's, but with oMLX's prefix cache you pay it once per session.
- **Pi** (`pi.dev`): system prompt + 4 tools under ~1,000 tokens — the least
  prefill per turn and the fastest median turn time in harness comparisons.
  `omlx launch pi` sets it up.
- **Claude Code / Claude Agent SDK**: works out of the box via oMLX's
  `/v1/messages`. It sends the largest system prompt and tool set of the three
  (roughly 2–3x the input tokens per session of Codex or Qwen-Code in
  published comparisons), so the prefix cache is essential. `omlx launch claude`
  sets the right env — the important ones if you wire it yourself:

  ```sh
  ANTHROPIC_BASE_URL=http://localhost:8000
  ANTHROPIC_AUTH_TOKEN=omlx            # or your oMLX api key
  ANTHROPIC_API_KEY=                   # empty
  ANTHROPIC_DEFAULT_OPUS_MODEL=Qwen3.8-27B-oQ4e-mtp
  ANTHROPIC_DEFAULT_SONNET_MODEL=Qwen3.8-27B-oQ4e-mtp
  ANTHROPIC_DEFAULT_HAIKU_MODEL=Qwen3.8-27B-oQ4e-mtp
  CLAUDE_CODE_SUBAGENT_MODEL=Qwen3.8-27B-oQ4e-mtp
  CLAUDE_CODE_ATTRIBUTION_HEADER=0     # per-request header breaks prefix caching
  CLAUDE_CODE_MAX_CONTEXT_TOKENS=131072
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=131072
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  API_TIMEOUT_MS=3000000
  ```

## License

See [LICENSE](./LICENSE).
