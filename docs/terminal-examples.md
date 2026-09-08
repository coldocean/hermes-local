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
  ✓ venv already exists — reusing it

==> Installing hermes-agent from PyPI
  ✓ installed: Hermes Agent v0.19.0 (2026.7.20)

==> Running hermes postinstall (node, browser, ripgrep, ffmpeg)
  ! pip cannot ship these; without them Hermes' tools are crippled
  would run: /home/user/hermes-local/venv/bin/hermes postinstall

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

==> Pointing Hermes at local Ollama (HERMES_HOME=/tmp/dryhome)
  would run: /home/user/hermes-local/venv/bin/hermes config set model.provider custom
  would run: /home/user/hermes-local/venv/bin/hermes config set model.base_url http://localhost:11434/v1
  would run: /home/user/hermes-local/venv/bin/hermes config set model.default llama3.2:1b
  would run: /home/user/hermes-local/venv/bin/hermes config set model.context_length 65536
  would run: /home/user/hermes-local/venv/bin/hermes config set model.ollama_num_ctx 65536

==> Installing the 'hermes-model' switcher at /home/user/hermes-local/hermes-model

==> Done
```

Two things to read out of that.

The **model** is sized to RAM: 3 GB → `llama3.2:1b`, with an honest warning that it's a wiring proof,
not a working agent. A 16 GB box gets `llama3.1:8b` instead.

The **window** is not. `context_length` and `ollama_num_ctx` are both 65536 on every machine, because
Hermes hard-refuses anything under 64,000 tokens. An earlier version of this script scaled the window
to RAM as well (8k / 16k / 32k) and never set `context_length` at all — which meant it produced a
Hermes that could not start, on any machine, every time.

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
model.default = llama3.1:8b

$ hermes config get model.context_length
model.context_length = 65536

$ hermes config get model.ollama_num_ctx
model.ollama_num_ctx = 65536

$ hermes config path
/home/user/hermes-local/testhome/config.yaml
```

Which lands in `config.yaml` as:

```yaml
model:
  provider: custom
  base_url: http://localhost:11434/v1
  default: llama3.1:8b
  context_length: 65536
  ollama_num_ctx: 65536
```

`context_length` is the one that matters — it short-circuits Hermes' context resolver before any
probing happens. `ollama_num_ctx` only sizes the KV cache Ollama allocates, and Hermes *caps* it by
`context_length`, never raises it. Set both, to the same number, or you get the 64K rejection in
session 7.

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
$ export OLLAMA_CONTEXT_LENGTH=65536
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

## 7. The 64K rejection, and getting out of it · expected shape

This is the error every local install hits first:

```console
$ hermes config set model.default qwen2.5:32b
model.default = qwen2.5:32b

$ hermes chat
agent init failed: Model qwen2.5:32b has a context window of 32,768 tokens,
which is below the minimum 64,000 required by Hermes Agent
```

That is not a setting you can turn down — `MINIMUM_CONTEXT_LENGTH = 64_000` is a constant in
`agent/model_metadata.py`, and 32,768 is qwen2.5's *native* window. The model can never pass. In the
dashboard the same failure looks like a gateway that restarts forever while claiming to be running:
each attempt fails in `agent_init`, the UI's websocket drops (`client_disconnect (1005)`) and
reconnects.

Use the switcher instead of `config set`, because it moves all three keys together:

```console
$ hermes-model
current: llama3.1:8b @ 65536 tokens

MODEL                        WINDOW
llama3.1:8b                  131072     ok
qwen2.5:32b                  32768      TOO SMALL for Hermes (needs 64000+)
mistral-nemo:12b             1024000    ok
llama3.2:1b                  131072     ok

$ hermes-model qwen2.5:32b
refusing: qwen2.5:32b has a 32768-token window; hermes-agent requires 64000+.
this is the "below the minimum 64,000" error you keep hitting.
$ echo $?
1

$ hermes-model mistral-nemo:12b
switched to mistral-nemo:12b @ 65536 tokens (native 1024000)
restart the gateway to pick it up:  ~/hermes-local/venv/bin/hermes dashboard --stop && ~/hermes-local/venv/bin/hermes dashboard

$ hermes-model nope:7b
model 'nope:7b' not found on http://localhost:11434 — run: ollama pull nope:7b
```

The WINDOW column is each model's *native* window, read from Ollama's `/api/show`. It is a property
of the weights — no config can raise it, which is why the fix is switching models, not tuning
numbers. Note the switch lands at 65536, not 1024000: `hermes-model` asks for 64K (override with
`HERMES_CTX`) and only clamps *down* if the model is smaller.

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
