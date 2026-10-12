#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for the local-only coding toolkit (M5-era edition).
#
# On a fresh Apple Silicon Mac:  git clone … && cd … && ./setup.sh
# Installs Homebrew (if needed), Bun, the Hugging Face CLI, oMLX 0.7.0+,
# OpenCode, downloads the Qwen 3.8 MTP checkpoint(s) into oMLX's model
# directory, writes the oMLX server + per-model settings (Lightning MTP on,
# 128K context, Qwen-recommended sampling), restarts oMLX and copies the
# OpenCode config into place — leaving everything ready to run.
#
# Idempotent: re-running skips anything already installed/downloaded and
# re-applies the settings (merge, never clobber unrelated keys).
#
# Env toggles:
#   INSTALL_QUALITY=1        also download the oQ6e "quality gear" (~24 GB)
#   INSTALL_MOE=1            also download the Qwen3.6-35B-A3B MoE "speed gear" (~20 GB)
#   INSTALL_OPENCODE=0       skip installing OpenCode / copying the config
#   INSTALL_OLLAMA_FALLBACK=1  also set up Ollama 0.34+ with qwen3.8-coder (fallback only)
#   OMLX_CONTEXT=131072      per-model max context window for oMLX (tokens)
#   OMLX_SSD_CACHE=50GB      cap for oMLX's on-disk prefix cache ("auto" = half the free disk)
#
set -euo pipefail

INSTALL_QUALITY="${INSTALL_QUALITY:-0}"
INSTALL_MOE="${INSTALL_MOE:-0}"
INSTALL_OPENCODE="${INSTALL_OPENCODE:-1}"
INSTALL_OLLAMA_FALLBACK="${INSTALL_OLLAMA_FALLBACK:-0}"
OMLX_CONTEXT="${OMLX_CONTEXT:-131072}"
OMLX_SSD_CACHE="${OMLX_SSD_CACHE:-50GB}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMLX_URL="http://localhost:8000"
OMLX_HOME="$HOME/.omlx"
OMLX_MODEL_DIR="$OMLX_HOME/models"
OMLX_MIN_VERSION="0.7.0"

# oMLX-native checkpoints (oQ = oMLX mixed-precision quant, "-mtp" = the
# model's own multi-token-prediction head kept for Lightning MTP).
DRIVER_REPO="Jundot/Qwen3.8-27B-oQ4e-mtp";      DRIVER_NAME="Qwen3.8-27B-oQ4e-mtp"       # ~17 GB
QUALITY_REPO="Jundot/Qwen3.8-27B-oQ6e-mtp";     QUALITY_NAME="Qwen3.8-27B-oQ6e-mtp"      # ~24 GB
MOE_REPO="Jundot/Qwen3.6-35B-A3B-oQ4e-mtp";     MOE_NAME="Qwen3.6-35B-A3B-oQ4e-mtp"      # ~20 GB

# Ollama fallback (only with INSTALL_OLLAMA_FALLBACK=1)
OLLAMA_URL="http://localhost:11434"
OLLAMA_BASE="qwen3.8:27b-mtp-q4_K_M"
OLLAMA_NAME="qwen3.8-coder"

# --- pretty logging ----------------------------------------------------------
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok()    { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m! %s\033[0m\n' "$*"; }
die()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# version_ge A B → true if A >= B (dotted numeric versions)
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

bold "mac-local-coding-agent — bootstrap (oMLX + Qwen 3.8 + Lightning MTP)"

# --- 1. platform sanity ------------------------------------------------------
mem_gb="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))"
if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "This script targets macOS. Continuing, but installs may differ."
elif [[ "$(uname -m)" != "arm64" ]]; then
  warn "Not Apple Silicon (arm64). MLX needs an M-series Mac."
else
  chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
  ok "$chip, ${mem_gb} GB unified memory."
  if (( mem_gb < 32 )); then
    warn "Less than 32 GB: the 27B driver still fits (~17 GB) but leave INSTALL_QUALITY/INSTALL_MOE off."
  fi
  osver="$(sw_vers -productVersion)"
  if ! version_ge "$osver" "26.2"; then
    warn "macOS $osver: the M5 Neural Accelerator (3-4x prefill) needs macOS 26.2+ for MLX."
  fi
fi

# --- 2. Homebrew -------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  info "Homebrew not found. Installing…"
  read -r -p "Install Homebrew now? [Y/n] " reply
  if [[ "${reply:-Y}" =~ ^[Nn]$ ]]; then
    die "Homebrew is required. Aborting."
  fi
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$p" ]] && eval "$("$p" shellenv)"
  done
fi
command -v brew >/dev/null 2>&1 || die "brew still not on PATH; open a new shell and re-run."
ok "Homebrew: $(brew --version | head -1)"

# --- 3. Bun ------------------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
  info "Installing Bun…"
  if ! brew install oven-sh/bun/bun; then
    warn "brew install failed; falling back to the official installer."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
  fi
fi
command -v bun >/dev/null 2>&1 || die "Bun install failed."
ok "Bun: $(bun --version)"

# --- 4. Hugging Face CLI (model downloads) -----------------------------------
if ! command -v hf >/dev/null 2>&1; then
  info "Installing the Hugging Face CLI (hf)…"
  brew install huggingface-cli || die "Failed to install huggingface-cli."
fi
command -v hf >/dev/null 2>&1 || die "hf not on PATH after install."
ok "hf: $(hf version 2>/dev/null | head -1 || echo installed)"

# --- 5. oMLX (>= 0.7.0) ------------------------------------------------------
# 0.6.x brings Lightning MTP (depth-k native multi-token prediction) for the
# Qwen 3.5/3.6/3.8 family, NAX GPU kernels for M5, TurboQuant KV, and the
# tiered RAM+SSD prefix cache that makes 30k-token agent turns cheap. 0.7.0
# makes MTP verify cheaper on Qwen3.8-27B (biggest gain at long context), stops
# re-prefilling stable system/tool prefixes, and keeps the GPU warm between
# requests (server.gpu_keep_warm_interval, default 0.5 s — no need to set it).
if ! brew tap | grep -qx "jundot/omlx"; then
  info "Adding the oMLX tap…"
  brew tap jundot/omlx https://github.com/jundot/omlx
fi
if command -v omlx >/dev/null 2>&1; then
  ver="$(omlx --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  if [[ -n "$ver" ]] && version_ge "$ver" "$OMLX_MIN_VERSION"; then
    ok "oMLX $ver (>= $OMLX_MIN_VERSION)."
  else
    warn "oMLX ${ver:-?} is too old (< $OMLX_MIN_VERSION). Upgrading (builds a Python env, takes a few minutes)…"
    brew upgrade jundot/omlx/omlx || die "brew upgrade omlx failed."
  fi
else
  info "Installing oMLX (builds a Python env, takes a few minutes)…"
  brew install jundot/omlx/omlx || die "Failed to install oMLX via Homebrew."
fi
command -v omlx >/dev/null 2>&1 || die "omlx not on PATH after install."

# --- 6. OpenCode (optional, small download) ----------------------------------
if [[ "$INSTALL_OPENCODE" == "1" ]]; then
  if ! command -v opencode >/dev/null 2>&1; then
    info "Installing OpenCode…"
    if ! brew install sst/tap/opencode; then
      warn "brew install failed; falling back to the official installer."
      curl -fsSL https://opencode.ai/install | bash || warn "OpenCode install failed; install it manually later."
    fi
  fi
  if command -v opencode >/dev/null 2>&1; then
    ok "OpenCode: $(opencode --version 2>/dev/null || echo installed)"
  fi
  mkdir -p "$HOME/.config/opencode"
  cp "$REPO_DIR/opencode.json" "$HOME/.config/opencode/opencode.json"
  ok "Copied opencode.json → ~/.config/opencode/"
else
  info "Skipping OpenCode (INSTALL_OPENCODE=0)."
fi

# --- 7. project deps (none, but initialize cleanly) -------------------------
info "Initializing the Bun project…"
( cd "$REPO_DIR" && bun install ) || warn "bun install reported an issue (project has no deps; safe to ignore)."

# === Big downloads ===========================================================
# Pulled straight from Hugging Face into oMLX's model directory. `hf download`
# resumes partial files and skips complete ones, so re-runs are cheap.
mkdir -p "$OMLX_MODEL_DIR"

download_model() { # $1 = HF repo, $2 = local dir name, $3 = human size hint
  local repo="$1" name="$2" hint="$3" dir="$OMLX_MODEL_DIR/$2"
  # Complete = config + weights present and no partial (*.incomplete) files left
  # behind by hf in its per-directory download cache.
  if [[ -f "$dir/config.json" ]] && ls "$dir"/*.safetensors >/dev/null 2>&1 \
     && ! find "$dir/.cache" -name '*.incomplete' 2>/dev/null | grep -q .; then
    ok "Model '$name' already present."
    return 0
  fi
  info "Downloading $repo → $dir ($hint)…"
  hf download "$repo" --local-dir "$dir" || die "Download of $repo failed (re-run to resume)."
  ok "Downloaded $name."
}

download_model "$DRIVER_REPO" "$DRIVER_NAME" "~17 GB"
if [[ "$INSTALL_QUALITY" == "1" ]]; then
  download_model "$QUALITY_REPO" "$QUALITY_NAME" "~24 GB"
else
  info "Skipping the oQ6e quality gear (INSTALL_QUALITY=1 to add it)."
fi
if [[ "$INSTALL_MOE" == "1" ]]; then
  download_model "$MOE_REPO" "$MOE_NAME" "~20 GB"
else
  info "Skipping the 35B-A3B MoE speed gear (INSTALL_MOE=1 to add it)."
fi

# === oMLX settings ===========================================================
# Server-level (~/.omlx/settings.json): only touch the keys we need.
#   sampling.max_context_window / max_tokens — the global ceiling (per-model
#     settings can only go lower), Claude Code needs >= 48K.
#   server.preserve_mid_system_cache=false — OpenCode/Claude Code send a leading
#     `developer`/`system` pair; with the default (true) oMLX's cache-preservation
#     merges them in a way Qwen's "system only at position 0" template rejects
#     (jundot/omlx#1966, #1908, #1923).
#   cache.enabled=true — tiered RAM+SSD prefix cache (the whole point).
#   cache.ssd_cache_max_size — capped (default 50GB); "auto" grows to half the
#     free disk, which reached ~46 GB within a few weeks of agent use.
info "Writing oMLX server settings ($OMLX_HOME/settings.json)…"
python3 - "$OMLX_HOME/settings.json" "$OMLX_MODEL_DIR" "$OMLX_CONTEXT" "$OMLX_SSD_CACHE" <<'PY'
import json, os, sys
path, model_dir, ctx, ssd_max = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
data.setdefault("version", "1.0")
srv = data.setdefault("server", {})
srv.setdefault("host", "127.0.0.1"); srv.setdefault("port", 8000)
srv["preserve_mid_system_cache"] = False
mdl = data.setdefault("model", {})
mdl["model_dir"] = model_dir
dirs = mdl.setdefault("model_dirs", [])
if model_dir not in dirs: dirs.insert(0, model_dir)
cache = data.setdefault("cache", {})
cache["enabled"] = True
cache["ssd_cache_max_size"] = ssd_max
samp = data.setdefault("sampling", {})
samp["max_context_window"] = max(int(samp.get("max_context_window") or 0), ctx)
samp["max_tokens"] = max(int(samp.get("max_tokens") or 0), 32768)
samp.setdefault("temperature", 1.0); samp.setdefault("top_p", 0.95)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PY
ok "Server settings written."

# Per-model (~/.omlx/model_settings.json):
#   mtp_enabled=true        — Lightning MTP: the checkpoint's own MTP head drafts
#                             1..N tokens per verify step (lossless, ~2x decode).
#   mtp_num_draft_tokens    — null = adaptive depth (oMLX picks 1..3 per sequence).
#   max_context_window      — 128K by default; Qwen3.8's KV cache is only ~64 KB/token
#                             (16 of 64 layers are full attention), so this is cheap.
#   temperature/top_p/top_k — Qwen3.8 model card, thinking mode. Do NOT lower the
#                             temperature "for reliability": it hurts MTP acceptance
#                             and the 3.8 tool calls are stable at 1.0.
#   is_default              — the driver answers requests without a model id.
#                             Models are NOT pinned so oMLX can swap gears (LRU).
info "Writing oMLX per-model settings ($OMLX_HOME/model_settings.json)…"
python3 - "$OMLX_HOME/model_settings.json" "$OMLX_CONTEXT" \
  "$DRIVER_NAME:driver" \
  "$( [[ "$INSTALL_QUALITY" == "1" ]] && echo "$QUALITY_NAME:quality" )" \
  "$( [[ "$INSTALL_MOE" == "1" ]] && echo "$MOE_NAME:moe" )" <<'PY'
import json, os, sys
path, ctx = sys.argv[1], int(sys.argv[2])
entries = [a for a in sys.argv[3:] if a]
data = {"version": 1, "models": {}}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
models = data.setdefault("models", {})
for entry in entries:
    name, role = entry.split(":", 1)
    m = models.setdefault(name, {})
    m.update({
        "mtp_enabled": True,
        "mtp_num_draft_tokens": None,
        "max_context_window": ctx,
        "temperature": 1.0,
        "top_p": 0.95,
        "top_k": 20,
        "repetition_penalty": 1.0,
        "presence_penalty": 0.0,
        "display_name": {
            "driver": "Qwen3.8 27B oQ4e + MTP (driver)",
            "quality": "Qwen3.8 27B oQ6e + MTP (quality gear)",
            "moe": "Qwen3.6 35B-A3B oQ4e + MTP (speed gear)",
        }[role],
    })
    # Not pinned on purpose: a pinned model can never be LRU-evicted, so on a
    # 48 GB Mac the oQ6e/MoE gears could not load next to it (Metal caps
    # wired memory at ~37 GB by default). Reload from SSD takes ~5 s.
    m["is_pinned"] = False
    m["is_default"] = role == "driver"
# Only one model may be default.
for name, m in models.items():
    if m.get("is_default") and not name.startswith("Qwen3.8-27B-oQ4e"):
        m["is_default"] = False
data["version"] = 1
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PY
ok "Per-model settings written."

# --- restart oMLX and wait ---------------------------------------------------
omlx_up() { curl -fsS "$OMLX_URL/health" >/dev/null 2>&1; }
info "Restarting oMLX…"
omlx restart >/dev/null 2>&1 || brew services restart jundot/omlx/omlx >/dev/null 2>&1 || omlx start >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  omlx_up && break
  sleep 1
done
omlx_up || die "oMLX did not come up on $OMLX_URL. Check ~/.omlx/logs/server.log"
ok "oMLX is up at $OMLX_URL (admin UI: $OMLX_URL/admin)."
models_json="$(curl -fsS "$OMLX_URL/v1/models" 2>/dev/null || echo '{}')"
if grep -q "\"$DRIVER_NAME\"" <<<"$models_json"; then
  ok "Driver model '$DRIVER_NAME' is served."
else
  warn "Driver model not listed yet — oMLX may still be scanning $OMLX_MODEL_DIR. Check $OMLX_URL/admin."
fi

# --- optional: Ollama fallback -----------------------------------------------
# Only if you need the Ollama API for other tools. NOT recommended as the agent
# driver: since 0.32 Ollama's llama.cpp runner cannot reuse its prompt cache for
# Qwen's hybrid (Gated DeltaNet) attention and re-prefills every agent turn.
if [[ "$INSTALL_OLLAMA_FALLBACK" == "1" ]]; then
  if ! command -v ollama >/dev/null 2>&1; then
    info "Installing Ollama…"; brew install ollama || die "Failed to install Ollama."
  fi
  over="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  if [[ -n "$over" ]] && ! version_ge "$over" "0.34"; then
    warn "Ollama $over < 0.34 (needed for the qwen3.8 MTP tags). Upgrading…"
    brew upgrade ollama || warn "brew upgrade ollama failed; update manually."
  fi
  server_up() { curl -fsS "${OLLAMA_URL}/v1/models" >/dev/null 2>&1; }
  if ! server_up; then
    info "Starting Ollama server in the background…"
    nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
    for _ in $(seq 1 30); do server_up && break; sleep 1; done
    server_up || die "Ollama server did not come up. Check /tmp/ollama-serve.log"
  fi
  if ollama list 2>/dev/null | awk '{print $1}' | grep -qxE "$OLLAMA_NAME(:latest)?"; then
    ok "Ollama fallback '$OLLAMA_NAME' already built."
  else
    info "Pulling $OLLAMA_BASE (~18 GB)…"
    ollama pull "$OLLAMA_BASE" || { warn "Pull failed (stale server?). Restarting and retrying once…"; pkill -f "ollama serve" || true; sleep 2; nohup ollama serve >/tmp/ollama-serve.log 2>&1 & sleep 5; ollama pull "$OLLAMA_BASE" || die "Pull failed twice."; }
    ollama create "$OLLAMA_NAME" -f "$REPO_DIR/Modelfile" || die "ollama create failed."
    ok "Built $OLLAMA_NAME (Ollama fallback)."
  fi
else
  info "Skipping the Ollama fallback (INSTALL_OLLAMA_FALLBACK=1 to add it)."
fi

# --- done --------------------------------------------------------------------
echo
bold "✅ Ready."
echo "Benchmark:                ./bench.sh"
echo "Run the terminal agent:   bun src/agent.ts"
if [[ "$INSTALL_OPENCODE" == "1" ]]; then
  echo "Run OpenCode:             opencode   (restart after editing opencode.json)"
fi
echo "Claude Code (local):      omlx launch claude --model $DRIVER_NAME"
echo "Models:                   $DRIVER_NAME (driver)$( [[ "$INSTALL_QUALITY" == "1" ]] && echo ", $QUALITY_NAME (quality)" )$( [[ "$INSTALL_MOE" == "1" ]] && echo ", $MOE_NAME (moe)" )"
echo
if [[ "$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)" == "0" ]]; then
  warn "Optional, per boot: let the GPU use more than macOS's default ~75% of RAM"
  echo "   sudo sysctl iogpu.wired_limit_mb=$(( mem_gb * 1024 - 6144 ))    # leaves 6 GB for macOS"
fi
