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

==> Setting up Ollama
  ! ollama not found — installing
  would run: sh -c curl -fsSL https://ollama.com/install.sh | sh
  would run: ollama serve &

==> Choosing a model
  no models downloaded yet
  ✓ picked for 3 GB: llama3.2:1b (wiring proof only — too small to be a useful agent)

==> Pulling llama3.2:1b (this is the slow part)
  would run: ollama pull llama3.2:1b

==> Pointing Hermes at local Ollama (HERMES_HOME=/tmp/hermes-dryhome)
  would run: hermes config set model.provider custom
  would run: hermes config set model.base_url http://localhost:11434/v1
  would run: hermes config set model.default llama3.2:1b
  would run: hermes config set model.ollama_num_ctx 8192

==> Done
```

Note the sizing in action: 3 GB of RAM → `llama3.2:1b` and `num_ctx 8192`, with an honest warning
that it's a wiring proof, not a working agent. On a 16 GB box the same script picks `qwen2.5:7b` at
32k context.

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

## 3. The Ollama wiring, read back · captured

```console
$ hermes config get model.provider
model.provider = custom

$ hermes config get model.base_url
model.base_url = http://localhost:11434/v1

$ hermes config get model.default
model.default = qwen2.5:7b

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
  default: qwen2.5:7b
  ollama_num_ctx: 32768
```

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
    -d '{"model":"qwen2.5:7b","max_tokens":32,
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

$ hermes chat                      # terminal agent, local brain
$ hermes dashboard --host 127.0.0.1
  dashboard → http://127.0.0.1:9119
$ hermes dashboard --status
$ hermes dashboard --stop
$ hermes doctor                    # add --fix to repair
$ hermes status
$ ollama list                      # what weights you actually have
```

---

## 7. Porting profiles from another install · expected shape

```console
# on the source machine
$ hermes profile export coding
# on this machine
$ hermes profile import ./coding.hermesprofile
```

A fresh local install starts empty — profiles, souls and skill selections do not travel on their own.
