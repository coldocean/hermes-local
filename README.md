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
bash bootstrap.sh --model qwen2.5:32b    # override the auto-sized model
bash bootstrap.sh --ctx 32768            # cap the window (a cap, not a target)
bash bootstrap.sh --keep-64k-guard       # leave hermes-agent's 64K floor alone
bash bootstrap.sh --no-dashboard         # install and configure only
bash bootstrap.sh --port 9200            # dashboard port (default 9119)
bash bootstrap.sh --dir ~/hermes-local   # where the venv lives
bash bootstrap.sh --home ~/.hermes       # HERMES_HOME (config + data)
```

Environment overrides: `HERMES_DIR`, `HERMES_HOME`, `OLLAMA_URL`, `DASH_PORT`, `DASH_HOST`, `HERMES_CTX`.

---

## The 64K floor, and how this script removes it

Stock Hermes refuses to start on any model whose context window is under **64,000 tokens**. It is a hard constant, not a preference:

```python
# agent/model_metadata.py
MINIMUM_CONTEXT_LENGTH = 64_000

# agent/agent_init.py — raised during every agent init
if _ctx and _ctx < MINIMUM_CONTEXT_LENGTH:
    raise ValueError(...)

# agent/conversation_compression.py — same check for the auxiliary model
if aux_context and aux_context < MINIMUM_CONTEXT_LENGTH:
    raise ValueError(...)
```

That check is what produces the error everyone hits:

```
agent init failed: Model qwen2.5:32b has a context window of 32,768 tokens,
which is below the minimum 64,000 required by Hermes Agent
```

The window is a property of the weights, so no config value can raise it — which locks out a lot of perfectly good local models (`qwen2.5` is 32,768, `qwen3` is 40,960 as Ollama ships it, `gemma2`/`phi3` are ≤ 8,192).

**So this repo removes the floor from your own install.** It's your machine and your copy of the package:

```bash
python scripts/unlock-context.py            # patch
python scripts/unlock-context.py --check    # is it patched? (exit 0 = yes)
python scripts/unlock-context.py --restore  # put it back, byte for byte
```

`bootstrap.sh` runs it for you after the install. Four files change inside site-packages:

| File | Change |
|---|---|
| `agent/model_metadata.py` | `MINIMUM_CONTEXT_LENGTH = 64_000` → `4096` |
| `agent/agent_init.py` | main-model `raise ValueError` block deleted |
| `agent/conversation_compression.py` | auxiliary-model `raise ValueError` block deleted |
| `run_agent.py` | LM Studio preload target `max(config, MINIMUM…)` → `max(config, 32768)` |

Why 4096 and not 0: two call sites use the constant as a *positive* fallback (the LM Studio preload and `auxiliary_client._task_minimum_context_length`), and a zero there would ask for a zero-token load. 4096 is below every real window, so it gates nothing. The constant keeps its name because eight modules import it.

The patch is idempotent (a marker comment makes a second run a no-op), backs each file up to `<file>.hermes-local.orig`, and **fails loudly** if hermes-agent's source no longer matches — so a future version breaks visibly instead of silently doing nothing.

**Re-run it after every upgrade.** `pip install --upgrade hermes-agent` and `hermes update` rewrite site-packages and put the floor straight back.

### The honest trade-off

The floor was there for a reason. A 32K window still has to hold Hermes' system prompt plus every tool schema before your conversation starts, so long sessions compress early and the agent forgets things sooner. It *works* — it just isn't roomy. `bootstrap.sh` and `hermes-model` warn under 64K and then do what you asked.

### Two config keys, still

Removing the floor doesn't change how the window is configured:

**`model.context_length` is what Hermes reads.** In `model_metadata.py` the resolver short-circuits on the config value before any probe runs — *"0. Explicit config override — user knows best"*. Leave it unset and Hermes probes Ollama, gets whatever `num_ctx` the server serves (default 4096), and runs your 32B model in a 4K window.

**`context_length` caps `ollama_num_ctx`, it never raises it.** From `agent_init.py`: an auto-detected `num_ctx` larger than your `context_length` gets clamped down. So the two must be **the same number**. Setting one alone is the classic half-fix.

The script sets both to the model's **native** window (capped at 131,072 unless you pass `--ctx`, because `mistral-nemo` advertises 1,024,000 and nobody can hold that).

## The second thing: tool calling

Hermes is an **agent**, not a chatbot. It only works with models that support **native tool calling**. Pick a model without it and Hermes will look broken no matter how much RAM you have.

With the context floor gone this is the one bar left, and it is not negotiable — a small window costs you memory, a missing tool API costs you the whole agent.

**Native tool calling:** `llama3.3`, `llama3.2`, `llama3.1`, `mistral-nemo`, `mistral-large`, `mistral-small` 3.x, `command-r`, `devstral`, `granite3.1`+, `qwen2.5`, `qwen3`

**No tool calling at all:** `gemma` / `gemma2` / `gemma3`, older `phi`, `deepseek-coder` base, any plain completion model

The script warns if `--model` isn't in a known tool-calling family — and then installs it anyway. Nothing is refused for its window size.

## Model sizing

Size the *weights and the KV cache together* — a big window is not free, and on a fixed amount of RAM a bigger model with a smaller window is usually the better trade. Now that windows aren't forced to 64K, the qwen tiers are back in the ladder:

| Your RAM | Auto-picked | Weights (Q4) | Native window | KV at q8_0 | Verdict |
|---|---|---|---|---|---|
| < 8 GB | `llama3.2:1b` | ~0.8 GB | 131,072 | ~1 GB | wiring proof only — too weak to be an agent |
| 8–15 GB | `llama3.2:3b` | ~2 GB | 131,072 | ~4 GB | simple tool calls |
| 16–23 GB | `llama3.1:8b` | ~5 GB | 131,072 | ~4 GB | **sweet spot** |
| 24–31 GB | `qwen2.5:14b` | ~9 GB | 32,768 | ~1 GB | stronger reasoning, tight window |
| 32–47 GB | `qwen2.5:32b` | ~20 GB | 32,768 | ~2 GB | strong local brain, tight window |
| 48–63 GB | `devstral:24b` | ~14 GB | 131,072 | ~5 GB | very strong on code + tools |
| 64 GB+ | `llama3.3:70b` | ~40 GB | 131,072 | ~10 GB | best local option |

If you already have a tool-capable model downloaded, the script reuses it instead of pulling gigabytes again — `qwen2.5` included, now that it isn't rejected.

> **There is no 120B option here.** `gpt-oss-120b` needs ~60 GB+ of RAM. And Groq isn't a model you can download — it's a cloud provider with custom silicon. Local means local.

The window now follows the model instead of the other way round: the script reads the real GGUF `context_length` out of `/api/show` and uses it, clamped by `--ctx`/`HERMES_CTX` if you set one and capped at 131,072 by default. Flash attention plus a quantised KV cache roughly halves what any window costs, so both go in your environment:

```bash
export OLLAMA_CONTEXT_LENGTH=32768   # serve-wide ceiling — set it to your model's window
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
  default: qwen2.5:32b
  context_length: 32768      # the model's native window — what Hermes reads
  ollama_num_ctx: 32768      # what goes on the wire, must match the above
```

`provider: custom` is Hermes' documented local path — aliases `ollama`, `local`, `vllm`, `llamacpp`. It needs **no API key**, and it sends `max_tokens` on every request. That last part matters: without it Ollama falls back to its internal `num_predict=128` and truncates every answer after a couple of sentences.

Applied with `hermes config set` rather than by editing YAML, so the schema stays valid:

```bash
hermes config set model.provider custom
hermes config set model.base_url http://localhost:11434/v1
hermes config set model.default qwen2.5:32b
hermes config set model.context_length 32768
hermes config set model.ollama_num_ctx 32768
hermes config get model.default        # read it back
hermes config path                     # where it lives
```

Don't use `hermes model` in scripts — it's interactive only.

### Switching models without breaking it

Changing `model.default` on its own leaves the **previous** model's `context_length` behind, and you end up running a 32K model in a window it can't honour (or a 128K model in a 32K one). Doing it by hand is what makes model switching feel cursed. The script installs a helper that moves all three keys together and reads the new model's real window first:

```bash
hermes-model                    # list installed models + their real windows
hermes-model qwen2.5:32b        # switch: default + context_length + num_ctx
```

```
current: qwen2.5:32b @ 32768 tokens

MODEL                        WINDOW
llama3.1:8b                  131072     roomy
qwen2.5:32b                  32768      tight — compresses early, but allowed
mistral-nemo:12b             1024000    roomy
```

Nothing is refused. A sub-64K pick prints a note about early compression and switches anyway:

```
note: qwen2.5:32b has a 32768-token window. That is tight for an agent — the system
      prompt + tool schemas eat a fixed chunk of it, so sessions compress
      early. Switching anyway; the 64K floor was patched out.
```

`HERMES_CTX` caps it if you want less than native (`HERMES_CTX=16384 hermes-model qwen2.5:32b`). Restart the gateway afterwards — config is read at agent init.

---

## Daily use

Put this in your shell rc — the `PATH` entry, the window, and the certificate bundle all need to be inherited by the gateway process, not just by your interactive shell:

```bash
export PATH="$HOME/hermes-local/venv/bin:$HOME/hermes-local:$PATH"
export OLLAMA_CONTEXT_LENGTH=32768        # match your model's window
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

**`below the minimum 64,000 required by Hermes Agent`** — the floor is back, which means something rewrote site-packages: a `pip install --upgrade hermes-agent`, a `hermes update`, or a fresh venv. Re-run the patch:

```bash
~/hermes-local/venv/bin/python ~/hermes-local/scripts/unlock-context.py
~/hermes-local/venv/bin/python ~/hermes-local/scripts/unlock-context.py --check   # exit 0 = patched
```

If it reports that it can't find the pattern any more, hermes-agent changed shape — that is the patch failing loudly on purpose, not silently no-op'ing. See [the 64K floor](#the-64k-floor-and-how-this-script-removes-it).

**My model has a small window and the agent forgets things fast** — expected, and it's the price of removing the floor. The system prompt and tool schemas are a large fixed prefix, so a 32K model starts compressing early. Fewer skills enabled (`hermes skills`) buys some of it back; a 128K model buys all of it.

**Raising `context_length` above the model's real window** — doesn't work and never did. Ollama truncates silently. `hermes-model` clamps to the native window for you.

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

**Very slow, machine swapping** — the model plus its KV cache is bigger than your RAM. Now that the floor is gone you have two levers, not one: shrink the window (`HERMES_CTX=32768 hermes-model <model>`, or `--ctx` at install time) or drop a model size. Set `OLLAMA_FLASH_ATTENTION=1` with `OLLAMA_KV_CACHE_TYPE=q8_0` first — it roughly halves what the window costs.

---

## Local vs a hosted Hermes

A fresh local install starts **empty**. Custom profiles, souls and skill selections from another Hermes install do not follow you. Port them explicitly:

```bash
# on the source install
hermes profile export <name>
# on this machine
hermes profile import <archive>
```

Also note pip ships **0.19.0**, which trails the newest container builds slightly. `hermes update` pulls newer releases when they land — and rewrites site-packages, so re-run `scripts/unlock-context.py` afterwards.

## Layout

```
~/hermes-local/venv/         virtualenv (hermes, hermes-acp, hermes-agent)
~/hermes-local/hermes-model  model switcher (model + context_length + num_ctx)
scripts/unlock-context.py    removes the 64K floor (--check / --restore)
~/hermes-local/certs.env     SSL_CERT_FILE exports, if TLS needed fixing
~/hermes-local/ollama.log    ollama serve output
~/.hermes/config.yaml        your Hermes config (HERMES_HOME)
~/.ollama/models/            downloaded weights
```

Uninstall: `rm -rf ~/hermes-local ~/.hermes` (and `~/.ollama` for the weights).
