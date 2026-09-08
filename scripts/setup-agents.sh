#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Four sub-agents on top of the one local install.
#
#   bash scripts/setup-agents.sh                    # provision all four
#   bash scripts/setup-agents.sh --dry-run          # print the plan, touch nothing
#   bash scripts/setup-agents.sh --agents coder,planner
#   bash scripts/setup-agents.sh --fast llama3.2:3b --big qwen2.5:32b
#
# WHAT THIS ACTUALLY MAKES. Not four installs, not four servers, not four
# copies of Ollama. hermes-agent already has the thing we want: PROFILES.
#
#   hermes -p coder chat
#   hermes -p coder config path   ->  $HERMES_HOME/profiles/coder/config.yaml
#
# Each profile carries its OWN config.yaml (so its own model and window), its
# own SOUL.md (its own system prompt / persona), and its own skills, sessions,
# memories and workspace. One pip install, one venv, one 64K-floor unlock,
# four agents that inherit all of it.
#
# The agents are:
#   researcher  finds things out, checks sources, cites URLs
#   planner     turns a goal into ordered, verifiable steps
#   designer    interface, layout, copy, visual direction
#   coder       writes and edits code, runs it, fixes it
#
# HOW THEY TALK TO EACH OTHER. Through hermes' own kanban board — a SQLite
# task board at $HERMES_HOME/kanban.db, shared by every profile. Cards are
# claimed atomically, can depend on each other, and each one is executed by a
# named profile in an isolated workspace. That is why every profile here gets
# a --description: the kanban decomposer routes work by ROLE, reading those
# descriptions, not by guessing from the profile name.
#
# TWO MODELS, NOT FOUR. Ollama only keeps a limited number of models resident
# (OLLAMA_MAX_LOADED_MODELS; on CPU it is effectively one). Four distinct
# models means constant evict-and-reload thrash between agents. So by default
# researcher and planner share a small fast brain, designer and coder share
# the big one — and if only one model is on disk, all four share it rather
# than this script quietly starting a multi-gigabyte download. Override any
# single agent afterwards with:  hermes-agents model researcher llama3.2:3b
#
# Safe to re-run: existing profiles are updated in place, never recreated.
# Verified against hermes-agent 0.19.0 (pip) on Python 3.13.
# ---------------------------------------------------------------------------
set -euo pipefail

HERMES_DIR="${HERMES_DIR:-$HOME/hermes-local}"
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
HERMES="${HERMES:-}"
AGENTS="researcher,planner,designer,coder"
FAST=""
BIG=""
DRY=0
SANE_MAX=131072
TIGHT_CTX=64000

while [ $# -gt 0 ]; do
  case "$1" in
    --home)     export HERMES_HOME="${2:?}"; shift 2 ;;
    --dir)      HERMES_DIR="${2:?}"; shift 2 ;;
    --hermes)   HERMES="${2:?}"; shift 2 ;;
    --agents)   AGENTS="${2:?}"; shift 2 ;;
    --fast)     FAST="${2:?}"; shift 2 ;;
    --big)      BIG="${2:?}"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  sed -n '2,44p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; Z=""; fi
step() { printf '\n%s==>%s %s\n' "$B" "$Z" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; }
die()  { printf '\n  %sx%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------- locate hermes -------------------------------
if [ -z "$HERMES" ]; then
  if   [ -x "$HERMES_DIR/venv/bin/hermes" ]; then HERMES="$HERMES_DIR/venv/bin/hermes"
  elif have hermes;                          then HERMES="$(command -v hermes)"
  else die "no hermes binary found. Run bootstrap.sh first, or pass --hermes /path/to/hermes"; fi
fi
[ -x "$HERMES" ] || die "not executable: $HERMES"
ok "hermes: $HERMES"
ok "home:   $HERMES_HOME"

# ----------------------------- model windows -------------------------------
# Same read-only probe bootstrap.sh uses: ask the GGUF what window it has,
# rather than trusting the family name.
native_ctx() {
  { curl -fsS --max-time 8 "$OLLAMA_URL/api/show" \
      -H 'Content-Type: application/json' -d "{\"name\":\"$1\"}" 2>/dev/null || true; } \
    | tr ',' '\n' \
    | sed -n 's/.*"[^"]*context_length"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' \
    | sort -n | tail -1
}

window_for() {  # model -> window to configure, clamped like bootstrap does
  local n; n="$(native_ctx "$1")"
  if [ -z "$n" ]; then echo 32768; return; fi
  if [ -n "${HERMES_CTX:-}" ]; then
    if [ "$n" -lt "$HERMES_CTX" ]; then echo "$n"; else echo "$HERMES_CTX"; fi
  elif [ "$n" -gt "$SANE_MAX" ]; then echo "$SANE_MAX"
  else echo "$n"; fi
}

INSTALLED="$({ curl -fsS --max-time 5 "$OLLAMA_URL/api/tags" || true; } | tr ',' '\n' \
  | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

tool_capable() {
  case "$1" in
    llama3.1*|llama3.2*|llama3.3*|llama4*|qwen2.5*|qwen3*|qwq*|mistral*|mixtral*|devstral*|command-r*|firefunction*|hermes3*|nemotron*|granite3*|smollm2*) return 0 ;;
    *) return 1 ;;
  esac
}

step "Choosing brains"

# BIG defaults to whatever the main install is already pointed at — that model
# is on disk and already verified end to end.
if [ -z "$BIG" ]; then
  BIG="$("$HERMES" config get model.default 2>/dev/null | tail -1 || true)"
  BIG="$(printf '%s' "$BIG" | tr -d '[:space:]')"
fi
if [ -z "$BIG" ] || [ "$BIG" = "None" ]; then
  BIG="$(printf '%s\n' "$INSTALLED" | head -1)"
fi
[ -n "$BIG" ] || die "no model configured and none installed. Run bootstrap.sh first."
ok "deep brain (designer, coder): $BIG"

# FAST: only ever something ALREADY on disk. A setup script has no business
# starting a 5 GB download behind your back.
if [ -z "$FAST" ]; then
  for m in llama3.2:3b llama3.2:1b llama3.1:8b qwen2.5:7b qwen2.5:14b mistral:7b; do
    if printf '%s\n' "$INSTALLED" | grep -qx "$m" && [ "$m" != "$BIG" ]; then FAST="$m"; break; fi
  done
fi
if [ -z "$FAST" ]; then
  FAST="$BIG"
  warn "no smaller model on disk — researcher and planner will share $BIG"
  warn "  give them a faster brain later:"
  warn "    ollama pull llama3.2:3b && $HERMES_DIR/hermes-agents model researcher llama3.2:3b"
else
  tool_capable "$FAST" || warn "'$FAST' is not in a known tool-calling family — it may fail to use tools"
  ok "fast brain (researcher, planner): $FAST"
fi

BIG_CTX="$(window_for "$BIG")"
FAST_CTX="$(window_for "$FAST")"
ok "$BIG @ $BIG_CTX tokens · $FAST @ $FAST_CTX tokens"
[ "$BIG_CTX" -lt "$TIGHT_CTX" ] && warn "$BIG_CTX is a tight window — long sessions compress early (allowed, the floor is unlocked)"

# ----------------------------- role definitions ----------------------------
# description = what the kanban decomposer reads when routing a task.
# soul        = the profile's SOUL.md, i.e. its system prompt.
role_desc() {
  case "$1" in
    researcher) echo "Finds things out. Web search, documentation, source-checking, comparisons; returns facts with URLs and flags what it could not verify." ;;
    planner)    echo "Turns a goal into an ordered, verifiable plan. Breaks work into small dependent steps, defines done, and assigns each step to the right agent." ;;
    designer)   echo "Interface and product design. Layout, hierarchy, typography, colour, copy, and design critique of existing screens or pages." ;;
    coder)      echo "Writes, edits and debugs code. Reads the repo first, makes focused changes, runs the build and tests, and fixes what it breaks." ;;
    *)          echo "Local Hermes sub-agent." ;;
  esac
}

role_model() {
  case "$1" in
    researcher|planner) echo "$FAST" ;;
    *)                  echo "$BIG" ;;
  esac
}

role_ctx() {
  case "$1" in
    researcher|planner) echo "$FAST_CTX" ;;
    *)                  echo "$BIG_CTX" ;;
  esac
}

role_soul() {
  case "$1" in
    researcher) cat <<'SOUL'
You are the researcher on a small local agent team. Your job is to find things out and come back with something someone else can act on.

Work from primary sources. Search, open the actual page, and quote what it says rather than what you remember it saying — your own weights are stale and you know it. Every non-obvious claim carries the URL it came from. When sources disagree, say so and show both. When you cannot verify something, say "unverified" in plain words instead of hedging your way around it; a short honest answer beats a long confident wrong one.

Prefer recency for anything versioned, priced, released, or otherwise moving. Note the date of what you found.

Deliver findings as a short brief: the answer first, then the evidence, then what is still open. No preamble, no restating the question back. You are not the one who decides what to build — hand clean facts to the planner and stop there.
SOUL
    ;;
    planner) cat <<'SOUL'
You are the planner on a small local agent team. You turn a vague goal into a sequence someone can execute without asking you follow-up questions.

Start by pinning down what "done" means, in one sentence, testable. Then break the work into the smallest steps that each produce something verifiable. State dependencies explicitly — which step cannot start until which other step lands. Say who does each step: researcher for unknowns, designer for anything a person will look at, coder for anything that runs.

Call out the risky step. Every plan has one, and naming it up front is most of the value you add. If a goal depends on a fact nobody has checked, the first step is research, not implementation.

Keep plans short enough to hold in your head: if it needs more than about seven steps, the goal is really two goals — say that. Do not write code, do not design screens, do not pad the plan with process. Emit the plan and stop.
SOUL
    ;;
    designer) cat <<'SOUL'
You are the designer on a small local agent team. You decide what a thing looks like and how it reads, and you can defend every choice.

Hierarchy before decoration. Establish what the eye should hit first, second, third, then spend contrast, size and space to enforce that order. One type family with real weight range beats three families. A restrained palette — one accent that earns its place — beats a rainbow. Whitespace is structure, not leftover.

Copy is design. Rewrite the label, the empty state, the error message; the words carry more of the experience than the border radius does.

Give concrete, implementable direction: named colours, actual type scale, actual spacing steps, actual component states — not adjectives. When you critique an existing screen, lead with the single worst problem and what specifically to do about it, then the smaller ones. Say when something is already fine; redesigning working things is a cost, not a contribution.
SOUL
    ;;
    coder) cat <<'SOUL'
You are the coder on a small local agent team. You make changes that work on the machine, not changes that look right in a message.

Read before you write. Find how the codebase already does this thing and follow it — its conventions beat your preferences. Make the smallest change that solves the problem, in the fewest files. Do not refactor code you were not asked to touch, do not add dependencies to save three lines, do not leave commented-out fragments behind.

Then run it. Build, test, execute the actual path you changed. A change you have not run is a hypothesis, and reporting a hypothesis as a fix is the one thing that will actually lose the team's trust. If it fails, read the whole error, fix the cause rather than the symptom, and run it again.

Report honestly and briefly: what you changed, what you ran, what the output was, and anything you left broken or unverified. Handle errors and edge cases like they will happen, because locally they will.
SOUL
    ;;
    *) echo "You are a local Hermes sub-agent." ;;
  esac
}

# ----------------------------- provision -----------------------------------
step "Provisioning profiles in $HERMES_HOME/profiles"

BASE_URL="$("$HERMES" config get model.base_url 2>/dev/null | tail -1 || true)"
BASE_URL="$(printf '%s' "$BASE_URL" | tr -d '[:space:]')"
case "$BASE_URL" in http*) : ;; *) BASE_URL="$OLLAMA_URL/v1" ;; esac

MADE=""
IFS=',' read -r -a _agents <<< "$AGENTS"
for a in "${_agents[@]}"; do
  a="$(printf '%s' "$a" | tr -d '[:space:]')"
  [ -n "$a" ] || continue
  PDIR="$HERMES_HOME/profiles/$a"
  M="$(role_model "$a")"; C="$(role_ctx "$a")"

  if [ -d "$PDIR" ]; then
    ok "$a — exists, updating in place"
  else
    # --no-alias: without it, profile create drops a wrapper script into
    # ~/.local/bin and then warns that ~/.local/bin isn't on your PATH. The
    # hermes-agents controller covers the same ground without the surprise.
    run "$HERMES" profile create "$a" --no-alias --description "$(role_desc "$a")"
    ok "$a — created"
  fi

  # Description is what the kanban decomposer routes on. Re-assert it every
  # run so an edited role definition here actually reaches the board.
  run "$HERMES" profile describe "$a" --text "$(role_desc "$a")"

  # SOUL.md is the profile's system prompt. Stock creation seeds it with the
  # generic Hermes soul; that generic text is exactly what makes four profiles
  # behave like one agent wearing four name tags.
  if [ "$DRY" = 1 ]; then
    printf '  would write: %s\n' "$PDIR/SOUL.md"
  else
    mkdir -p "$PDIR"
    role_soul "$a" > "$PDIR/SOUL.md"
  fi

  run "$HERMES" -p "$a" config set model.provider custom
  run "$HERMES" -p "$a" config set model.base_url "$BASE_URL"
  run "$HERMES" -p "$a" config set model.default "$M"
  run "$HERMES" -p "$a" config set model.context_length "$C"
  run "$HERMES" -p "$a" config set model.ollama_num_ctx "$C"
  ok "$a -> $M @ $C tokens"
  MADE="$MADE $a"
done

# ----------------------------- kanban --------------------------------------
step "Initialising the shared task board"

if [ "$DRY" = 1 ]; then
  printf '  would run: %s kanban init\n' "$HERMES"
else
  if [ -f "$HERMES_HOME/kanban.db" ]; then
    ok "board already exists: $HERMES_HOME/kanban.db"
  else
    "$HERMES" kanban init >/dev/null 2>&1 || warn "kanban init returned non-zero — check '$HERMES kanban init'"
    [ -f "$HERMES_HOME/kanban.db" ] && ok "board created: $HERMES_HOME/kanban.db"
  fi
fi

# ----------------------------- controller ----------------------------------
step "Installing the 'hermes-agents' controller at $HERMES_DIR/hermes-agents"

if [ "$DRY" = 1 ]; then
  printf '  would write: %s/hermes-agents\n' "$HERMES_DIR"
else
mkdir -p "$HERMES_DIR"
cat > "$HERMES_DIR/hermes-agents" <<CTRL
#!/usr/bin/env bash
# One place to drive the four local sub-agents.
#
#   hermes-agents                      list agents, their brains and windows
#   hermes-agents chat coder           talk to one directly
#   hermes-agents model coder qwen2.5:32b   repoint one agent's brain
#   hermes-agents task coder "fix the build"   queue a card for one agent
#   hermes-agents plan "ship the landing page" decompose a goal across all four
#   hermes-agents swarm "audit the site"       parallel workers + verify + write-up
#   hermes-agents board                show the task board
#   hermes-agents up | down | status   run / stop / inspect the dispatcher
#   hermes-agents logs coder           tail one agent's log
set -euo pipefail
HERMES="$HERMES"
export HERMES_HOME="\${HERMES_HOME:-$HERMES_HOME}"
OLLAMA_URL="\${OLLAMA_URL:-$OLLAMA_URL}"
AGENTS="\${HERMES_AGENTS:-$(printf '%s' "$MADE" | sed 's/^ *//')}"
PIDFILE="$HERMES_DIR/.kanban-daemon.pid"
[ -f "$HERMES_DIR/certs.env" ] && . "$HERMES_DIR/certs.env"

known() { for a in \$AGENTS; do [ "\$a" = "\$1" ] && return 0; done; return 1; }
need()  { [ -n "\${1:-}" ] || { echo "which agent? one of: \$AGENTS" >&2; exit 2; }
          known "\$1" || { echo "unknown agent '\$1'. known: \$AGENTS" >&2; exit 2; }; }

native_ctx() {
  { curl -fsS --max-time 8 "\$OLLAMA_URL/api/show" \\
      -H 'Content-Type: application/json' -d "{\\"name\\":\\"\$1\\"}" 2>/dev/null || true; } \\
    | tr ',' '\\n' \\
    | sed -n 's/.*"[^"]*context_length"[[:space:]]*:[[:space:]]*\\([0-9]\\{1,\\}\\).*/\\1/p' \\
    | sort -n | tail -1
}

cmd="\${1:-list}"; shift || true
case "\$cmd" in
  list|ls|"")
    printf '%-12s %-22s %-9s %s\\n' AGENT BRAIN WINDOW ROLE
    for a in \$AGENTS; do
      m="\$("\$HERMES" -p "\$a" config get model.default 2>/dev/null | tail -1)"
      c="\$("\$HERMES" -p "\$a" config get model.context_length 2>/dev/null | tail -1)"
      d="\$(sed -n 's/^description:[[:space:]]*//p' "\$HERMES_HOME/profiles/\$a/profile.yaml" 2>/dev/null | head -1 | cut -c1-52)"
      printf '%-12s %-22s %-9s %s\\n' "\$a" "\${m:-?}" "\${c:-?}" "\$d"
    done
    echo
    echo "board: \$HERMES_HOME/kanban.db"
    ;;
  chat)     need "\${1:-}"; exec "\$HERMES" -p "\$1" chat ;;
  run)      need "\${1:-}"; a="\$1"; shift; exec "\$HERMES" -p "\$a" "\$@" ;;
  model)
    need "\${1:-}"; a="\$1"; m="\${2:?usage: hermes-agents model <agent> <model>}"
    n="\$(native_ctx "\$m")"
    [ -n "\$n" ] || { echo "model '\$m' not found on \$OLLAMA_URL — run: ollama pull \$m" >&2; exit 1; }
    c="\${HERMES_CTX:-\$n}"; [ "\$n" -lt "\$c" ] && c="\$n"
    [ "\$c" -gt $SANE_MAX ] && [ -z "\${HERMES_CTX:-}" ] && c=$SANE_MAX
    "\$HERMES" -p "\$a" config set model.default "\$m" >/dev/null
    "\$HERMES" -p "\$a" config set model.context_length "\$c" >/dev/null
    "\$HERMES" -p "\$a" config set model.ollama_num_ctx "\$c" >/dev/null
    echo "\$a -> \$m @ \$c tokens (native \$n)"
    echo "note: every distinct model you add is another one Ollama has to keep"
    echo "      resident — fewer distinct brains means less evict-and-reload."
    ;;
  soul)     need "\${1:-}"; exec \${EDITOR:-vi} "\$HERMES_HOME/profiles/\$1/SOUL.md" ;;
  task)
    need "\${1:-}"; a="\$1"; shift
    [ \$# -gt 0 ] || { echo 'usage: hermes-agents task <agent> "<title>"' >&2; exit 2; }
    "\$HERMES" kanban create "\$*" --assignee "\$a" --created-by hermes-agents
    echo "queued for \$a — run 'hermes-agents up' if the dispatcher isn't running"
    ;;
  plan)
    [ \$# -gt 0 ] || { echo 'usage: hermes-agents plan "<goal>"' >&2; exit 2; }
    id="\$("\$HERMES" kanban create "\$*" --triage --created-by hermes-agents --json 2>/dev/null \\
          | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)"
    [ -n "\$id" ] || { echo "could not create the card" >&2; exit 1; }
    echo "triage card \$id — decomposing across: \$AGENTS"
    "\$HERMES" kanban decompose "\$id" --author hermes-agents
    "\$HERMES" kanban list
    ;;
  swarm)
    [ \$# -gt 0 ] || { echo 'usage: hermes-agents swarm "<goal>"' >&2; exit 2; }
    "\$HERMES" kanban swarm "\$*" \\
      --worker researcher:"Research the ground truth" \\
      --worker designer:"Design direction and critique" \\
      --worker coder:"Implement and run it" \\
      --verifier planner --synthesizer planner --created-by hermes-agents
    ;;
  board|ls-tasks) exec "\$HERMES" kanban list "\$@" ;;
  show)     exec "\$HERMES" kanban show "\$@" ;;
  up)
    # The gateway hosts an embedded dispatcher (kanban.dispatch_in_gateway,
    # default true). If it is up, a standalone daemon would race it for
    # claims — which is exactly why 'kanban daemon' refuses to start without
    # --force while a gateway is available.
    if "\$HERMES" gateway status 2>/dev/null | grep -qi 'is running'; then
      echo "gateway is running — its embedded dispatcher already ticks the board"
      echo "nothing to start. 'hermes-agents status' to watch it."
      exit 0
    fi
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
      echo "dispatcher already running (pid \$(cat "\$PIDFILE"))"; exit 0
    fi
    rm -f "\$PIDFILE"
    nohup "\$HERMES" kanban daemon --force --interval "\${KANBAN_INTERVAL:-30}" \\
      --pidfile "\$PIDFILE" >>"$HERMES_DIR/kanban-daemon.log" 2>&1 &
    sleep 2
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
      echo "dispatcher up (pid \$(cat "\$PIDFILE"), tick \${KANBAN_INTERVAL:-30}s)"
      echo "log: $HERMES_DIR/kanban-daemon.log"
    else
      echo "dispatcher did NOT stay up — last lines of the log:" >&2
      tail -12 "$HERMES_DIR/kanban-daemon.log" >&2 || true
      exit 1
    fi
    ;;
  down)
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
      kill "\$(cat "\$PIDFILE")" && rm -f "\$PIDFILE" && echo "dispatcher stopped"
    else echo "not running"; fi
    ;;
  status)
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
      echo "dispatcher: running (pid \$(cat "\$PIDFILE"))"
    else echo "dispatcher: stopped  —  start it with: hermes-agents up"; fi
    echo
    "\$HERMES" kanban assignees 2>/dev/null || true
    echo
    "\$HERMES" kanban stats 2>/dev/null || true
    ;;
  logs)
    need "\${1:-}"
    f="\$HERMES_HOME/profiles/\$1/logs/agent.log"
    [ -f "\$f" ] || f="\$HERMES_HOME/logs/agent.log"
    exec tail -f "\$f"
    ;;
  -h|--help|help) sed -n '2,12p' "\$0" ;;
  *) echo "unknown command '\$cmd' — try: hermes-agents --help" >&2; exit 2 ;;
esac
CTRL
chmod +x "$HERMES_DIR/hermes-agents"
ok "hermes-agents installed"
fi

# ----------------------------- done ----------------------------------------
step "Done"
cat <<EOF

  Agents:   $(printf '%s' "$MADE" | sed 's/^ *//')
  Profiles: $HERMES_HOME/profiles/<name>/   (config.yaml · SOUL.md · skills · sessions · memories)
  Board:    $HERMES_HOME/kanban.db          (shared by all of them)

  List them:              $HERMES_DIR/hermes-agents
  Talk to one:            $HERMES_DIR/hermes-agents chat coder
  Queue one card:         $HERMES_DIR/hermes-agents task researcher "compare X and Y"
  Split a goal:           $HERMES_DIR/hermes-agents plan "ship the landing page"
  Start the dispatcher:   $HERMES_DIR/hermes-agents up
  Edit a persona:         $HERMES_DIR/hermes-agents soul designer

  Nothing on the board moves on its own. Either run 'hermes-agents up' (a
  standalone dispatcher) or leave the dashboard running — the gateway hosts
  an embedded dispatcher that ticks every kanban.dispatch_interval_seconds.

  Each agent runs on the same unlocked install, so a 32K model like
  qwen2.5:32b is selectable for any of them. Adding a THIRD distinct model is
  the point where Ollama starts evicting one to load another on every handoff.

EOF
