# Setup

## Prerequisites

**GPU node**
- Linux with the NVIDIA driver installed (`nvidia-smi` works)
- A CUDA toolkit (`nvcc`) whose major version your driver supports — see
  [TROUBLESHOOTING.md §Toolkit and driver must match](TROUBLESHOOTING.md#toolkit-and-driver-must-match)
- ~40 GB free disk (llama.cpp build + ~18 GB of weights)
- Key-based SSH access from the laptop

**Laptop**
- Ubuntu (or any Debian derivative)
- Claude Code installed and working (`claude` on `PATH`)
- `sudo` for a handful of apt packages

## 1. The GPU node

Run the scripts **as your normal user**. They call `sudo` where needed. Running
the whole thing as root installs into `/root`, where `systemctl --user` as your
own account cannot reach it — the scripts refuse to start as root for this
reason.

If you use conda, **deactivate it first**. Conda's compilers and CUDA toolkit
will hijack the build and produce a binary that cannot link against the driver.

```bash
conda deactivate
scp -r node/ gpunode:~/cc-hybrid-node
ssh gpunode
cd ~/cc-hybrid-node
./setup-node.sh
```

`setup-node.sh` does the following, and is safe to re-run:

1. Refuses to run as root.
2. Installs only the apt packages that are actually missing, tolerating a
   broken third-party repo (expired GPG keys on cloud-sdk, docker, etc.).
3. Clones or updates llama.cpp.
4. Reads your driver version and picks an `nvcc` whose major version that
   driver can run, preferring system installs over a conda one.
5. Picks a CUDA host compiler `nvcc` can parse, installing an older `g++` if
   the system one is too new.
6. Points the linker at `libcuda.so.1` (or a toolkit stub).
7. Builds `llama-server` for compute capability 7.5.
8. Downloads the model into an isolated venv-driven `huggingface_hub`, so your
   conda base environment is never touched.

Override defaults with environment variables:

```bash
PREFIX=/data/llm ./setup-node.sh                                  # install elsewhere
CUDA_ARCH=86 ./setup-node.sh                                      # different GPU
HF_REPO=unsloth/Devstral-Small-2507-GGUF HF_QUANT=Q4_K_M ./setup-node.sh
USE_CONDA_TOOLCHAIN=1 ./setup-node.sh                             # deliberately use conda
```

### Install the service

```bash
./install-service.sh
```

This writes `~/.config/llama-server/llama-server.env` (substituting your real
home directory, because systemd does not expand `%h` inside an
`EnvironmentFile`), installs the unit, and enables `loginctl enable-linger` so
the server survives you logging out.

It will warn if the `MODEL` path does not exist — the default filename in the
template is a guess. Find the real one and set it:

```bash
find ~/llm/models -name '*.gguf'
$EDITOR ~/.config/llama-server/llama-server.env
```

### Start and verify

```bash
systemctl --user start llama-server
journalctl --user -u llama-server -f     # model load takes a few minutes
./test-node.sh
```

`test-node.sh` runs five checks. **Check 4, tool calling, is the one that
matters.** If the model mentions a tool but does not emit a structured
`tool_calls` block, Claude Code will appear to work while silently never
editing a file. Fix that before going further — see
[TROUBLESHOOTING.md §Tools never fire](TROUBLESHOOTING.md#tools-never-fire-the-model-narrates-instead).

## 2. The laptop

### SSH first

The tunnel runs as a systemd user service, so it cannot answer a password or
passphrase prompt. Set up `~/.ssh/config`:

```
Host quadro
    HostName      gpu05.example.internal
    User          dylan
    IdentityFile  ~/.ssh/id_ed25519
```

Confirm `ssh quadro true` returns immediately with no prompt. If your key has a
passphrase, make sure `ssh-agent` is running and the key is loaded.

### Install

```bash
cd laptop
./setup-laptop.sh
```

This creates a venv at `~/.local/share/cc-hybrid/venv`, installs
`litellm[proxy]>=1.82.9` (the pin steps past the 1.82.7/1.82.8 supply-chain
advisory — do not loosen it), generates a random master key, installs both
systemd user units, and puts the three wrappers in `~/.local/bin`.

Re-running it keeps your existing `.env` files and refreshes
`litellm-config.yaml` from the repo, backing up a locally modified copy to
`litellm-config.yaml.bak`.

### Point it at the node

```bash
$EDITOR ~/.config/cc-hybrid/tunnel.env      # SSH_TARGET=quadro
systemctl --user start cc-tunnel cc-litellm
cc-status
```

`cc-status` should show four green lines. The last — end-to-end
`/v1/messages` — exercises the whole chain and is the real test.

## 3. Use it

```bash
cc-local
```

The first prompt of a session will feel slow. Processing a ~30k-token Claude
Code prompt on Turing takes real time, and `--cache-reuse` only helps from the
second turn onward. That is the hardware, not a misconfiguration.

## File locations after install

| file | purpose |
|---|---|
| `~/.config/llama-server/llama-server.env` | node: server config (on the node) |
| `~/.config/systemd/user/llama-server.service` | node: unit |
| `~/llm/llama.cpp/build/bin/llama-server` | node: the binary |
| `~/llm/models/` | node: weights |
| `~/.config/cc-hybrid/litellm.env` | laptop: master key, optional API key |
| `~/.config/cc-hybrid/tunnel.env` | laptop: SSH target and ports |
| `~/.config/cc-hybrid/litellm-config.yaml` | laptop: routing |
| `~/.local/share/cc-hybrid/venv/` | laptop: LiteLLM |
| `~/.local/bin/cc-{local,cloud,status}` | laptop: wrappers |
