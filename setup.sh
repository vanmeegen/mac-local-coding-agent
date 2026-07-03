#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for the local-only coding toolkit.
#
# On a fresh Apple Silicon Mac:  git clone … && cd … && ./setup.sh
# Installs Homebrew (if needed), Bun, Ollama 0.30+, pulls/builds the models,
# installs OpenCode, and copies the config into place — leaving everything
# ready to run.
#
# Idempotent: re-running skips anything already installed/pulled.
#
# Env toggles:
#   INSTALL_MOE=0        skip the 35B-A3B MoE "fast gear" model
#   INSTALL_OPENCODE=0   skip installing OpenCode / copying the config
#
set -euo pipefail

INSTALL_MOE="${INSTALL_MOE:-1}"
INSTALL_OPENCODE="${INSTALL_OPENCODE:-1}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_URL="http://localhost:11434"
DRIVER_BASE="hf.co/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M"
DRIVER_NAME="qwen3.6-coder"
MOE_MODEL="qwen3.6:35b-a3b"

# --- pretty logging ----------------------------------------------------------
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok()    { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m! %s\033[0m\n' "$*"; }
die()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

bold "mac-local-coding-agent — bootstrap"

# --- 1. platform sanity ------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "This script targets macOS. Continuing, but installs may differ."
elif [[ "$(uname -m)" != "arm64" ]]; then
  warn "Not Apple Silicon (arm64). The MLX acceleration story assumes an M-series Mac."
else
  ok "macOS on Apple Silicon detected."
fi

# --- 2. Homebrew -------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  info "Homebrew not found. Installing…"
  read -r -p "Install Homebrew now? [Y/n] " reply
  if [[ "${reply:-Y}" =~ ^[Nn]$ ]]; then
    die "Homebrew is required. Aborting."
  fi
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for both Apple Silicon and Intel default prefixes.
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

# --- 4. Ollama (>= 0.30) -----------------------------------------------------
# 0.19 was the first MLX-backend preview (March 2026); 0.30+ carries several
# rounds of MLX hardening since then (M5 Neural Accelerator matmul kernel,
# snapshotting for reliability, MTP tuning) and is the version this setup is
# validated against.
need_ollama_install=1
if command -v ollama >/dev/null 2>&1; then
  ver="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  if [[ -n "$ver" ]]; then
    # Compare major.minor against 0.30.
    major="${ver%%.*}"; rest="${ver#*.}"; minor="${rest%%.*}"
    if (( major > 0 )) || (( major == 0 && minor >= 30 )); then
      need_ollama_install=0
      ok "Ollama $ver (>= 0.30)."
    else
      warn "Ollama $ver is too old (< 0.30). Upgrading…"
      brew upgrade ollama || warn "brew upgrade failed; you may need to update manually."
      need_ollama_install=0
    fi
  fi
fi
if (( need_ollama_install == 1 )); then
  info "Installing Ollama…"
  brew install ollama || die "Failed to install Ollama via Homebrew."
fi
command -v ollama >/dev/null 2>&1 || die "Ollama not on PATH after install."

# --- 5. OpenCode (optional, small download) ----------------------------------
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

# --- 6. project deps (none, but initialize cleanly) -------------------------
info "Initializing the Bun project…"
( cd "$REPO_DIR" && bun install ) || warn "bun install reported an issue (project has no deps; safe to ignore)."

# === Big downloads last ======================================================
# Everything below pulls multi-GB model weights. Kept at the end so the fast
# tooling setup (Homebrew, Bun, Ollama, OpenCode, config) is complete first —
# a slow or failed model download won't block the rest of the install.

# --- 7. start the Ollama server (needed for the model pulls) -----------------
server_up() { curl -fsS "${OLLAMA_URL}/v1/models" >/dev/null 2>&1; }

# Start a fresh `ollama serve` in the background and wait for it to answer.
start_server() {
  nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
  for _ in $(seq 1 30); do
    server_up && return 0
    sleep 1
  done
  return 1
}

# Kill any running server and start a clean one. A stale/wedged `ollama serve`
# accepts a pull request but then drops the download stream, surfacing as
# "Error: EOF" with no progress — restarting the server clears that state.
restart_server() {
  warn "Restarting the Ollama server…"
  pkill -f "ollama serve" 2>/dev/null || true
  sleep 2
  start_server || die "Ollama server did not come back up. Check /tmp/ollama-serve.log"
  ok "Ollama server restarted at ${OLLAMA_URL}."
}

if server_up; then
  ok "Ollama server already running."
else
  info "Starting Ollama server in the background…"
  start_server || die "Ollama server did not come up. Check /tmp/ollama-serve.log"
  ok "Ollama server is up at ${OLLAMA_URL}."
fi

# Pull a model, retrying once after a server restart. The first attempt can fail
# with "Error: EOF" when an already-running server is in a wedged state; a fresh
# server almost always succeeds. Returns non-zero only if both attempts fail.
pull_model() {
  local model="$1"
  ollama pull "$model" && return 0
  warn "Pull of '$model' failed (often a stale server / EOF). Retrying once…"
  restart_server
  ollama pull "$model"
}

# --- 8. driver model (~16 GB) ------------------------------------------------
# Match a model by name, tolerating the implicit ":latest" tag that `ollama list`
# shows for an untagged build (e.g. "qwen3.6-coder" is listed as
# "qwen3.6-coder:latest"). Without this, the driver is re-pulled every run.
has_model() {
  ollama list 2>/dev/null | awk '{print $1}' | grep -qxE "$1(:latest)?"
}

if has_model "$DRIVER_NAME"; then
  ok "Driver model '$DRIVER_NAME' already built."
else
  info "Pulling driver base ($DRIVER_BASE, ~16 GB)…"
  pull_model "$DRIVER_BASE" || die "Failed to pull $DRIVER_BASE (after a server-restart retry). Check /tmp/ollama-serve.log"
  info "Building '$DRIVER_NAME' from Modelfile…"
  ollama create "$DRIVER_NAME" -f "$REPO_DIR/Modelfile" || die "ollama create failed."
  ok "Built $DRIVER_NAME."
fi

# --- 9. MoE "fast gear" (optional, large download) --------------------------
if [[ "$INSTALL_MOE" == "1" ]]; then
  if has_model "$MOE_MODEL"; then
    ok "MoE model '$MOE_MODEL' already present."
  else
    info "Pulling MoE fast gear ($MOE_MODEL)…"
    pull_model "$MOE_MODEL" || warn "Failed to pull $MOE_MODEL (skipping; agent still works on dense)."
  fi
else
  info "Skipping MoE model (INSTALL_MOE=0)."
fi

# --- 10. done ----------------------------------------------------------------
echo
bold "✅ Ready."
echo "Run the terminal agent:   bun src/agent.ts"
if [[ "$INSTALL_OPENCODE" == "1" ]]; then
  echo "Run OpenCode:             opencode   (restart after editing opencode.json)"
fi
echo "Models:                   $DRIVER_NAME (driver)$( [[ "$INSTALL_MOE" == "1" ]] && echo ", $MOE_MODEL (fast gear)" )"
