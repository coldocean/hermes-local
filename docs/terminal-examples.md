# Terminal examples

Sessions below marked **captured** are real output from a live `hermes-agent 0.19.0` pip install.
Sessions marked **expected shape** depend on your own machine (RAM, OS, downloaded models), so the
values will differ — the structure won't.

---

## 1. Dry run — the whole plan, nothing touched · captured

```console
$ bash bootstrap.sh --dry-run --no-dashboard

==> Inspecting this machine
  ✓ os: linux (x86_64)
  ✓ ram: 3 GB

==> Locating Python 3.11–3.13 (hermes-agent requires >=3.11,<3.14)
  ✓ python: python3.13 (3.13)

==> Creating the virtualenv at /home/user/hermes-local/venv
  would run: mkdir -p /home/user/hermes-local
  would run: python3.13 -m venv /home/user/hermes-local/venv
  ✓ venv ready

==> Installing hermes-agent from PyPI
  would run: /home/user/hermes-local/venv/bin/pip install --upgrade pip
  would run: /home/user/hermes-local/venv/bin/pip install hermes-agent

==> Running hermes postinstall (node, browser, ripgrep, ffmpeg)
  ! pip cannot ship these; without them Hermes' tools are crippled
  would run: /home/user/hermes-local/venv/bin/hermes postinstall

==> Removing hermes-agent's 64K minimum-context floor
  would run: /home/user/hermes-local/venv/bin/python scripts/unlock-context.py

==> Checking TLS root certificates
  would run: pip install --upgrade certifi; verify https reachability

==> Setting up Ollama
  ! ollama not found — installing
  would run: sh -c curl -fsSL https://ollama.com/install.sh | sh
  would run: ollama serve &

==> Choosing a model
  no models downloaded yet
  ✓ picked for 3 GB: llama3.2:1b (wiring proof only — too small to be a useful agent)

==> Pulling llama3.2:1b (this is the slow part)
  would run: ollama pull llama3.2:1b
  ! could not read llama3.2:1b's native window from /api/show — using 32768

==> Pointing Hermes at local Ollama (HERMES_HOME=/tmp/dryhome)
  would run: /home/user/hermes-local/venv/bin/hermes config set model.provider custom
  would run: /home/user/hermes-local/venv/bin/hermes config set model.base_url http://localhost:11434/v1
  would run: /home/user/hermes-local/venv/bin/hermes config set model.default llama3.2:1b
  would run: /home/user/hermes-local/venv/bin/hermes config set model.context_length 32768
  would run: /home/user/hermes-local/venv/bin/hermes config set model.ollama_num_ctx 32768

==> Installing the 'hermes-model' switcher at /home/user/hermes-local/hermes-model

==> Done
```

Three things to read out of that.

The **model** is sized to RAM: 3 GB → `llama3.2:1b`, with an honest warning that it's a wiring proof,
not a working agent. A 16 GB box gets `llama3.1:8b` instead.

The **64K floor gets patched out** right after the install — that's session 7. Without it, half the
useful local models can't start at all.

The **window** follows the model. It's read from Ollama's `/api/show` and used as-is, capped at
131,072 unless you pass `--ctx`. Here the dry run couldn't reach Ollama (nothing is installed yet),
so it falls back to 32,768 and says so. On a real run against a live server you'd see
`llama3.2:1b native context window: 131072 tokens`. `context_length` and `ollama_num_ctx` always move
together — Hermes caps the second by the first, so a mismatch silently shrinks your window.

---

## 2. Version check · captured

```console
$ hermes --version
Hermes Agent v0.19.0 (2026.7.20)
Install directory: /home/user/hermes-local/venv/lib/python3.13/site-packages
Install method: pip
Python: 3.13.5
OpenAI SDK: 2.24.0
```

`Install method: pip` is how you know you're on the local install and not talking to a container.

---

## 3. The Ollama wiring, read back · expected shape

```console
$ hermes config get model.provider
model.provider = custom

$ hermes config get model.base_url
model.base_url = http://localhost:11434/v1

$ hermes config get model.default
model.default = qwen2.5:32b

$ hermes config get model.context_length
model.context_length = 32768

$ hermes config get model.ollama_num_ctx
model.ollama_num_ctx = 32768

$ hermes config path
/home/user/hermes-local/testhome/config.yaml
```

Which lands in `config.yaml` as:

```yaml
model:
  provider: custom
  base_url: http://localhost:11434/v1
  default: qwen2.5:32b
  context_length: 32768
  ollama_num_ctx: 32768
```

Both numbers are the model's *native* window, read from Ollama's `/api/show`. `context_length` is
the one that matters — it short-circuits Hermes' context resolver before any probing happens.
`ollama_num_ctx` only sizes the KV cache Ollama allocates, and Hermes *caps* it by `context_length`,
never raises it. Set both, to the same number. Under stock hermes-agent a 32,768 window would be
refused outright; session 7 is how that floor gets removed.

---

## 4. What `postinstall` is for · captured

```console
$ hermes postinstall --help
usage: hermes postinstall [-h]

One-shot post-install for pip users. Installs system dependencies that pip
cannot provide, then runs setup if needed.
```

Skip this and search, browsing and media tools silently do nothing. It is not optional.

---

## 5. Proving the round-trip yourself · expected shape

```console
$ curl -s http://localhost:11434/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"llama3.1:8b","max_tokens":32,
         "messages":[{"role":"user","content":"reply with the single word: ready"}]}' \
  | python3 -m json.tool
{
    "choices": [
        {
            "message": { "role": "assistant", "content": "ready" },
            "finish_reason": "stop"
        }
    ]
}
```

`bootstrap.sh` runs exactly this at the end. If `content` comes back empty you're on a reasoning
model burning its budget; if it stops mid-sentence, `max_tokens` isn't reaching Ollama.

---

## 6. Everyday commands · expected shape

```console
$ export PATH="$HOME/hermes-local/venv/bin:$PATH"
$ export OLLAMA_CONTEXT_LENGTH=32768      # match your model's window
$ export OLLAMA_FLASH_ATTENTION=1
$ export OLLAMA_KV_CACHE_TYPE=q8_0
$ [ -f "$HOME/hermes-local/certs.env" ] && . "$HOME/hermes-local/certs.env"

$ hermes chat                      # terminal agent, local brain
$ hermes dashboard --host 127.0.0.1
  dashboard → http://127.0.0.1:9119
$ hermes dashboard --status
$ hermes dashboard --stop
$ hermes doctor                    # add --fix to repair
$ hermes status
$ ollama list                      # what weights you actually have
$ hermes-model                     # list installed models + their real windows
```

The three `OLLAMA_*` exports have to be in the environment **`ollama serve` itself** was started
from, not just your shell. On macOS the menubar app inherits nothing — quit it and run `ollama serve`
from a terminal that has them, or the KV cache stays at the 4096 default and a 64K request gets
silently truncated.

---

## 7. Removing the 64K floor · captured (patch) / stub Ollama (switcher)

Stock Hermes refuses any model under 64,000 tokens, which rules out qwen2.5 (32,768) forever:

```console
$ hermes config set model.default qwen2.5:32b
model.default = qwen2.5:32b

$ hermes chat
agent init failed: Model qwen2.5:32b has a context window of 32,768 tokens,
which is below the minimum 64,000 required by Hermes Agent
```

In the dashboard the same failure looks like a gateway that restarts forever while claiming to be
running: each attempt fails in `agent_init`, the UI's websocket drops (`client_disconnect (1005)`)
and reconnects.

The window is a property of the weights, so it can't be raised. The constant can. This is real
output against a pip install of `hermes-agent 0.19.0`:

```console
$ ./venv/bin/python scripts/unlock-context.py --check
hermes-agent at: /tmp/hv/lib/python3.13/site-packages

  stock    agent/model_metadata.py
  stock    agent/agent_init.py
  stock    agent/conversation_compression.py
  stock    run_agent.py

live MINIMUM_CONTEXT_LENGTH = 64000
$ echo $?
1

$ ./venv/bin/python scripts/unlock-context.py
hermes-agent at: /tmp/hv/lib/python3.13/site-packages

  patched  agent/model_metadata.py
  patched  agent/agent_init.py
  patched  agent/conversation_compression.py
  patched  run_agent.py

64K floor removed. MINIMUM_CONTEXT_LENGTH is now 4096.
Any model is selectable — Hermes will no longer refuse a small window.
Trade-off: a 32K window still has to hold the system prompt + tool
schemas, so long sessions compress earlier and more often.
```

Run it twice and nothing happens — a marker comment makes it idempotent:

```console
$ ./venv/bin/python scripts/unlock-context.py
hermes-agent at: /tmp/hv/lib/python3.13/site-packages

  ok       agent/model_metadata.py (already patched)
  ok       agent/agent_init.py (already patched)
  ok       agent/conversation_compression.py (already patched)
  ok       run_agent.py (already patched)

Nothing to do — already unlocked.
```

Every touched file is backed up to `<file>.hermes-local.orig` first, so it's reversible:

```console
$ ./venv/bin/python scripts/unlock-context.py --restore
hermes-agent at: /tmp/hv/lib/python3.13/site-packages

  restored agent/model_metadata.py
  restored agent/agent_init.py
  restored agent/conversation_compression.py
  restored run_agent.py

4 file(s) restored. The 64K floor is back in force.
```

`bootstrap.sh` runs the patch for you after pip and after `postinstall`. **Re-run it after every
`hermes update` or `pip install --upgrade hermes-agent`** — an upgrade rewrites site-packages and
restores the floor.

With the floor gone, the switcher stops refusing things. Output below is the real script talking to
a stub Ollama, so the model list is a fixture:

```console
$ hermes-model
current: qwen2.5:32b @ 32768 tokens

MODEL                        WINDOW
llama3.1:8b                  131072     roomy
qwen2.5:32b                  32768      tight — compresses early, but allowed
mistral-nemo:12b             1024000    roomy
llama3.2:1b                  131072     roomy

$ hermes-model qwen2.5:32b
note: qwen2.5:32b has a 32768-token window. That is tight for an agent — the system
      prompt + tool schemas eat a fixed chunk of it, so sessions compress
      early. Switching anyway; the 64K floor was patched out.
switched to qwen2.5:32b @ 32768 tokens (native 32768)
restart the gateway to pick it up:  ~/hermes-local/venv/bin/hermes dashboard --stop && ~/hermes-local/venv/bin/hermes dashboard
$ echo $?
0

$ HERMES_CTX=16384 hermes-model qwen2.5:32b
note: qwen2.5:32b has a 32768-token window. That is tight for an agent — the system
      prompt + tool schemas eat a fixed chunk of it, so sessions compress
      early. Switching anyway; the 64K floor was patched out.
switched to qwen2.5:32b @ 16384 tokens (native 32768)

$ hermes-model mistral-nemo:12b
switched to mistral-nemo:12b @ 131072 tokens (native 1024000)

$ hermes-model nope:7b
model 'nope:7b' not found on http://localhost:11434 — run: ollama pull nope:7b
$ echo $?
1
```

The WINDOW column is each model's *native* window from `/api/show`. Two things the switcher still
does: it moves `model.default`, `model.context_length` and `model.ollama_num_ctx` together (changing
one alone is what makes switching feel cursed), and it never asks for more than the model has.
`mistral-nemo` lands at 131,072 rather than its advertised 1,024,000 — that is the sanity cap; pass
`HERMES_CTX=1024000` if you really want to try holding it.

---

## 8. The log lines that look fatal and aren't · captured (macOS install)

```console
$ tail -f ~/.hermes/logs/agent.log
hermes_cli.model_catalog: model catalog fetch failed: certificate verify failed:
  unable to get local issuer certificate (_ssl.c:1020)
agent.agent_init: Auxiliary Nous client unavailable: no Nous authentication found
agent.model_registry: marking opencoder unhealthy for 60s (payment / credit error)
agent.agent_init: check_vision_requirements returned False
agent.agent_init: check_web_api_key returned False
```

Only the first one matters. A python.org build on macOS ships without root certificates, so the model
catalog never loads, so Hermes can't look up a model's true context window and falls back to whatever
the endpoint reports. Fix it once:

```console
$ ~/hermes-local/venv/bin/pip install --upgrade certifi
$ /Applications/Python\ 3.13/Install\ Certificates.command
```

The other four are Hermes noticing you have no cloud account, no vision model and no web-search key —
which is the entire point of running local.

---

## 9. Porting profiles from another install · expected shape

```console
# on the source machine
$ hermes profile export coding
# on this machine
$ hermes profile import ./coding.hermesprofile
```

A fresh local install starts empty — profiles, souls and skill selections do not travel on their own.

---

## 10. Four sub-agents on one install · captured (stub Ollama)

Provisioning. Four hermes profiles, two brains, one shared board:

```console
$ bash scripts/setup-agents.sh
  ✓ hermes: ~/hermes-local/venv/bin/hermes
  ✓ home:   ~/.hermes

==> Choosing brains
  ✓ deep brain (designer, coder): llama3.1:8b
  ✓ fast brain (researcher, planner): llama3.2:1b
  ✓ llama3.1:8b @ 131072 tokens · llama3.2:1b @ 131072 tokens

==> Provisioning profiles in ~/.hermes/profiles
  ✓ researcher — created
✓ Set model.default = llama3.2:1b in ~/.hermes/profiles/researcher/config.yaml
✓ Set model.context_length = 131072 in ~/.hermes/profiles/researcher/config.yaml
  ✓ researcher -> llama3.2:1b @ 131072 tokens
  ...
  ✓ coder -> llama3.1:8b @ 131072 tokens

==> Initialising the shared task board
  ✓ board created: ~/.hermes/kanban.db

==> Installing the 'hermes-agents' controller at ~/hermes-local/hermes-agents
  ✓ hermes-agents installed
```

The whole design rests on one fact — a profile owns its own config file, so
per-agent model and window need no invention:

```console
$ hermes -p coder config path
~/.hermes/profiles/coder/config.yaml

$ cat ~/.hermes/profiles/coder/config.yaml
model:
  provider: custom
  base_url: http://localhost:11434/v1
  default: llama3.1:8b
  context_length: 131072
  ollama_num_ctx: 131072
```

Who they are:

```console
$ hermes-agents
AGENT        BRAIN                  WINDOW    ROLE
researcher   llama3.2:1b            131072    Finds things out. Web search, documentation, source-
planner      llama3.2:1b            131072    Turns a goal into an ordered, verifiable plan. Break
designer     llama3.1:8b            131072    Interface and product design. Layout, hierarchy, typ
coder        llama3.1:8b            131072    Writes, edits and debugs code. Reads the repo first,

board: ~/.hermes/kanban.db
```

The ROLE column is each profile's `--description`, and it is not decoration:
the kanban decomposer routes tasks by reading it, rather than guessing from
the profile name.

Repointing one brain moves all three keys together, the same way `hermes-model`
does for the main install — and says out loud what a third distinct model costs:

```console
$ hermes-agents model researcher qwen2.5:32b
researcher -> qwen2.5:32b @ 32768 tokens (native 32768)
note: every distinct model you add is another one Ollama has to keep
      resident — fewer distinct brains means less evict-and-reload.
```

32,768 is accepted without argument. On a stock install that model is refused
outright — see session 7.

Queueing work and watching the board:

```console
$ hermes-agents task researcher "compare qwen2.5:32b and llama3.1:8b for tool calling"
Created t_d944b3dd  (ready, assignee=researcher)
queued for researcher — run 'hermes-agents up' if the dispatcher isn't running

$ hermes-agents board
▶ t_d944b3dd  ready     researcher            compare qwen2.5:32b and llama3.1:8b for tool calling

$ hermes-agents status
dispatcher: stopped  —  start it with: hermes-agents up

NAME                  ON DISK   COUNTS
coder                 yes       (idle)
designer              yes       (idle)
planner               yes       (idle)
researcher            yes       ready=1

By status:
  ready     1
  running   0
  blocked   0
  done      0

Oldest ready task age: 1s
```

A card sitting in `ready` forever is the single most common surprise here:
nothing on the board moves without a dispatcher.

```console
$ hermes-agents up
dispatcher up (pid 10258, tick 30s)
log: ~/hermes-local/kanban-daemon.log

$ hermes-agents up
dispatcher already running (pid 10258)

$ hermes-agents down
dispatcher stopped
```

`up` checks for a running gateway first and bows out if it finds one — the
gateway embeds its own dispatcher, and two dispatchers race for claims. It also
re-reads the pidfile after starting rather than assuming: if the daemon exits,
you get the tail of its log and a non-zero exit, not a cheerful lie.

What actually makes them four different agents is `SOUL.md` — the profile's
system prompt. Stock profile creation seeds it with the generic Hermes soul,
which is exactly what would leave you with one agent wearing four name tags:

```console
$ head -3 ~/.hermes/profiles/coder/SOUL.md
You are the coder on a small local agent team. You make changes that work on
the machine, not changes that look right in a message.

Read before you write. Find how the codebase already does this thing and follow
it — its conventions beat your preferences. Make the smallest change that solves
the problem, in the fewest files.

$ hermes-agents soul designer      # opens $EDITOR on that file
```
