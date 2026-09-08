# hermes-local

Run **Hermes Agent** on your own machine, with **Ollama** as the brain. No Docker, no cloud API key, no Groq.

One command:

```bash
bash bootstrap.sh
```

It detects your OS and RAM, installs Hermes from PyPI into a virtualenv, installs the system tools pip can't ship, installs and starts Ollama, pulls a model that actually fits your RAM, wires the two together, proves the round-trip works, and opens the dashboard.

Safe to re-run — every step checks before it acts.

See [docs/terminal-examples.md](docs/terminal-examples.md) for real captured terminal sessions.

---

## Requirements

| | |
|---|---|
| OS | macOS, Linux, or Windows **inside WSL2** |
| Python | 3.11, 3.12 or 3.13 (`hermes-agent` requires `>=3.11,<3.14`) |
| RAM | 8 GB minimum to be useful, 16 GB+ for a good agent |
| Disk | 5–45 GB depending on model |
| Network | for the installs and the model pull only — after that it runs fully offline |

Windows: install WSL2 (`wsl --install`), open Ubuntu, run the script there. Native PowerShell is not supported.

## Flags

```bash
bash bootstrap.sh --dry-run              # print the whole plan, change nothing
bash bootstrap.sh --model llama3.1:8b    # override the auto-sized model
bash bootstrap.sh --ctx 131072           # bigger context window (costs RAM)
bash bootstrap.sh --no-dashboard         # install and configure only
bash bootstrap.sh --port 9200            # dashboard port (default 9119)
bash bootstrap.sh --dir ~/hermes-local   # where the venv lives
bash bootstrap.sh --home ~/.hermes       # HERMES_HOME (config + data)
```

Environment overrides: `HERMES_DIR`, `HERMES_HOME`, `OLLAMA_URL`, `DASH_PORT`, `DASH_HOST`, `HERMES_CTX`.

---

## The thing that will bite you first: the 64K rule

Hermes refuses to start on any model whose context window is under **64,000 tokens**. It is a hard constant, not a preference:

```python
# agent/model_metadata.py
MINIMUM_CONTEXT_LENGTH = 64_000

# agent/agent_init.py — raised during every agent init
if _ctx and _ctx < MINIMUM_CONTEXT_LENGTH:
    raise ValueError(...)
```

That check is what produces the error everyone hits:

```
agent init failed: Model qwen2.5:32b has a context window of 32,768 tokens,
which is below the minimum 64,000 required by Hermes Agent
```

Three consequences, and they explain nearly every "it says it's running but nothing works" report:

**1. Half the popular Ollama models can never pass.** The window is a property of the weights, not a setting.

| Model | Native window | Usable with Hermes |
|---|---|---|
| `qwen2.5:*` | 32,768 | never |
| `qwen3:*` | 40,960 as Ollama ships it | never |
| `gemma2`, `phi3`, `granite3.0` | ≤ 8,192 | never |
| `llama3.1` / `3.2` / `3.3` | 131,072 | yes |
| `mistral-nemo`, `devstral`, `command-r` | 128,000+ | yes |

**2. You must set `model.context_length`, not just `ollama_num_ctx`.** In `model_metadata.py` the context resolver short-circuits on the config value before any probe runs — comment in the source: *"0. Explicit config override — user knows best"*. It is the number the 64K guard actually sees. Leave it unset and Hermes probes Ollama, gets whatever `num_ctx` the server serves (default 4096), and rejects the model.

**3. `context_length` caps `ollama_num_ctx`, it never raises it.** From `agent_init.py`: an auto-detected `num_ctx` larger than your `context_length` gets clamped down. So the two must be **the same number**. Setting one alone is the classic half-fix that leaves you exactly where you started.

The script pins both to 65,536 and refuses to configure a model that can't honestly reach it.

## The second thing: tool calling

Hermes is an **agent**, not a chatbot. It only works with models that support **native tool calling**. Pick a model without it and Hermes will look broken no matter how much RAM you have.

A model has to clear **both** bars — native tool calling **and** a ≥64K window. These clear both, and they're the only families the script will auto-pick:

**Works:** `llama3.3`, `llama3.2`, `llama3.1`, `mistral-nemo`, `mistral-large`, `command-r`, `devstral`, `granite3.1`+

**Tool calling, but under 64K — rejected by name:** `qwen2.5`, `qwen3`, `granite3.0`, `mistral-small` before 3.x

**No tool calling at all:** `gemma` / `gemma2` / `gemma3`, older `phi`, `deepseek-coder` base, any plain completion model

The script warns you if `--model` isn't in a known tool-calling family, and hard-fails if it's under the window floor.

## Model sizing

The old version of this table sized only the weights, which is how you end up with a 32B model on a 32 GB box that then can't hold the window Hermes demands. **The 64K KV cache is not free** — it costs GB on top of the weights. Budget for both:

| Your RAM | Auto-picked | Weights (Q4) | 64K window (q8_0 KV) | Verdict |
|---|---|---|---|---|
| < 8 GB | `llama3.2:1b` | ~0.8 GB | ~1 GB | wiring proof only — too weak to be an agent |
| 8–15 GB | `llama3.2:3b` | ~2 GB | ~4 GB | simple tool calls |
| 16–23 GB | `llama3.1:8b` | ~5 GB | ~4 GB | **sweet spot** |
| 24–47 GB | `mistral-nemo:12b` | ~7 GB | ~5 GB | strong, 128K native |
| 48–63 GB | `devstral:24b` | ~14 GB | ~5 GB | very strong on code + tools |
| 64 GB+ | `llama3.3:70b` | ~40 GB | ~10 GB | best local option |

If you already have a tool-capable model downloaded **that clears 64K**, the script reuses it instead of pulling gigabytes again. A downloaded `qwen2.5` is skipped, not reused.

> **There is no 120B option here.** `gpt-oss-120b` needs ~60 GB+ of RAM. And Groq isn't a model you can download — it's a cloud provider with custom silicon. Local means local.

The window is **not** scaled to your RAM. It can't be — anything under 64K is a Hermes that cannot start. The *model* is what you scale. To make 64K affordable the script turns on flash attention and a quantised KV cache, which roughly halves what the window costs:

```bash
export OLLAMA_CONTEXT_LENGTH=65536
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
```

Ollama's own default window is small and it truncates silently, so if it was already running when you ran the script, restart it with those set.

---

## What the script writes to your config

Five keys, verified against `hermes-agent` 0.19.0:

```yaml
model:
  provider: custom
  base_url: http://localhost:11434/v1
  default: llama3.1:8b
  context_length: 65536      # what the 64K guard reads — the actual fix
  ollama_num_ctx: 65536      # what goes on the wire, must match the above
```

`provider: custom` is Hermes' documented local path — aliases `ollama`, `local`, `vllm`, `llamacpp`. It needs **no API key**, and it sends `max_tokens` on every request. That last part matters: without it Ollama falls back to its internal `num_predict=128` and truncates every answer after a couple of sentences.

Applied with `hermes config set` rather than by editing YAML, so the schema stays valid:

```bash
hermes config set model.provider custom
hermes config set model.base_url http://localhost:11434/v1
hermes config set model.default llama3.1:8b
hermes config set model.context_length 65536
hermes config set model.ollama_num_ctx 65536
hermes config get model.default        # read it back
hermes config path                     # where it lives
```

Don't use `hermes model` in scripts — it's interactive only.

### Switching models without breaking it

Changing `model.default` on its own leaves the **previous** model's `context_length` behind, and the next agent init fails. Doing that by hand is what makes model switching feel cursed. The script installs a helper that moves all three keys together and validates the window first:

```bash
hermes-model                    # list installed models + their real windows
hermes-model llama3.1:8b        # switch: default + context_length + num_ctx
```

```
current: llama3.1:8b @ 65536 tokens

MODEL                        WINDOW
llama3.1:8b                  131072     ok
qwen2.5:32b                  32768      TOO SMALL for Hermes (needs 64000+)
mistral-nemo:12b             1024000    ok
```

It refuses a sub-64K model up front instead of letting the dashboard fail later. Restart the gateway afterwards — config is read at agent init.

---

## Daily use

Put this in your shell rc — the `PATH` entry, the window, and the certificate bundle all need to be inherited by the gateway process, not just by your interactive shell:

```bash
export PATH="$HOME/hermes-local/venv/bin:$HOME/hermes-local:$PATH"
export OLLAMA_CONTEXT_LENGTH=65536
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
[ -f "$HOME/hermes-local/certs.env" ] && . "$HOME/hermes-local/certs.env"
```

```bash
hermes chat                                  # terminal agent
hermes dashboard --host 127.0.0.1            # web UI on :9119
hermes dashboard --stop                      # stop it
hermes doctor                                # health check, --fix to repair
hermes status                                # gateway state
hermes skills                                # list / toggle skills
hermes serve                                 # headless JSON-RPC + WebSocket
```

Keep the dashboard on `127.0.0.1`. Since the mid-2026 hardening a public bind **requires** an auth provider — `--insecure` is a deprecated no-op. To reach it from another device, SSH-tunnel:

```bash
ssh -L 9119:127.0.0.1:9119 you@your-machine
```

## Turning reasoning off

Some local models burn the whole token budget on reasoning and return empty content. Ollama needs **both** switches, because its `/v1/chat/completions` silently ignores `extra_body.think` (only `/api/chat` honours it):

```bash
hermes config set model.reasoning_config.effort none
hermes config set model.reasoning_config.enabled false
```

---

## Troubleshooting

**`below the minimum 64,000 required by Hermes Agent`** — the model's own window is too small. No config value can raise it; raising `context_length` past the real window just makes Ollama truncate silently while the agent still refuses to init. Switch models with `hermes-model`. See [the 64K rule](#the-thing-that-will-bite-you-first-the-64k-rule).

**Every model I pick is rejected** — you're picking from the qwen family. `qwen2.5` is 32,768 and `qwen3` is 40,960 as Ollama ships it. Neither will ever start. Run `hermes-model` with no arguments to see the real window of everything you have downloaded.

**The gateway says it's running but keeps restarting** — check the log for `ws closed ... client_disconnect` immediately followed by `ws accepted`, and a repeating `run_agent: OpenAI client created (agent_init)`. That is not a crash loop: the process is fine, agent init is failing on every attempt and the UI drops and reconnects. Fix the context window first — this symptom usually goes with it. Confirm with `hermes doctor` before chasing it as a separate bug.

**`certificate verify failed: unable to get local issuer certificate`** — a macOS python.org build with no root certificates. It looks cosmetic (it appears on the model-catalog fetch) but it isn't: with the catalog unreachable Hermes can't look up a model's true context window and falls back to whatever the server reports. Fix:

```bash
~/hermes-local/venv/bin/pip install --upgrade certifi
open "/Applications/Python 3.13/Install Certificates.command"   # python.org builds only
export SSL_CERT_FILE="$(~/hermes-local/venv/bin/python -m certifi)"
export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
```

The script writes those two exports to `~/hermes-local/certs.env` — source it from your shell rc so the gateway inherits them.

### Log lines that look alarming and are not

| Line | Meaning |
|---|---|
| `Auxiliary Nous client unavailable: no Nous authentication found` | you're running fully local, there's no Nous account. Harmless. `hermes auth` silences it. |
| `marking opencoder unhealthy for 60s (payment / credit error)` | a cloud helper model you aren't paying for. Harmless. |
| `check_fn check_vision_requirements returned False` | vision tools disabled because the model isn't multimodal. Expected. |
| `check_web_api_key returned False` | no web-search key configured. Expected. |

None of these stop the agent. The context error and the certificate error do.

**`ensurepip is not available`** on venv creation — Debian/Ubuntu ships Python without it. The script self-heals via `sudo apt-get install python3.13-venv`; do that manually if you skipped it.

**Tools missing / browser or search does nothing** — you skipped `hermes postinstall`. pip cannot install node, the browser, ripgrep or ffmpeg. Run it, then `hermes doctor`.

**Answers cut off after a sentence** — `num_predict=128`. Confirm `model.provider` is `custom` (it's the profile that sends `max_tokens`).

**Empty replies** — a reasoning model eating its budget. Turn reasoning off, or switch to a plain chat model.

**Agent ignores its tools** — the model has no native tool calling. Change model, not settings.

**`connection refused` to 11434** — Ollama isn't running: `ollama serve` (the script backgrounds it to `$HERMES_DIR/ollama.log`).

**Very slow, machine swapping** — the model plus its 64K window is bigger than your RAM. You can't shrink the window below 64K, so drop a model size. `OLLAMA_FLASH_ATTENTION=1` with `OLLAMA_KV_CACHE_TYPE=q8_0` roughly halves what the window costs and is worth setting before you drop a size.

---

## Local vs a hosted Hermes

A fresh local install starts **empty**. Custom profiles, souls and skill selections from another Hermes install do not follow you. Port them explicitly:

```bash
# on the source install
hermes profile export <name>
# on this machine
hermes profile import <archive>
```

Also note pip ships **0.19.0**, which trails the newest container builds slightly. `hermes update` pulls newer releases when they land.

## Layout

```
~/hermes-local/venv/         virtualenv (hermes, hermes-acp, hermes-agent)
~/hermes-local/hermes-model  model switcher (model + context_length + num_ctx)
~/hermes-local/certs.env     SSL_CERT_FILE exports, if TLS needed fixing
~/hermes-local/ollama.log    ollama serve output
~/.hermes/config.yaml        your Hermes config (HERMES_HOME)
~/.ollama/models/            downloaded weights
```

Uninstall: `rm -rf ~/hermes-local ~/.hermes` (and `~/.ollama` for the weights).
