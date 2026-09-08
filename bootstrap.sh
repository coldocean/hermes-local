#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hermes Agent — local install, local Ollama brain.
#
#   bash bootstrap.sh                 # install + configure + open dashboard
#   bash bootstrap.sh --model qwen3:8b
#   bash bootstrap.sh --no-dashboard
#   bash bootstrap.sh --dry-run       # print the plan, touch nothing
#
# Safe to re-run: every step checks before it acts.
# Verified against hermes-agent 0.19.0 (pip) on Python 3.13.
# ---------------------------------------------------------------------------
set -euo pipefail

# ----------------------------- settings ------------------------------------
HERMES_DIR="${HERMES_DIR:-$HOME/hermes-local}"
VENV="$HERMES_DIR/venv"
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
DASH_PORT="${DASH_PORT:-9119}"
DASH_HOST="${DASH_HOST:-127.0.0.1}"
MODEL=""
WANT_DASH=1
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --model)         MODEL="${2:?--model needs a value}"; shift 2 ;;
    --port)          DASH_PORT="${2:?}"; shift 2 ;;
    --home)          export HERMES_HOME="${2:?}"; shift 2 ;;
    --dir)           HERMES_DIR="${2:?}"; VENV="$HERMES_DIR/venv"; shift 2 ;;
    --no-dashboard)  WANT_DASH=0; shift ;;
    --dry-run)       DRY=1; shift ;;
    -h|--help)       sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ----------------------------- output --------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; Z=""; fi
step() { printf '\n%s==>%s %s\n' "$B" "$Z" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; }
die()  { printf '\n  %sx%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------- 1. machine ----------------------------------
step "Inspecting this machine"

UNAME="$(uname -s)"
case "$UNAME" in
  Darwin) OS=macos ;;
  Linux)  OS=linux; grep -qi microsoft /proc/version 2>/dev/null && OS=wsl ;;
  *)      die "unsupported OS '$UNAME'. On Windows, run this inside WSL2." ;;
esac

if [ "$OS" = macos ]; then
  RAM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
else
  RAM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
fi
[ "$RAM_GB" -ge 1 ] || RAM_GB=1

ok "os: $OS ($(uname -m))"
ok "ram: ${RAM_GB} GB"

# ----------------------------- 2. python -----------------------------------
step "Locating Python 3.11–3.13 (hermes-agent requires >=3.11,<3.14)"

PY=""
for c in python3.13 python3.12 python3.11 python3 python; do
  have "$c" || continue
  v="$("$c" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)"
  case "$v" in 3.11|3.12|3.13) PY="$c"; PYV="$v"; break ;; esac
done
[ -n "$PY" ] || die "no Python 3.11-3.13 found.
  macos: brew install python@3.13
  linux: sudo apt-get install -y python3.13 python3.13-venv"
ok "python: $PY ($PYV)"

# ----------------------------- 3. venv -------------------------------------
step "Creating the virtualenv at $VENV"

if [ -x "$VENV/bin/hermes" ]; then
  ok "venv already exists — reusing it"
else
  run mkdir -p "$HERMES_DIR"
  if [ "$DRY" = 1 ]; then
    echo "  would run: $PY -m venv $VENV"
  elif ! "$PY" -m venv "$VENV" 2>/tmp/venv.err; then
    # Debian/Ubuntu ship python without ensurepip. This is the #1 failure here.
    if grep -q ensurepip /tmp/venv.err; then
      warn "ensurepip missing — installing python${PYV}-venv"
      sudo apt-get update -qq && sudo apt-get install -y "python${PYV}-venv"
      "$PY" -m venv "$VENV"
    else
      cat /tmp/venv.err >&2; die "venv creation failed"
    fi
  fi
  ok "venv ready"
fi
HERMES="$VENV/bin/hermes"

# ----------------------------- 4. hermes -----------------------------------
step "Installing hermes-agent from PyPI"

if [ -x "$HERMES" ]; then
  ok "installed: $("$HERMES" --version 2>/dev/null | head -1)"
else
  run "$VENV/bin/pip" install --upgrade pip
  run "$VENV/bin/pip" install hermes-agent
  [ "$DRY" = 1 ] || ok "installed: $("$HERMES" --version | head -1)"
fi

step "Running hermes postinstall (node, browser, ripgrep, ffmpeg)"
warn "pip cannot ship these; without them Hermes' tools are crippled"
run "$HERMES" postinstall || warn "postinstall reported problems — 'hermes doctor' will tell you which"

# ----------------------------- 5. ollama -----------------------------------
step "Setting up Ollama"

if have ollama; then
  ok "ollama present: $(ollama --version 2>&1 | head -1)"
else
  warn "ollama not found — installing"
  if [ "$OS" = macos ]; then
    if have brew; then run brew install ollama
    else die "install Ollama first: https://ollama.com/download"; fi
  else
    run sh -c 'curl -fsSL https://ollama.com/install.sh | sh'
  fi
fi

# Is the API up? Start it in the background if not.
if curl -fsS --max-time 3 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  ok "ollama api answering on $OLLAMA_URL"
elif [ "$DRY" = 1 ]; then
  echo "  would run: ollama serve &"
else
  warn "starting 'ollama serve' in the background (log: $HERMES_DIR/ollama.log)"
  mkdir -p "$HERMES_DIR"
  nohup ollama serve >"$HERMES_DIR/ollama.log" 2>&1 &
  for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "$OLLAMA_URL/api/tags" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS --max-time 2 "$OLLAMA_URL/api/tags" >/dev/null 2>&1 \
    || die "ollama did not come up. check $HERMES_DIR/ollama.log"
  ok "ollama api answering on $OLLAMA_URL"
fi

# ----------------------------- 6. model ------------------------------------
step "Choosing a model"

# Hermes is an AGENT: it lives on native tool calling. Families that support it:
TOOL_FAMILIES="qwen3 qwen2.5 llama3.3 llama3.2 llama3.1 mistral-nemo mistral-small mistral-large command-r firefunction devstral granite3"
tool_capable() { for f in $TOOL_FAMILIES; do case "$1" in "$f"*) return 0 ;; esac; done; return 1; }

INSTALLED="$(curl -fsS --max-time 5 "$OLLAMA_URL/api/tags" 2>/dev/null \
  | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' || true)"
if [ -n "$INSTALLED" ]; then
  echo "  already downloaded:"; echo "$INSTALLED" | sed 's/^/    - /'
else
  echo "  no models downloaded yet"
fi

# Size to RAM: rough Q4 footprints — 1B .8G, 3B 2.5G, 7-8B 5G, 14B 9G, 32B 20G, 70B 40G.
if   [ "$RAM_GB" -lt 6 ];  then SIZED="llama3.2:1b";  NOTE="wiring proof only — too small to be a useful agent"
elif [ "$RAM_GB" -lt 12 ]; then SIZED="llama3.2:3b";  NOTE="usable for simple tool calls"
elif [ "$RAM_GB" -lt 20 ]; then SIZED="qwen2.5:7b";   NOTE="the sweet spot for an agent brain"
elif [ "$RAM_GB" -lt 32 ]; then SIZED="qwen2.5:14b";  NOTE="strong"
elif [ "$RAM_GB" -lt 64 ]; then SIZED="qwen2.5:32b";  NOTE="very strong"
else                            SIZED="llama3.3:70b"; NOTE="~40 GB download"
fi

if [ -n "$MODEL" ]; then
  tool_capable "$MODEL" || warn "'$MODEL' is not in a known tool-calling family — Hermes may fail to use tools"
else
  # Prefer something already on disk over a fresh multi-GB download.
  MODEL=""
  for m in $INSTALLED; do if tool_capable "$m"; then MODEL="$m"; break; fi; done
  if [ -n "$MODEL" ]; then ok "reusing downloaded tool-capable model: $MODEL"
  else MODEL="$SIZED"; ok "picked for ${RAM_GB} GB: $MODEL ($NOTE)"; fi
fi

if echo "$INSTALLED" | grep -qx "$MODEL"; then
  ok "$MODEL already present"
else
  step "Pulling $MODEL (this is the slow part)"
  run ollama pull "$MODEL"
fi

# ----------------------------- 7. config -----------------------------------
step "Pointing Hermes at local Ollama (HERMES_HOME=$HERMES_HOME)"

# num_ctx: keep the context inside RAM. 32k needs headroom the small boxes lack.
if   [ "$RAM_GB" -lt 8 ];  then NUM_CTX=8192
elif [ "$RAM_GB" -lt 16 ]; then NUM_CTX=16384
else                            NUM_CTX=32768; fi

if [ "$DRY" = 0 ] && [ ! -f "$HERMES_HOME/config.yaml" ]; then
  "$HERMES" setup --non-interactive >/dev/null 2>&1 || true
fi

# These four keys are the verified Ollama wiring. provider 'custom' is the
# documented local path (aliases: ollama, local, vllm, llamacpp) and it also
# sends max_tokens, without which Ollama truncates at num_predict=128.
run "$HERMES" config set model.provider custom
run "$HERMES" config set model.base_url "$OLLAMA_URL/v1"
run "$HERMES" config set model.default "$MODEL"
run "$HERMES" config set model.ollama_num_ctx "$NUM_CTX"

if [ "$DRY" = 0 ]; then
  echo
  for k in model.provider model.base_url model.default model.ollama_num_ctx; do
    printf '  %-24s = %s\n' "$k" "$("$HERMES" config get "$k" 2>/dev/null | tail -1)"
  done
  echo
  ok "config file: $("$HERMES" config path 2>/dev/null | tail -1)"
fi

# ----------------------------- 8. verify -----------------------------------
step "Verifying the model answers through the OpenAI-compatible endpoint"

if [ "$DRY" = 0 ]; then
  if curl -fsS --max-time 180 "$OLLAMA_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"reply with the single word: ready\"}]}" \
      | grep -qi ready; then
    ok "round-trip OK — Hermes and Ollama are wired together"
  else
    warn "no clean reply. check: ollama run $MODEL"
  fi
fi

# ----------------------------- 9. run --------------------------------------
step "Done"
cat <<EOF

  Hermes:   $HERMES
  Config:   $HERMES_HOME/config.yaml
  Model:    $MODEL  (local, via Ollama)

  Chat in the terminal:   $HERMES chat
  Dashboard:              $HERMES dashboard --host $DASH_HOST --port $DASH_PORT
  Health check:           $HERMES doctor
  Stop the dashboard:     $HERMES dashboard --stop

  Put this in your shell rc so 'hermes' is always on PATH:
    export PATH="$VENV/bin:\$PATH"

EOF

if [ "$WANT_DASH" = 1 ] && [ "$DRY" = 0 ]; then
  step "Launching the dashboard on http://$DASH_HOST:$DASH_PORT"
  exec "$HERMES" dashboard --host "$DASH_HOST" --port "$DASH_PORT"
fi
