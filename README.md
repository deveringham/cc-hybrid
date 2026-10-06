# cc-hybrid

Drive Claude Code from a self-hosted model on a GPU node, with a one-word
switch back to Anthropic for the hard stuff. Built for a node with
2× Quadro RTX 5000 (16 GB each, Turing) driven from an Ubuntu laptop.

```
┌──────────────── Ubuntu laptop ─────────────────┐      ┌──── GPU node ────┐
│                                                 │      │                  │
│  claude ──► LiteLLM :4000 ──► ssh tunnel :8080 ─┼──────┼─► llama-server   │
│        Anthropic /v1/messages   (autossh)       │      │   Qwen3-Coder    │
│                                                 │      │                  │
└─────────────────────────────────────────────────┘      └──────────────────┘
```

Claude Code speaks the Anthropic Messages API; llama.cpp speaks OpenAI's.
LiteLLM sits between them, serving `/v1/messages` and translating both ways.

## Daily use

```bash
cc-local     # Claude Code against your own node
cc-cloud     # Claude Code against Anthropic (your subscription)
cc-status    # is the local path healthy?
```

`cc-local` checks the tunnel and proxy before launching and starts whatever is
down, so you get a clear message up front rather than a hang mid-task.

**Switching is manual and deliberate.** There is no automatic failover in the
default config — see [docs/ROUTING.md](docs/ROUTING.md) for why, and for how to
turn on automatic fallback if you have a pay-as-you-go API key.

Rule of thumb: default to `cc-local`. When a session starts looping, re-reading
the same file, or producing malformed edits, that is the local model hitting its
ceiling — restart in `cc-cloud`.

## Install

Node (as your normal user, **not** with sudo, **not** inside conda):

```bash
scp -r node/ gpunode:~/cc-hybrid-node
ssh gpunode
cd ~/cc-hybrid-node
./setup-node.sh          # builds llama.cpp, downloads ~18 GB of weights
./install-service.sh
# set MODEL in ~/.config/llama-server/llama-server.env to the real .gguf path
systemctl --user start llama-server
./test-node.sh           # check #4 (tool calling) is the one that matters
```

Laptop:

```bash
cd laptop
./setup-laptop.sh
$EDITOR ~/.config/cc-hybrid/tunnel.env     # set SSH_TARGET
systemctl --user start cc-tunnel cc-litellm
cc-status
```

Full walkthrough with prerequisites: [docs/SETUP.md](docs/SETUP.md).

## Layout

| path | what |
|---|---|
| `node/setup-node.sh` | builds llama.cpp for Turing, fetches the model |
| `node/install-service.sh` | installs the systemd user service |
| `node/test-node.sh` | smoke test, **including tool calling** |
| `node/llama-server.env.example` | all server tuning knobs |
| `laptop/setup-laptop.sh` | installs everything on the laptop side |
| `laptop/litellm-config.yaml` | routing, timeouts, optional cloud fallback |
| `laptop/cc-tunnel.service` | auto-reconnecting SSH tunnel |
| `laptop/bin/` | the `cc-local` / `cc-cloud` / `cc-status` wrappers |
| `docs/` | setup, tuning, troubleshooting, routing |

## Secrets

`*.env` is gitignored; only `*.env.example` is tracked. The real files are
created in `~/.config/cc-hybrid/` and `~/.config/llama-server/` at install time,
`chmod 600`, and `setup-laptop.sh` generates a random LiteLLM master key. Nothing
in this repo should ever contain a credential.

`llama-server` binds to `127.0.0.1` on the node and has **no authentication** —
the SSH tunnel is the access control. Never set `HOST=0.0.0.0`.

## Docs

- [docs/SETUP.md](docs/SETUP.md) — full install, prerequisites, verification
- [docs/TUNING.md](docs/TUNING.md) — context size, KV cache, model choice
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — every failure hit while building this
- [docs/ROUTING.md](docs/ROUTING.md) — why switching is manual, and the options
