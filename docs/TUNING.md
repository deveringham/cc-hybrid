# Tuning

All knobs live in `~/.config/llama-server/llama-server.env` on the node.
Restart after editing:

```bash
systemctl --user restart llama-server
```

## The three that matter

**`CTX_SIZE`** (default 65536). Claude Code sends a large system prompt plus
tool schemas every single turn. Below ~32768 you get HTTP 400s from llama.cpp.
This is the first thing to lower if the server OOMs at startup.

**`CACHE_TYPE_K` / `CACHE_TYPE_V`** (default `q8_0`). Quantizing the KV cache is
what makes 64k context fit in 32 GB alongside an 18 GB model. Setting these to
`f16` roughly doubles cache size and will not fit. Quality cost of `q8_0` is
negligible.

**`TENSOR_SPLIT`** (default `0.5,0.5`). These cards have no NVLink, so layers
are split and activations cross PCIe. Unavoidable at this model size. Watch
with `nvidia-smi dmon` during a long session; if one card runs near full while
the other has headroom, skew it (`0.45,0.55`).

## The rest

| variable | default | notes |
|---|---|---|
| `NGL` | 99 | layers on GPU; 99 means "all" |
| `FLASH_ATTN` | `on` | works on Turing in llama.cpp, cuts KV cache cost |
| `PARALLEL` | 1 | concurrent slots **divide** `CTX_SIZE` between them |
| `BATCH_SIZE` | 2048 | larger helps prompt processing, which dominates latency |
| `UBATCH_SIZE` | 512 | lower both if you see OOM |
| `EXTRA_ARGS` | `--cache-reuse 256 --no-warmup` | prefix reuse across turns |
| `ALIAS` | `local-coder` | must match the model name in `litellm-config.yaml` |

`EXTRA_ARGS` **must stay quoted.** systemd tolerates an unquoted value with
spaces, but `install-service.sh` reads the file to validate paths and the shell
would try to execute the second word.

## Why this model

Default is `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q4_K_XL`.

It is a Mixture-of-Experts with roughly 3B active parameters out of 30B. That
matters here specifically: on Turing your bottleneck is compute, not capacity,
so an MoE buys 30B-class quality at 3B-class compute cost. A dense 30B would be
unusably slow on these cards.

**Use the Unsloth quants.** They carry the chat-template fixes that make tool
calling work. Other people's quants of the same model frequently do not, and
broken tool calling is the one failure that makes Claude Code look functional
while never touching a file.

To try something else:

```bash
HF_REPO=unsloth/Devstral-Small-2507-GGUF HF_QUANT=Q4_K_M ./setup-node.sh
```

then update `MODEL` and `ALIAS` in the env file.

## Keep in sync

Two values exist in both places and must match:

| node (`llama-server.env`) | laptop (`litellm-config.yaml`) |
|---|---|
| `ALIAS=local-coder` | `model: openai/local-coder` |
| `CTX_SIZE=65536` | `max_input_tokens: 65536` |

## Expected performance

- **First prompt of a session: slow.** A ~30k-token prompt on Turing takes real
  time to process. Normal.
- **Subsequent turns: much faster**, thanks to `--cache-reuse`.
- **Model load: minutes** from cold page cache. Keep the GGUF on local NVMe,
  never network storage.

If you want to know whether a change helped, compare against
`llama-bench` rather than impressions — prompt processing and token generation
move independently.
