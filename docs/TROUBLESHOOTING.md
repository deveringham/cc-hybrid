# Troubleshooting

Every failure below was hit while building this setup. The scripts now handle
most of them automatically; the explanations are here for when they resurface
in a new form.

---

## Build and install (node)

### apt fails with NO_PUBKEY / "is not signed"

```
W: GPG error: https://packages.cloud.google.com/apt cloud-sdk InRelease:
   The following signatures couldn't be verified ... NO_PUBKEY C0BA5CE6DC6315A3
E: The repository '... cloud-sdk InRelease' is not signed.
```

A third-party apt repo has a rotated signing key, and that breaks
`apt-get update` for *every* repo. The scripts warn and continue, because
everything they install comes from Ubuntu's own repos.

To fix it properly, refresh the key for the offending repo:

```bash
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
sudo sed -i 's|^deb https://packages.cloud.google.com|deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com|' \
  /etc/apt/sources.list.d/google-cloud-sdk.list
sudo apt-get update
```

Or disable it: `sudo mv /etc/apt/sources.list.d/google-cloud-sdk.list{,.disabled}`

### "Do not run this with sudo"

The scripts call `sudo` themselves where root is needed. Running the whole
script as root installs llama.cpp, the weights and the systemd **user** service
into `/root`, where `systemctl --user` as your own account cannot reach them.

If you already did:

```bash
sudo rm -rf /root/llm
```

### "parameter packs not expanded with '...'"

```
/usr/include/c++/11/bits/std_function.h:435: error:
    parameter packs not expanded with '...'
gmake[3]: *** [... ggml-cuda.dir/acc.cu.o] Error 1
```

Not a llama.cpp bug. `nvcc` cannot parse a libstdc++ newer than its CUDA
release expects, and it fails inside the standard headers rather than saying
so. CUDA 11.5 against GCC 11 reproduces it exactly.

`setup-node.sh` detects this and passes an older `g++` via
`-DCMAKE_CUDA_HOST_COMPILER`, installing one if needed. Only CUDA host code
uses it. Tolerances applied:

| toolkit | max GCC major |
|---|---|
| CUDA 11.0–11.7 | 10 |
| CUDA 11.8 | 11 |
| CUDA 12.x | 13 |
| CUDA 13.x | 14 |

### "undefined reference to `cuMemCreate`" / libcuda.so.1 not found

```
ld: warning: libcuda.so.1, needed by bin/libggml-cuda.so, not found
ld: libggml-cuda.so: undefined reference to `cuMemCreate'
```

`libcuda.so.1` ships with the **driver**, not the toolkit, and lives outside the
toolkit's library directory. This appears when a conda env is active: CMake
picks up `x86_64-conda-linux-gnu-gcc` and conda's `nvcc`, and conda's linker
never looks in `/usr/lib/x86_64-linux-gnu`.

The script now pins the build to the system toolchain when it detects conda,
and points the linker at the driver library. The manual equivalent:

```bash
conda deactivate
./setup-node.sh
```

`USE_CONDA_TOOLCHAIN=1` overrides, if you want conda's compilers deliberately.

### Toolkit and driver must match

Toolkit and driver are separate pieces of software. A toolkit newer than your
driver compiles happily, then fails at link time or dies at runtime with
*"CUDA driver version is insufficient"*.

| toolkit | minimum Linux driver |
|---|---|
| CUDA 11.x | ≥ 450 |
| CUDA 12.x | ≥ 525 and < 580 |
| CUDA 13.x | ≥ 580.65.06 |

`setup-node.sh` reads your driver, derives the highest toolkit major it can
run, and selects a matching `nvcc` — preferring system installs over conda. If
nothing compatible exists it stops rather than building an unusable binary.

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader
```

Turing (compute 7.5) is supported by CUDA 11, 12 and 13 alike — only Maxwell,
Pascal and Volta were dropped in CUDA 13 — so the GPU is never the constraint,
only the driver.

Beware: `conda install -c nvidia cuda-toolkit=12.4` may resolve to a much newer
version than requested. Check with `nvcc --version` afterwards.

### "line NN: 256: command not found" from the env file

An `EnvironmentFile` value containing spaces was written unquoted:

```
EXTRA_ARGS=--cache-reuse 256 --no-warmup      # wrong
EXTRA_ARGS="--cache-reuse 256 --no-warmup"    # right
```

systemd tolerates the first form; a shell sourcing the file reads it as "set
`EXTRA_ARGS=--cache-reuse`, then run the command `256`".
`install-service.sh` repairs an existing unquoted value and no longer sources
the file at all.

### Harmless build warnings

- **`Could NOT find NCCL`** — only matters for multi-GPU *training*. llama.cpp
  splits layers itself.
- **`Could NOT find OpenSSL` / HTTPS support disabled** — the server binds to
  loopback behind the SSH tunnel; it never needs TLS.
- **`LLAMA_CURL is deprecated`** — removed from the script.
- **`ccache not found`** — only affects rebuild speed.

---

## Runtime (node)

### Server OOMs on startup

Lower `CTX_SIZE` to 32768 in `~/.config/llama-server/llama-server.env`. Confirm
`CACHE_TYPE_K`/`CACHE_TYPE_V` are `q8_0`, not `f16`. See [TUNING.md](TUNING.md).

### Service dies when you log out

Lingering is not enabled:

```bash
sudo loginctl enable-linger "$USER"
```

`install-service.sh` does this, but it needs the `sudo` to have succeeded.

### Tools never fire, the model narrates instead

The highest-impact failure, because everything *looks* fine. `test-node.sh`
check 4 catches it.

Causes, in order of likelihood:

1. `--jinja` missing from the server command line.
2. A quant whose chat template lacks the tool-calling fixes. Use the Unsloth
   quants.
3. A template that needs overriding explicitly:

```
EXTRA_ARGS="--cache-reuse 256 --no-warmup --chat-template-file /path/to/model.jinja"
```

The `.jinja` file is downloaded alongside the GGUF.

---

## Connection (laptop)

### `API Error: 404`

`ANTHROPIC_BASE_URL` has a trailing `/v1`. The client appends `/v1/messages`
itself, so you get `/v1/v1/messages`. The wrappers set this correctly; this
only bites if you set it by hand.

### "Issue with the selected model"

A custom model id was passed directly in `--model`, which trips Claude Code's
model-list validation. Use a tier alias plus `ANTHROPIC_DEFAULT_*_MODEL`, which
is what `cc-local` does.

### `403 Forbidden`

The proxy did not receive a usable token. Usually `ANTHROPIC_API_KEY` is set in
your shell and wins over the proxy token. `cc-local` unsets it. Otherwise check
`ANTHROPIC_AUTH_TOKEN` matches `LITELLM_MASTER_KEY` in
`~/.config/cc-hybrid/litellm.env`.

### HTTP 400 from llama.cpp

Almost always context. Raise `CTX_SIZE` on the node and restart.

### Everything hangs on the first prompt

Often normal — see [TUNING.md §Expected performance](TUNING.md#expected-performance).
Check `journalctl --user -u llama-server -f` on the node: if tokens are being
processed, wait.

### Tunnel keeps dropping

```bash
systemctl --user status cc-tunnel
```

autossh reconnects after node sleep or laptop suspend, but the first request
after a reconnect may still fail. Run `cc-status` after waking the laptop.

### LiteLLM won't start

```bash
journalctl --user -u cc-litellm -n 50
```

Common causes: `LITELLM_MASTER_KEY` still the placeholder, a YAML syntax error
in `litellm-config.yaml`, or the venv missing (`./setup-laptop.sh` again).

---

## Diagnostic one-liners

```bash
# laptop: whole chain
cc-status

# laptop: raw Anthropic-format request through the proxy
curl -s http://127.0.0.1:4000/v1/messages \
  -H "x-api-key: $(sed -n 's/^LITELLM_MASTER_KEY=//p' ~/.config/cc-hybrid/litellm.env)" \
  -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{"model":"local-coder","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'

# laptop: is the tunnel actually carrying traffic?
curl -s localhost:8080/health

# node: what is loaded, and with how much context?
curl -s localhost:8080/props | python3 -m json.tool | head -20

# node: GPU usage during a session
nvidia-smi dmon -s um

# node: full server log
journalctl --user -u llama-server -f
```
