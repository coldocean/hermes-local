#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hermes Agent — local install, local Ollama brain.
#
#   bash bootstrap.sh                 # install + configure + open dashboard
#   bash bootstrap.sh --model llama3.1:8b
#   bash bootstrap.sh --ctx 131072    # bigger window (more RAM per token)
#   bash bootstrap.sh --no-dashboard
#   bash bootstrap.sh --dry-run       # print the plan, touch nothing
#
# THE 64K RULE. Hermes refuses to start on any model whose context window is
# under 64,000 tokens (agent/model_metadata.py: MINIMUM_CONTEXT_LENGTH=64000,
# enforced in agent/agent_init.py). That rejection is what produces
#   "agent init failed: Model X has a context window of 32,768 tokens,
#    which is below the minimum 64,000 required by Hermes Agent"
# So this script only offers models with a >=64K NATIVE window, pins
# model.context_length AND model.ollama_num_ctx to the same value, and refuses
# to configure a model that cannot honestly reach 64K. qwen2.5 (32,768) and
# qwen3 (40,960 on Ollama) can never pass — they are rejected by name.
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

# Hermes' hard floor is 64,000. 65,536 is the nearest power of two above it and
# the value we pin everywhere: model.context_length, model.ollama_num_ctx and
# Ollama's own OLLAMA_CONTEXT_LENGTH. Raise it only if you have the RAM.
MIN_CTX=65536
CTX="${HERMES_CTX:-$MIN_CTX}"

while [ $# -gt 0 ]; do
  case "$1" in
    --model)         MODEL="${2:?--model needs a value}"; shift 2 ;;
    --ctx)           CTX="${2:?--ctx needs a value}"; shift 2 ;;
    --port)          DASH_PORT="${2:?}"; shift 2 ;;
    --home)          export HERMES_HOME="${2:?}"; shift 2 ;;
    --dir)           HERMES_DIR="${2:?}"; VENV="$HERMES_DIR/venv"; shift 2 ;;
    --no-dashboard)  WANT_DASH=0; shift ;;
    --dry-run)       DRY=1; shift ;;
    -h|--help)       sed -n '2,25p' "$0"; exit 0 ;;
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

if [ "$CTX" -lt "$MIN_CTX" ] 2>/dev/null; then
  die "--ctx $CTX is below Hermes' hard minimum of 64,000 (use $MIN_CTX or more)"
fi

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

# --------------------------- 4b. TLS roots ---------------------------------
# python.org builds on macOS ship no root certificates, so every https call
# from inside the venv dies with:
#   model catalog fetch failed (...): certificate verify failed:
#   unable to get local issuer certificate (_ssl.c:1020)
# That is not cosmetic. With the catalog unreachable Hermes cannot look up a
# model's real context window and falls back to whatever the server reports.
step "Checking TLS root certificates"

if [ "$DRY" = 1 ]; then
  echo "  would run: pip install --upgrade certifi; verify https reachability"
else
  CERT_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/README.md"
  cert_ok() { "$VENV/bin/python" - "$CERT_URL" <<'PY' >/dev/null 2>&1
import ssl, sys, urllib.request
urllib.request.urlopen(sys.argv[1], timeout=10, context=ssl.create_default_context())
PY
  }
  if cert_ok; then
    ok "https from the venv verifies — model catalog reachable"
  else
    warn "https verification failed — installing certifi and wiring SSL_CERT_FILE"
    "$VENV/bin/pip" install --upgrade -q certifi || true
    if [ "$OS" = macos ]; then
      # python.org's own installer ships this; brew python does not need it.
      for c in /Applications/Python\ 3.1[123]/Install\ Certificates.command; do
        [ -f "$c" ] && { warn "running $(basename "$c")"; bash "$c" >/dev/null 2>&1 || true; }
      done
    fi
    CA="$("$VENV/bin/python" -m certifi 2>/dev/null || true)"
    if [ -n "$CA" ] && [ -f "$CA" ]; then
      export SSL_CERT_FILE="$CA" REQUESTS_CA_BUNDLE="$CA"
      # Persist for every future 'hermes' run from this venv.
      printf 'export SSL_CERT_FILE="%s"\nexport REQUESTS_CA_BUNDLE="%s"\n' "$CA" "$CA" \
        > "$HERMES_DIR/certs.env"
      if cert_ok; then ok "fixed via certifi bundle: $CA"
      else warn "still failing. corporate TLS proxy? add its root CA to $CA"; fi
      warn "the gateway needs these too: source $HERMES_DIR/certs.env"
    else
      warn "certifi unavailable — catalog lookups will stay offline (not fatal)"
    fi
  fi
fi

# ----------------------------- 5. ollama -----------------------------------
step "Setting up Ollama"

# Ollama's own default window is 4096 and it silently truncates to it, which
# would hand Hermes a sub-64K window no matter what config.yaml says. These
# three env vars are what make a 64K KV cache both served and affordable:
# flash attention + q8_0 KV roughly halves the cache footprint.
export OLLAMA_CONTEXT_LENGTH="$CTX"
export OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"

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
  warn "ollama was already running — it will NOT have picked up OLLAMA_CONTEXT_LENGTH=$CTX."
  warn "  macOS app users: quit Ollama, then in a terminal run"
  warn "    OLLAMA_CONTEXT_LENGTH=$CTX OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 ollama serve"
  warn "  linux systemd: sudo systemctl edit ollama  ->  Environment=\"OLLAMA_CONTEXT_LENGTH=$CTX\""
  warn "  (model.ollama_num_ctx below makes Hermes request $CTX per call regardless)"
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

# Hermes is an AGENT: it lives on native tool calling. But tool calling alone is
# not enough — the model must ALSO have a >=64K native window or agent init
# refuses it. These families satisfy both (all 128K native):
TOOL_FAMILIES="llama3.3 llama3.2 llama3.1 mistral-nemo mistral-large command-r devstral granite3.3 granite3.2 granite3.1"
tool_capable() { for f in $TOOL_FAMILIES; do case "$1" in "$f"*) return 0 ;; esac; done; return 1; }

# Tool-capable but PERMANENTLY under the 64K floor — never offer these.
# qwen2.5 = 32,768 native. qwen3 = 40,960 as Ollama ships it. granite3.0 = 4,096.
# mistral-small before 3.x = 32,768. Choosing one is the direct cause of
# "below the minimum 64,000 required by Hermes Agent".
too_small() {
  case "$1" in
    qwen2.5*|qwen2:*|qwen:*|qwen3*|granite3.0*|granite3:*|codellama*|phi3*|gemma2*) return 0 ;;
  esac
  return 1
}

# Ask Ollama what the model's real window is: model_info.*.context_length in
# /api/show is the GGUF training max — the same field Hermes itself probes.
# Two things this must survive: a 404 (model not pulled) and `set -o pipefail`,
# which otherwise turns a failed probe into a silent whole-script exit.
native_ctx() {
  { curl -fsS --max-time 8 "$OLLAMA_URL/api/show" \
      -H 'Content-Type: application/json' -d "{\"name\":\"$1\"}" 2>/dev/null || true; } \
    | tr ',' '\n' \
    | sed -n 's/.*"[^"]*context_length"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' \
    | sort -n | tail -1
}

INSTALLED="$(curl -fsS --max-time 5 "$OLLAMA_URL/api/tags" 2>/dev/null \
  | tr ',' '\n' \
  | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
if [ -n "$INSTALLED" ]; then
  echo "  already downloaded:"; echo "$INSTALLED" | sed 's/^/    - /'
else
  echo "  no models downloaded yet"
fi

# Size to RAM. Budget = Q4 weights + the 64K KV cache, which is NOT free:
# at q8_0 it costs roughly 2 GB (1B), 4 GB (3B), 4 GB (8B), 5 GB (12B),
# 5 GB (24B), 10 GB (70B). The old table ignored this and recommended 32B
# models on 32 GB boxes that then could not hold the window Hermes demands.
if   [ "$RAM_GB" -lt 8 ];  then SIZED="llama3.2:1b";     NOTE="wiring proof only — too small to be a useful agent"
elif [ "$RAM_GB" -lt 16 ]; then SIZED="llama3.2:3b";     NOTE="usable for simple tool calls; ~2 GB weights + ~4 GB window"
elif [ "$RAM_GB" -lt 24 ]; then SIZED="llama3.1:8b";     NOTE="the sweet spot for an agent brain; ~5 GB + ~4 GB window"
elif [ "$RAM_GB" -lt 48 ]; then SIZED="mistral-nemo:12b";NOTE="strong tool caller, 128K native; ~7 GB + ~5 GB window"
elif [ "$RAM_GB" -lt 64 ]; then SIZED="devstral:24b";    NOTE="very strong on code/tools; ~14 GB + ~5 GB window"
else                            SIZED="llama3.3:70b";    NOTE="~40 GB download + ~10 GB window"
fi

if [ -n "$MODEL" ]; then
  if too_small "$MODEL"; then
    die "'$MODEL' cannot run Hermes.
  Its native context window is under the hard 64,000-token minimum that
  hermes-agent enforces at startup (qwen2.5 = 32,768, qwen3 = 40,960).
  No config value can raise it — setting model.context_length higher just
  makes Ollama truncate silently and the agent still refuses to init.
  Pick a 128K model instead, e.g.:  --model $SIZED"
  fi
  tool_capable "$MODEL" || warn "'$MODEL' is not in a known tool-calling family — Hermes may fail to use tools"
else
  # Prefer something already on disk over a fresh multi-GB download,
  # but never reuse a model that cannot clear the 64K floor.
  MODEL=""
  for m in $INSTALLED; do
    too_small "$m" && continue
    if tool_capable "$m"; then MODEL="$m"; break; fi
  done
  if [ -n "$MODEL" ]; then ok "reusing downloaded tool-capable model: $MODEL"
  else MODEL="$SIZED"; ok "picked for ${RAM_GB} GB: $MODEL ($NOTE)"; fi
fi

if echo "$INSTALLED" | grep -qx "$MODEL"; then
  ok "$MODEL already present"
else
  step "Pulling $MODEL (this is the slow part)"
  run ollama pull "$MODEL"
fi

# Now that the weights are on disk, ask the GGUF itself rather than trusting
# the family name. This is the check that would have caught qwen2.5:32b.
if [ "$DRY" = 0 ]; then
  NATIVE="$(native_ctx "$MODEL")"
  if [ -z "$NATIVE" ]; then
    warn "could not read $MODEL's native context window from /api/show — continuing"
  elif [ "$NATIVE" -lt "$MIN_CTX" ]; then
    die "$MODEL advertises a native context window of $NATIVE tokens.
  hermes-agent refuses anything under 64,000 and will fail every agent init
  with 'below the minimum 64,000 required by Hermes Agent'.
  Pick a 128K model instead:  bash $0 --model $SIZED"
  else
    ok "$MODEL native context window: $NATIVE tokens (>= $MIN_CTX required)"
    if [ "$NATIVE" -lt "$CTX" ]; then
      warn "requested --ctx $CTX exceeds the model's $NATIVE — clamping to $NATIVE"
      CTX="$NATIVE"
    fi
  fi
fi

# ----------------------------- 7. config -----------------------------------
step "Pointing Hermes at local Ollama (HERMES_HOME=$HERMES_HOME)"

# There is no RAM-based tier here any more, and that is deliberate. The old
# script scaled num_ctx to 8192/16384/32768 — every one of those is under the
# 64,000 floor, so it configured a Hermes that could never start, on any
# machine. The window is not negotiable; the MODEL is what you scale to RAM.
NUM_CTX="$CTX"

if [ "$DRY" = 0 ] && [ ! -f "$HERMES_HOME/config.yaml" ]; then
  "$HERMES" setup --non-interactive >/dev/null 2>&1 || true
fi

# These keys are the verified Ollama wiring. provider 'custom' is the
# documented local path (aliases: ollama, local, vllm, llamacpp) and it also
# sends max_tokens, without which Ollama truncates at num_predict=128.
run "$HERMES" config set model.provider custom
run "$HERMES" config set model.base_url "$OLLAMA_URL/v1"
run "$HERMES" config set model.default "$MODEL"

# model.context_length is the one that actually fixes the startup rejection.
# In agent/model_metadata.py the resolver short-circuits on it before any probe
# ("0. Explicit config override — user knows best"), so this value is what the
# 64K guard in agent_init.py sees. Without it Hermes probes Ollama, gets
# whatever num_ctx the server happens to serve, and rejects the model.
run "$HERMES" config set model.context_length "$CTX"

# model.ollama_num_ctx is what Hermes puts on the wire per request, because
# Ollama otherwise defaults to a tiny window regardless of the GGUF. Note the
# direction of the interaction in agent_init.py: context_length CAPS an
# auto-detected num_ctx, it never raises it. Setting both to the same number
# is the only combination that is self-consistent.
run "$HERMES" config set model.ollama_num_ctx "$NUM_CTX"

if [ "$DRY" = 0 ]; then
  echo
  for k in model.provider model.base_url model.default model.context_length model.ollama_num_ctx; do
    printf '  %-24s = %s\n' "$k" "$("$HERMES" config get "$k" 2>/dev/null | tail -1)"
  done
  echo
  ok "config file: $("$HERMES" config path 2>/dev/null | tail -1)"
fi

# ------------------------- 7b. model switcher ------------------------------
# Switching models by hand is what keeps breaking: change model.default alone
# and the stale context_length from the previous model is still in config, so
# the next agent init fails. This helper moves all three together.
step "Installing the 'hermes-model' switcher at $HERMES_DIR/hermes-model"

if [ "$DRY" = 0 ]; then
  mkdir -p "$HERMES_DIR"
  cat > "$HERMES_DIR/hermes-model" <<SWITCHER
#!/usr/bin/env bash
# Switch the local Hermes brain: model + context_length + num_ctx, together.
#   hermes-model                 list installed models and their real windows
#   hermes-model llama3.1:8b     switch to it
set -euo pipefail
HERMES="$HERMES"
export HERMES_HOME="\${HERMES_HOME:-$HERMES_HOME}"
OLLAMA_URL="\${OLLAMA_URL:-$OLLAMA_URL}"
MIN_CTX=$MIN_CTX
[ -f "$HERMES_DIR/certs.env" ] && . "$HERMES_DIR/certs.env"

native_ctx() {
  { curl -fsS --max-time 8 "\$OLLAMA_URL/api/show" \\
      -H 'Content-Type: application/json' -d "{\\"name\\":\\"\$1\\"}" 2>/dev/null || true; } \\
    | tr ',' '\\n' \\
    | sed -n 's/.*"[^"]*context_length"[[:space:]]*:[[:space:]]*\\([0-9]\\{1,\\}\\).*/\\1/p' \\
    | sort -n | tail -1
}

if [ \$# -eq 0 ]; then
  echo "current: \$("\$HERMES" config get model.default 2>/dev/null | tail -1) @ \$("\$HERMES" config get model.context_length 2>/dev/null | tail -1) tokens"
  echo
  printf '%-28s %-10s %s\\n' MODEL WINDOW ''
  for m in \$({ curl -fsS --max-time 5 "\$OLLAMA_URL/api/tags" || true; } | tr ',' '\\n' \\
               | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p'); do
    n="\$(native_ctx "\$m")"; n="\${n:-?}"
    if [ "\$n" = "?" ]; then mark="unknown"
    elif [ "\$n" -lt "\$MIN_CTX" ]; then mark="TOO SMALL for Hermes (needs 64000+)"
    else mark="ok"; fi
    printf '%-28s %-10s %s\\n' "\$m" "\$n" "\$mark"
  done
  exit 0
fi

M="\$1"
N="\$(native_ctx "\$M")"
[ -n "\$N" ] || { echo "model '\$M' not found on \$OLLAMA_URL — run: ollama pull \$M" >&2; exit 1; }
if [ "\$N" -lt "\$MIN_CTX" ]; then
  echo "refusing: \$M has a \$N-token window; hermes-agent requires 64000+." >&2
  echo "this is the \"below the minimum 64,000\" error you keep hitting." >&2
  exit 1
fi
C="\${HERMES_CTX:-\$MIN_CTX}"; [ "\$N" -lt "\$C" ] && C="\$N"
"\$HERMES" config set model.default "\$M"
"\$HERMES" config set model.context_length "\$C"
"\$HERMES" config set model.ollama_num_ctx "\$C"
echo "switched to \$M @ \$C tokens (native \$N)"
echo "restart the gateway to pick it up:  \$HERMES dashboard --stop && \$HERMES dashboard"
SWITCHER
  chmod +x "$HERMES_DIR/hermes-model"
  ok "hermes-model installed — run it with no args to list windows"
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
  Window:   $CTX tokens  (model.context_length = model.ollama_num_ctx)

  Chat in the terminal:   $HERMES chat
  Dashboard:              $HERMES dashboard --host $DASH_HOST --port $DASH_PORT
  Health check:           $HERMES doctor
  Stop the dashboard:     $HERMES dashboard --stop
  Switch model safely:    $HERMES_DIR/hermes-model
  List model windows:     $HERMES_DIR/hermes-model            (no arguments)

  Put this in your shell rc so 'hermes' is always on PATH, so the gateway
  inherits the 64K window, and so TLS verification keeps working:

    export PATH="$VENV/bin:$HERMES_DIR:\$PATH"
    export OLLAMA_CONTEXT_LENGTH=$CTX
    export OLLAMA_FLASH_ATTENTION=1
    export OLLAMA_KV_CACHE_TYPE=q8_0
    [ -f "$HERMES_DIR/certs.env" ] && . "$HERMES_DIR/certs.env"

  If the dashboard ever says a model is "below the minimum 64,000": that is
  the model's own window, not a setting. Switch with hermes-model — never by
  editing model.default alone, which leaves a stale context_length behind.

EOF

if [ "$WANT_DASH" = 1 ] && [ "$DRY" = 0 ]; then
  step "Launching the dashboard on http://$DASH_HOST:$DASH_PORT"
  exec "$HERMES" dashboard --host "$DASH_HOST" --port "$DASH_PORT"
fi
