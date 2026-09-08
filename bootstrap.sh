#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hermes Agent — local install, local Ollama brain.
#
#   bash bootstrap.sh                 # install + configure + open dashboard
#   bash bootstrap.sh --model llama3.1:8b
#   bash bootstrap.sh --ctx 131072    # cap the window (more RAM per token)
#   bash bootstrap.sh --no-dashboard
#   bash bootstrap.sh --no-agents     # skip the four sub-agent profiles
#   bash bootstrap.sh --dry-run       # print the plan, touch nothing
#   bash bootstrap.sh --keep-64k-guard  # leave hermes-agent's 64K floor alone
#
# THE 64K FLOOR — AND HOW THIS SCRIPT REMOVES IT. Stock hermes-agent refuses to
# start on any model whose context window is under 64,000 tokens
# (agent/model_metadata.py: MINIMUM_CONTEXT_LENGTH = 64_000, raised in
# agent/agent_init.py and agent/conversation_compression.py). That is what
# produces
#   "agent init failed: Model X has a context window of 32,768 tokens,
#    which is below the minimum 64,000 required by Hermes Agent"
# and it locks out plenty of usable local models (qwen2.5 = 32,768, qwen3 =
# 40,960 as Ollama ships it). This script runs scripts/unlock-context.py over
# your own install to drop the constant to 4096 and delete both raise sites, so
# ANY model is selectable. Windows are then set to each model's NATIVE size
# instead of a forced 65,536. Pass --keep-64k-guard to opt out.
#
# Re-run the unlock after any 'pip install --upgrade hermes-agent' / 'hermes
# update' — an upgrade rewrites site-packages and puts the floor back.
#
# FOUR SUB-AGENTS. Section 7c hands off to scripts/setup-agents.sh, which turns
# this one install into four specialists — researcher, planner, designer, coder
# — as hermes PROFILES. Each gets its own config.yaml (own model, own window),
# its own SOUL.md, its own skills, sessions, memories and workspace, all on the
# same venv and the same unlocked floor. They coordinate through hermes' shared
# kanban board. Pass --no-agents to skip it.
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
WANT_AGENTS=1
DRY=0
UNLOCK=1

# CTX is a CAP, not a target. Empty means "use whatever the model natively
# supports" — 32,768 for qwen2.5, 131,072 for llama3.1, 1,024,000 for
# mistral-nemo. Set --ctx / HERMES_CTX to clamp it down when RAM is tight;
# the KV cache is what a big window actually costs.
CTX="${HERMES_CTX:-}"

# Windows below this are legal after the unlock but genuinely tight: Hermes'
# system prompt + tool schemas are a large fixed prefix, so sessions compress
# early. Used for warnings only — nothing is refused.
TIGHT_CTX=64000

# Some models advertise a native window nobody can actually hold in RAM
# (mistral-nemo says 1,024,000). Without --ctx we default no higher than this;
# pass --ctx explicitly to go bigger.
SANE_MAX=131072

while [ $# -gt 0 ]; do
  case "$1" in
    --model)          MODEL="${2:?--model needs a value}"; shift 2 ;;
    --ctx)            CTX="${2:?--ctx needs a value}"; shift 2 ;;
    --port)           DASH_PORT="${2:?}"; shift 2 ;;
    --home)           export HERMES_HOME="${2:?}"; shift 2 ;;
    --dir)            HERMES_DIR="${2:?}"; VENV="$HERMES_DIR/venv"; shift 2 ;;
    --no-dashboard)   WANT_DASH=0; shift ;;
    --no-agents)      WANT_AGENTS=0; shift ;;
    --keep-64k-guard) UNLOCK=0; shift ;;
    --dry-run)        DRY=1; shift ;;
    -h|--help)        sed -n '2,39p' "$0"; exit 0 ;;
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

# Where scripts/unlock-context.py lives, relative to this script.
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
UNLOCK_PY="$SELF_DIR/scripts/unlock-context.py"
AGENTS_SH="$SELF_DIR/scripts/setup-agents.sh"

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

# --------------------------- 4c. unlock ------------------------------------
# Drop hermes-agent's MINIMUM_CONTEXT_LENGTH floor so any model is selectable.
# Runs AFTER pip and AFTER postinstall, because either can rewrite the files.
# Idempotent: a marker comment makes a second run a no-op, and
# `unlock-context.py --restore` puts site-packages back byte-for-byte.
unlock_context() {
  [ "$UNLOCK" = 1 ] || { warn "--keep-64k-guard: leaving the 64K floor in place"; return 0; }
  if [ ! -f "$UNLOCK_PY" ]; then
    warn "scripts/unlock-context.py not found next to this script ($UNLOCK_PY)"
    warn "  the 64K floor stays in force — models under 64K will be refused"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    echo "  would run: $VENV/bin/python $UNLOCK_PY"
    return 0
  fi
  if "$VENV/bin/python" "$UNLOCK_PY" 2>&1 | sed 's/^/  /'; then
    ok "context floor unlocked — any model window is now accepted"
    return 0
  fi
  # Auto-detection reads the interpreter's own sys.path. If that missed (odd
  # venv layout, python symlinked in from elsewhere), point it at the venv's
  # site-packages directly before giving up.
  for sp in "$VENV"/lib/python*/site-packages; do
    [ -f "$sp/agent/model_metadata.py" ] || continue
    if "$VENV/bin/python" "$UNLOCK_PY" --site-packages "$sp" 2>&1 | sed 's/^/  /'; then
      ok "context floor unlocked — any model window is now accepted"
      return 0
    fi
  done
  warn "unlock-context.py failed. hermes-agent may have changed shape;"
  warn "  the 64K floor is still in force. Run it by hand to see why:"
  warn "    $VENV/bin/python $UNLOCK_PY"
}

step "Removing hermes-agent's 64K minimum-context floor"
unlock_context

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
# hands Hermes a tiny window no matter what config.yaml says. These three env
# vars are what make a large KV cache both served and affordable: flash
# attention + q8_0 KV roughly halves the cache footprint.
#
# The serve-wide ceiling has to be set before 'ollama serve' starts, i.e.
# before we know which model gets picked, so it uses --ctx if given and 65,536
# otherwise. Per-request model.ollama_num_ctx (section 7) is the value that
# actually decides each call's window, and it is capped by this.
SERVE_CTX="${CTX:-65536}"
export OLLAMA_CONTEXT_LENGTH="$SERVE_CTX"
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
  warn "ollama was already running — it will NOT have picked up OLLAMA_CONTEXT_LENGTH=$SERVE_CTX."
  warn "  macOS app users: quit Ollama, then in a terminal run"
  warn "    OLLAMA_CONTEXT_LENGTH=$SERVE_CTX OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 ollama serve"
  warn "  linux systemd: sudo systemctl edit ollama  ->  Environment=\"OLLAMA_CONTEXT_LENGTH=$SERVE_CTX\""
  warn "  (a running server caps every request at its own ceiling, whatever model.ollama_num_ctx asks for)"
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

# Hermes is an AGENT: it lives on native tool calling. That is the one thing a
# model genuinely has to have — the context floor is gone, tool calling is not
# negotiable. These families all do native tool calls:
TOOL_FAMILIES="llama3.3 llama3.2 llama3.1 mistral-nemo mistral-large mistral-small command-r devstral granite3.3 granite3.2 granite3.1 qwen3 qwen2.5"
tool_capable() { for f in $TOOL_FAMILIES; do case "$1" in "$f"*) return 0 ;; esac; done; return 1; }

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

# Size to RAM. Budget = Q4 weights + the KV cache for the window you actually
# run, which is not free: at q8_0 a 32K window costs roughly 1-3 GB and 128K
# costs 4-10 GB depending on the model. Bigger model + smaller window is
# usually the better trade on a fixed amount of RAM.
if   [ "$RAM_GB" -lt 8 ];  then SIZED="llama3.2:1b";      NOTE="wiring proof only — too small to be a useful agent"
elif [ "$RAM_GB" -lt 16 ]; then SIZED="llama3.2:3b";      NOTE="usable for simple tool calls; ~2 GB weights"
elif [ "$RAM_GB" -lt 24 ]; then SIZED="llama3.1:8b";      NOTE="the sweet spot for an agent brain; ~5 GB weights, 128K native"
elif [ "$RAM_GB" -lt 32 ]; then SIZED="qwen2.5:14b";      NOTE="stronger reasoning; ~9 GB weights, 32K native"
elif [ "$RAM_GB" -lt 48 ]; then SIZED="qwen2.5:32b";      NOTE="strong local brain; ~20 GB weights, 32K native"
elif [ "$RAM_GB" -lt 64 ]; then SIZED="devstral:24b";     NOTE="very strong on code/tools; ~14 GB weights, 128K native"
else                            SIZED="llama3.3:70b";     NOTE="~40 GB download, 128K native"
fi

if [ -n "$MODEL" ]; then
  tool_capable "$MODEL" || warn "'$MODEL' is not in a known tool-calling family — Hermes may fail to use tools"
else
  # Prefer something already on disk over a fresh multi-GB download.
  MODEL=""
  for m in $INSTALLED; do
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

# Ask the GGUF itself rather than trusting the family name, then run the model
# at its NATIVE window — clamped down by --ctx / HERMES_CTX if you set one.
# Nothing here refuses a model any more; a small window only gets a warning.
# This runs in --dry-run too: the probe is a read-only GET, and resolving the
# real number here is what keeps the dry run from printing a placeholder where
# a token count belongs.
NATIVE=""
[ -x "$(command -v curl || true)" ] && NATIVE="$(native_ctx "$MODEL")"
if [ -z "$NATIVE" ]; then
  CTX="${CTX:-32768}"
  warn "could not read $MODEL's native window from /api/show — using $CTX"
else
  ok "$MODEL native context window: $NATIVE tokens"
  if [ -z "$CTX" ]; then
    if [ "$NATIVE" -gt "$SANE_MAX" ]; then
      CTX="$SANE_MAX"
      ok "native window is $NATIVE — using $CTX (pass --ctx $NATIVE to hold the whole thing)"
    else
      CTX="$NATIVE"
      ok "using the full native window: $CTX tokens"
    fi
  elif [ "$NATIVE" -lt "$CTX" ]; then
    warn "--ctx $CTX exceeds the model's $NATIVE — clamping to $NATIVE"
    CTX="$NATIVE"
  else
    ok "capping the window at your requested $CTX tokens (native $NATIVE)"
  fi
  if [ "$CTX" -lt "$TIGHT_CTX" ]; then
    warn "$CTX tokens is a tight window for an agent: Hermes' system prompt +"
    warn "  tool schemas are a large fixed prefix, so long sessions will start"
    warn "  compressing early. It works — the floor is unlocked — but expect it."
  fi
fi

# ----------------------------- 7. config -----------------------------------
step "Pointing Hermes at local Ollama (HERMES_HOME=$HERMES_HOME)"

# Both keys get the same number, and that number is the model's real window
# (section 6), not a fixed 65,536. With the floor unlocked there is nothing to
# satisfy — the only thing that matters is that config, the wire and the GGUF
# all agree, so Hermes' status bar and its compression threshold reflect the
# window Ollama is actually serving.
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

# model.context_length is the value Hermes trusts above everything else: in
# agent/model_metadata.py the resolver short-circuits on it before any probe
# ("0. Explicit config override — user knows best"). Set it and you decide the
# window; leave it out and Hermes takes whatever num_ctx the server happens to
# report, which is 4096 on a default Ollama.
run "$HERMES" config set model.context_length "$CTX"

# model.ollama_num_ctx is what Hermes puts on the wire per request, because
# Ollama otherwise defaults to a tiny window regardless of the GGUF. Note the
# direction of the interaction in agent_init.py: context_length CAPS an
# auto-detected num_ctx, it never raises it. Setting both to the same number
# is the only combination that is self-consistent, whatever size you pick.
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
# Hermes asks Ollama for a window the new model does not have. This helper
# moves all three keys together and never refuses a model — it warns.
step "Installing the 'hermes-model' switcher at $HERMES_DIR/hermes-model"

if [ "$DRY" = 0 ]; then
  mkdir -p "$HERMES_DIR"
  cat > "$HERMES_DIR/hermes-model" <<SWITCHER
#!/usr/bin/env bash
# Switch the local Hermes brain: model + context_length + num_ctx, together.
#   hermes-model                 list installed models and their real windows
#   hermes-model qwen2.5:32b     switch to it (any window — nothing is refused)
#   HERMES_CTX=16384 hermes-model qwen2.5:32b   switch and cap the window
set -euo pipefail
HERMES="$HERMES"
export HERMES_HOME="\${HERMES_HOME:-$HERMES_HOME}"
OLLAMA_URL="\${OLLAMA_URL:-$OLLAMA_URL}"
TIGHT_CTX=$TIGHT_CTX
SANE_MAX=$SANE_MAX
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
    elif [ "\$n" -lt "\$TIGHT_CTX" ]; then mark="tight — compresses early, but allowed"
    else mark="roomy"; fi
    printf '%-28s %-10s %s\\n' "\$m" "\$n" "\$mark"
  done
  exit 0
fi

M="\$1"
N="\$(native_ctx "\$M")"
[ -n "\$N" ] || { echo "model '\$M' not found on \$OLLAMA_URL — run: ollama pull \$M" >&2; exit 1; }
if [ -n "\${HERMES_CTX:-}" ]; then C="\$HERMES_CTX"
elif [ "\$N" -gt "\$SANE_MAX" ]; then C="\$SANE_MAX"
else C="\$N"; fi
[ "\$N" -lt "\$C" ] && C="\$N"
if [ "\$C" -lt "\$TIGHT_CTX" ]; then
  echo "note: \$M has a \$N-token window. That is tight for an agent — the system" >&2
  echo "      prompt + tool schemas eat a fixed chunk of it, so sessions compress" >&2
  echo "      early. Switching anyway; the 64K floor was patched out." >&2
fi
"\$HERMES" config set model.default "\$M"
"\$HERMES" config set model.context_length "\$C"
"\$HERMES" config set model.ollama_num_ctx "\$C"
echo "switched to \$M @ \$C tokens (native \$N)"
echo "restart the gateway to pick it up:  \$HERMES dashboard --stop && \$HERMES dashboard"
SWITCHER
  chmod +x "$HERMES_DIR/hermes-model"
  ok "hermes-model installed — run it with no args to list windows"
fi

# --------------------------- 7c. sub-agents --------------------------------
# One install, four specialists. hermes-agent already has the mechanism —
# profiles — and each profile carries its own config.yaml, so per-agent model
# and window are native, not a hack:
#     hermes -p coder config path -> $HERMES_HOME/profiles/coder/config.yaml
# They share this venv, this unlocked floor and one kanban board.
if [ "$WANT_AGENTS" = 1 ]; then
  step "Setting up the four sub-agents (researcher, planner, designer, coder)"
  if [ ! -f "$AGENTS_SH" ]; then
    warn "scripts/setup-agents.sh not found next to this script — skipping"
    warn "  clone the whole repo rather than downloading bootstrap.sh alone"
  else
    AGENT_ARGS=(--hermes "$HERMES" --dir "$HERMES_DIR" --home "$HERMES_HOME" --big "$MODEL")
    [ "$DRY" = 1 ] && AGENT_ARGS+=(--dry-run)
    # Never fatal: a working single-agent install is the important outcome.
    if OLLAMA_URL="$OLLAMA_URL" bash "$AGENTS_SH" "${AGENT_ARGS[@]}"; then
      ok "four agents provisioned — drive them with $HERMES_DIR/hermes-agents"
    else
      warn "sub-agent setup failed — the main install is fine; retry with:"
      warn "  bash $AGENTS_SH --hermes $HERMES --dir $HERMES_DIR"
    fi
  fi
else
  ok "skipping sub-agents (--no-agents). Add them later: bash $AGENTS_SH"
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

  Your four sub-agents:   $HERMES_DIR/hermes-agents           (no arguments)
  Talk to one:            $HERMES_DIR/hermes-agents chat coder
  Give one a task:        $HERMES_DIR/hermes-agents task researcher "compare X and Y"
  Split a goal up:        $HERMES_DIR/hermes-agents plan "ship the landing page"
  Start the dispatcher:   $HERMES_DIR/hermes-agents up

  Re-unlock after upgrading:  $VENV/bin/python $UNLOCK_PY
  Put the floor back:         $VENV/bin/python $UNLOCK_PY --restore
  Check patch state:          $VENV/bin/python $UNLOCK_PY --check

  Put this in your shell rc so 'hermes' is always on PATH, so the gateway
  inherits the window, and so TLS verification keeps working:

    export PATH="$VENV/bin:$HERMES_DIR:\$PATH"
    export OLLAMA_CONTEXT_LENGTH=$CTX
    export OLLAMA_FLASH_ATTENTION=1
    export OLLAMA_KV_CACHE_TYPE=q8_0
    [ -f "$HERMES_DIR/certs.env" ] && . "$HERMES_DIR/certs.env"

  The "below the minimum 64,000" rejection is patched out of this install, so
  any model is selectable. If it ever comes back, a 'pip install --upgrade
  hermes-agent' or 'hermes update' rewrote site-packages: re-run
  unlock-context.py. Still switch models with hermes-model rather than editing
  model.default alone, which leaves a stale context_length behind.

  The sub-agents are hermes profiles under $HERMES_HOME/profiles — each with
  its own config.yaml, SOUL.md, skills, sessions and memories. Cards on the
  shared board at $HERMES_HOME/kanban.db only move while a dispatcher runs:
  either 'hermes-agents up', or the dashboard, whose gateway embeds one.

EOF

if [ "$WANT_DASH" = 1 ] && [ "$DRY" = 0 ]; then
  step "Launching the dashboard on http://$DASH_HOST:$DASH_PORT"
  exec "$HERMES" dashboard --host "$DASH_HOST" --port "$DASH_PORT"
fi
