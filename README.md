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
bash bootstrap.sh --model qwen2.5:14b    # override the auto-sized model
bash bootstrap.sh --no-dashboard         # install and configure only
bash bootstrap.sh --port 9200            # dashboard port (default 9119)
bash bootstrap.sh --dir ~/hermes-local   # where the venv lives
bash bootstrap.sh --home ~/.hermes       # HERMES_HOME (config + data)
```

Environment overrides: `HERMES_DIR`, `HERMES_HOME`, `OLLAMA_URL`, `DASH_PORT`, `DASH_HOST`.

---

## The one thing that will bite you: tool calling

Hermes is an **agent**, not a chatbot. It only works with models that support **native tool calling**. Pick a model without it and Hermes will look broken no matter how much RAM you have.

**Works:** `qwen3`, `qwen2.5`, `llama3.3`, `llama3.2`, `llama3.1`, `mistral-nemo`, `mistral-small`, `command-r`, `firefunction`, `devstral`, `granite3`

**Does not:** `gemma` / `gemma2` / `gemma3`, older `phi`, `deepseek-coder` base, any plain completion model

The script warns you if `--model` isn't in a known tool-calling family.

## Model sizing

Rough Q4 quantised footprints, and what the script picks for you:

| Your RAM | Auto-picked | Model RAM | Verdict |
|---|---|---|---|
| < 6 GB | `llama3.2:1b` | ~0.8 GB | wiring proof only — too weak to be an agent |
| 6–11 GB | `llama3.2:3b` | ~2.5 GB | simple tool calls |
| 12–19 GB | `qwen2.5:7b` | ~5 GB | **sweet spot** |
| 20–31 GB | `qwen2.5:14b` | ~9 GB | strong |
| 32–63 GB | `qwen2.5:32b` | ~20 GB | very strong |
| 64 GB+ | `llama3.3:70b` | ~40 GB | best local option |

If you already have a tool-capable model downloaded, the script reuses it instead of pulling gigabytes again.

> **There is no 120B option here.** `gpt-oss-120b` needs ~60 GB+ of RAM. And Groq isn't a model you can download — it's a cloud provider with custom silicon. Local means local.

`model.ollama_num_ctx` is also scaled to your RAM (8k / 16k / 32k), because context eats memory on top of the weights.

---

## What the script writes to your config

Four keys, verified against `hermes-agent` 0.19.0:

```yaml
model:
  provider: custom
  base_url: http://localhost:11434/v1
  default: qwen2.5:7b
  ollama_num_ctx: 32768
```

`provider: custom` is Hermes' documented local path — aliases `ollama`, `local`, `vllm`, `llamacpp`. It needs **no API key**, and it sends `max_tokens` on every request. That last part matters: without it Ollama falls back to its internal `num_predict=128` and truncates every answer after a couple of sentences.

Applied with `hermes config set` rather than by editing YAML, so the schema stays valid:

```bash
hermes config set model.provider custom
hermes config set model.base_url http://localhost:11434/v1
hermes config set model.default qwen2.5:7b
hermes config set model.ollama_num_ctx 32768
hermes config get model.default        # read it back
hermes config path                     # where it lives
```

Don't use `hermes model` in scripts — it's interactive only.

---

## Daily use

```bash
export PATH="$HOME/hermes-local/venv/bin:$PATH"   # add to your shell rc

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

**`ensurepip is not available`** on venv creation — Debian/Ubuntu ships Python without it. The script self-heals via `sudo apt-get install python3.13-venv`; do that manually if you skipped it.

**Tools missing / browser or search does nothing** — you skipped `hermes postinstall`. pip cannot install node, the browser, ripgrep or ffmpeg. Run it, then `hermes doctor`.

**Answers cut off after a sentence** — `num_predict=128`. Confirm `model.provider` is `custom` (it's the profile that sends `max_tokens`).

**Empty replies** — a reasoning model eating its budget. Turn reasoning off, or switch to a plain chat model.

**Agent ignores its tools** — the model has no native tool calling. Change model, not settings.

**`connection refused` to 11434** — Ollama isn't running: `ollama serve` (the script backgrounds it to `$HERMES_DIR/ollama.log`).

**Very slow, machine swapping** — the model is bigger than your RAM. Drop a size or lower `ollama_num_ctx`.

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
~/hermes-local/venv/       virtualenv (hermes, hermes-acp, hermes-agent)
~/hermes-local/ollama.log  ollama serve output
~/.hermes/config.yaml      your Hermes config (HERMES_HOME)
~/.ollama/models/          downloaded weights
```

Uninstall: `rm -rf ~/hermes-local ~/.hermes` (and `~/.ollama` for the weights).
