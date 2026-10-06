#!/usr/bin/env bash
# Build llama.cpp for Turing (Quadro RTX 5000, compute capability 7.5)
# and fetch a coder model. Run this ON THE QUADRO NODE.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/llm}"
LLAMA_SRC="$PREFIX/llama.cpp"
MODEL_DIR="${MODEL_DIR:-$PREFIX/models}"
CUDA_ARCH="${CUDA_ARCH:-75}"   # 75 = Turing. Do not change unless your GPUs differ.

# Unsloth's quants carry the tool-calling chat-template fixes. Keep this repo
# unless you have a specific reason to switch.
HF_REPO="${HF_REPO:-unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF}"
HF_QUANT="${HF_QUANT:-UD-Q4_K_XL}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }

# --- preflight ---------------------------------------------------------------
# Do NOT run this under sudo. It calls sudo itself where root is needed; running
# the whole thing as root installs llama.cpp, the model and the user service
# into /root, where `systemctl --user` as your own account cannot reach them.
if [ "$(id -u)" -eq 0 ]; then
  die "Do not run this with sudo. Run it as your normal user:  ./setup-node.sh
       (If you already ran it as root, clean up first:  sudo rm -rf /root/llm)"
fi

command -v nvidia-smi >/dev/null || die "nvidia-smi not found. Install the NVIDIA driver first."
command -v nvcc >/dev/null || die "nvcc not found. Install the CUDA toolkit (e.g. 'sudo apt install nvidia-cuda-toolkit') or add it to PATH."

log "Detected GPUs:"
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader

# --- dependencies ------------------------------------------------------------
# Only install what is actually missing, and never let a broken THIRD-PARTY apt
# repo (expired signing keys on cloud-sdk, docker, cuda repos and the like) kill
# the whole run. Everything we need lives in Ubuntu's own repos.
PKGS="build-essential cmake git curl libcurl4-openssl-dev python3-pip python3-venv pciutils"
missing=""
for p in $PKGS; do
  dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
done

if [ -n "$missing" ]; then
  log "Installing missing build dependencies:$missing"
  apt_out=$(sudo apt-get update 2>&1) || true
  if printf '%s' "$apt_out" | grep -qE 'NO_PUBKEY|is not signed|GPG error'; then
    warn "One or more third-party apt repositories failed to refresh:"
    printf '%s\n' "$apt_out" | grep -E 'NO_PUBKEY|is not signed|GPG error' | sed 's/^/       /' >&2
    warn "Ignoring — Ubuntu's own repos are what we need. See README §1.0 to fix it properly."
  fi
  # shellcheck disable=SC2086
  sudo apt-get install -y -qq $missing \
    || die "apt install failed. Install these by hand, then re-run:$missing"
else
  log "All build dependencies already present"
fi

mkdir -p "$PREFIX" "$MODEL_DIR"

# --- build llama.cpp ---------------------------------------------------------
if [ -d "$LLAMA_SRC/.git" ]; then
  log "Updating existing llama.cpp checkout"
  git -C "$LLAMA_SRC" pull --ff-only
else
  log "Cloning llama.cpp"
  git clone https://github.com/ggml-org/llama.cpp "$LLAMA_SRC"
fi

# --- choose a CUDA toolkit the installed DRIVER can actually run -------------
# The toolkit and the driver are separate things. A toolkit newer than the
# driver compiles fine and then fails, either at link time (libcuda.so.1 not
# found) or at runtime ("CUDA driver version is insufficient").
#   CUDA 11.x needs driver >= 450
#   CUDA 12.x needs driver >= 525 and < 580
#   CUDA 13.x needs driver >= 580.65.06
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
DRIVER_MAJOR=${DRIVER_VER%%.*}
log "NVIDIA driver: ${DRIVER_VER:-unknown}"

if [ -n "${DRIVER_MAJOR:-}" ] && [ "$DRIVER_MAJOR" -ge 580 ] 2>/dev/null; then
  MAX_CUDA_MAJOR=13
elif [ -n "${DRIVER_MAJOR:-}" ] && [ "$DRIVER_MAJOR" -ge 525 ] 2>/dev/null; then
  MAX_CUDA_MAJOR=12
else
  MAX_CUDA_MAJOR=11
fi
log "Driver supports CUDA toolkits up to major version $MAX_CUDA_MAJOR"

# Conda's compilers and toolkit hijack the build: CMake picks
# x86_64-conda-linux-gnu-gcc and conda's nvcc, then its linker cannot see the
# system driver library. Build with the system toolchain unless told otherwise.
: "${USE_CONDA_TOOLCHAIN:=0}"

nvcc_ver_of() { "$1" --version 2>/dev/null | sed -n 's/.*release \([0-9]\+\.[0-9]\+\).*/\1/p' | head -1; }

# Candidate nvcc binaries, system locations first.
NVCC=""
for cand in /usr/local/cuda/bin/nvcc /usr/local/cuda-12*/bin/nvcc /usr/local/cuda-11*/bin/nvcc /usr/bin/nvcc; do
  [ -x "$cand" ] || continue
  v=$(nvcc_ver_of "$cand"); [ -n "$v" ] || continue
  if [ "${v%%.*}" -le "$MAX_CUDA_MAJOR" ] 2>/dev/null; then NVCC="$cand"; CUDA_VER="$v"; break; fi
done

# Fall back to whatever nvcc is on PATH (possibly conda's).
if [ -z "$NVCC" ] && command -v nvcc >/dev/null 2>&1; then
  NVCC=$(command -v nvcc); CUDA_VER=$(nvcc_ver_of "$NVCC")
fi
[ -n "$NVCC" ] || die "No usable nvcc found."

CUDA_MAJOR=${CUDA_VER%%.*}
CUDA_MINOR=${CUDA_VER##*.}
log "Using nvcc: $NVCC (CUDA $CUDA_VER)"

if [ "${CUDA_MAJOR:-0}" -gt "$MAX_CUDA_MAJOR" ] 2>/dev/null; then
  die "CUDA toolkit $CUDA_VER needs a newer driver than ${DRIVER_VER:-yours}.
       This build would fail to link (libcuda.so.1 not found) or crash at
       runtime with 'CUDA driver version is insufficient'.
       Fix one of these, then re-run:
         - Install a toolkit your driver supports, e.g. in conda:
             conda install -y -c nvidia cuda-toolkit=12.4
           (and for driver < 525, use the system CUDA 11.x instead:
             conda deactivate && ./setup-node.sh)
         - Or update the NVIDIA driver to >= 580 to keep CUDA 13.x."
fi

CUDA_BIN_DIR=$(dirname "$NVCC")
CUDA_ROOT=$(dirname "$CUDA_BIN_DIR")

# --- pick a CUDA host compiler nvcc can actually digest ----------------------
# nvcc refuses to parse a libstdc++ newer than its CUDA release expects. With
# CUDA 11.x and GCC 11 you get a flood of
#   /usr/include/c++/11/bits/std_function.h: error: parameter packs not
#   expanded with '...'
# which is nvcc mis-parsing the host headers, not a llama.cpp bug. The fix is
# to hand nvcc an older g++ for host code only.

# Highest GCC major each CUDA line tolerates in practice.
case "$CUDA_MAJOR" in
  11) if [ "${CUDA_MINOR:-0}" -ge 8 ]; then MAX_GCC=11; else MAX_GCC=10; fi ;;
  12) MAX_GCC=13 ;;
  13|*) MAX_GCC=14 ;;
esac

# Pin the main compilers to the system ones so conda's toolchain stays out.
TOOLCHAIN_ARGS=""
if [ "$USE_CONDA_TOOLCHAIN" != "1" ] && [ -x /usr/bin/gcc ] && [ -x /usr/bin/g++ ]; then
  if [ -n "${CONDA_PREFIX:-}" ]; then
    log "Conda env active; forcing the system toolchain (set USE_CONDA_TOOLCHAIN=1 to override)"
  fi
  TOOLCHAIN_ARGS="-DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++"
  SYS_GCC=$(/usr/bin/g++ -dumpversion 2>/dev/null | cut -d. -f1 || echo 0)
else
  SYS_GCC=$(g++ -dumpversion 2>/dev/null | cut -d. -f1 || echo 0)
fi

HOST_GCC_ARG=""
if [ "${SYS_GCC:-0}" -gt "$MAX_GCC" ] 2>/dev/null; then
  log "System g++ is $SYS_GCC but CUDA $CUDA_VER needs <= $MAX_GCC for host code"
  HOST_GXX=""
  for v in $(seq "$MAX_GCC" -1 8); do
    if [ -x "/usr/bin/g++-$v" ]; then HOST_GXX="/usr/bin/g++-$v"; break; fi
  done
  if [ -z "$HOST_GXX" ]; then
    log "Installing g++-$MAX_GCC for nvcc host compilation (sudo required)"
    sudo apt-get install -y -qq "gcc-$MAX_GCC" "g++-$MAX_GCC" \
      || die "Could not install g++-$MAX_GCC. Install a compatible g++ by hand and re-run."
    HOST_GXX="/usr/bin/g++-$MAX_GCC"
  fi
  log "Using $HOST_GXX as the CUDA host compiler"
  HOST_GCC_ARG="-DCMAKE_CUDA_HOST_COMPILER=$HOST_GXX"
fi

# --- make sure the linker can find the driver library ------------------------
# libcuda.so.1 ships with the DRIVER, not the toolkit, and lives outside the
# toolkit's lib dir. Toolkits provide a link-time stub; point the linker at
# whichever we can find, or the final link fails with
#   undefined reference to `cuMemCreate' / libcuda.so.1, needed by ..., not found
LINK_ARGS=""
STUB_DIR=""
for d in "$CUDA_ROOT/lib64/stubs" "$CUDA_ROOT/lib/stubs" "$CUDA_ROOT/targets/x86_64-linux/lib/stubs"; do
  [ -f "$d/libcuda.so" ] && { STUB_DIR="$d"; break; }
done
DRIVER_LIB_DIR=""
for d in /usr/lib/x86_64-linux-gnu /usr/lib64 /lib/x86_64-linux-gnu; do
  [ -e "$d/libcuda.so.1" ] && { DRIVER_LIB_DIR="$d"; break; }
done
if [ -n "$DRIVER_LIB_DIR" ]; then
  log "Driver library found in $DRIVER_LIB_DIR"
  LINK_ARGS="-DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath-link,$DRIVER_LIB_DIR -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-rpath-link,$DRIVER_LIB_DIR"
elif [ -n "$STUB_DIR" ]; then
  log "Using CUDA driver stub in $STUB_DIR"
  LINK_ARGS="-DCMAKE_EXE_LINKER_FLAGS=-L$STUB_DIR -DCMAKE_SHARED_LINKER_FLAGS=-L$STUB_DIR"
else
  warn "Could not locate libcuda.so.1 or a driver stub; the link step may fail."
fi

# --- build llama.cpp ---------------------------------------------------------
log "Building llama-server for CUDA arch $CUDA_ARCH (this takes several minutes)"

# Any change of compiler, toolkit or linker flags must not inherit a stale
# CMake cache — CMake would silently keep the previous, broken selection.
if [ -f "$LLAMA_SRC/build/CMakeCache.txt" ]; then
  cached_host=$(sed -n 's/^CMAKE_CUDA_HOST_COMPILER:[^=]*=//p' "$LLAMA_SRC/build/CMakeCache.txt" | head -1)
  cached_cxx=$(sed -n 's/^CMAKE_CXX_COMPILER:[^=]*=//p'        "$LLAMA_SRC/build/CMakeCache.txt" | head -1)
  cached_nvcc=$(sed -n 's/^CMAKE_CUDA_COMPILER:[^=]*=//p'      "$LLAMA_SRC/build/CMakeCache.txt" | head -1)
  want_host=${HOST_GCC_ARG#-DCMAKE_CUDA_HOST_COMPILER=}
  want_cxx="/usr/bin/g++"; [ -n "$TOOLCHAIN_ARGS" ] || want_cxx="$cached_cxx"
  if [ "$cached_host" != "$want_host" ] || [ "$cached_cxx" != "$want_cxx" ] \
     || { [ -n "$cached_nvcc" ] && [ "$cached_nvcc" != "$NVCC" ]; }; then
    log "Toolchain selection changed; wiping stale build directory"
    rm -rf "$LLAMA_SRC/build"
  fi
fi

# shellcheck disable=SC2086
cmake -S "$LLAMA_SRC" -B "$LLAMA_SRC/build" \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DCMAKE_CUDA_COMPILER="$NVCC" \
  $TOOLCHAIN_ARGS \
  $HOST_GCC_ARG \
  $LINK_ARGS \
  || die "CMake configure failed."

cmake --build "$LLAMA_SRC/build" --config Release -j"$(nproc)" --target llama-server llama-cli \
  || die "Build failed. Common causes:
       * 'parameter packs not expanded' in std_function.h
           nvcc cannot parse your libstdc++. Install an older g++ and re-run.
       * 'undefined reference to cuMemCreate' / 'libcuda.so.1 ... not found'
           The linker cannot see the driver library, usually because a conda
           toolchain is active. Re-run outside conda:
             conda deactivate && ./setup-node.sh
       * A toolkit newer than your driver supports. Check the versions this
         script printed above, and install a matching toolkit."

[ -x "$LLAMA_SRC/build/bin/llama-server" ] || die "Build finished but llama-server is missing."
log "Built $LLAMA_SRC/build/bin/llama-server"

# --- fetch the model ---------------------------------------------------------
log "Downloading $HF_REPO:$HF_QUANT into $MODEL_DIR"

# Use an isolated venv for the downloader. Avoids touching a conda base env,
# and sidesteps PEP 668 "externally-managed-environment" on newer Ubuntu.
DL_VENV="$PREFIX/.hfvenv"
if [ ! -x "$DL_VENV/bin/python" ]; then
  python3 -m venv "$DL_VENV" || die "Could not create venv at $DL_VENV (is python3-venv installed?)"
fi
"$DL_VENV/bin/pip" install --quiet --upgrade pip
"$DL_VENV/bin/pip" install --quiet --upgrade "huggingface_hub[hf_transfer]"

# hf_transfer gives much faster downloads for a ~18 GB fetch.
export HF_HUB_ENABLE_HF_TRANSFER=1

"$DL_VENV/bin/python" - <<PY
from huggingface_hub import snapshot_download
import os
p = snapshot_download(
    repo_id="${HF_REPO}",
    allow_patterns=["*${HF_QUANT}*.gguf", "*.jinja", "*.json"],
    local_dir=os.path.join("${MODEL_DIR}", "${HF_REPO}".split("/")[-1]),
)
print("Downloaded to:", p)
PY

log "GGUF files now present:"
find "$MODEL_DIR" -name '*.gguf' -printf '%p  (%s bytes)\n'

cat <<EOF

Done. Next steps on this node:

  1. Copy the GGUF path printed above into  ~/.config/llama-server/llama-server.env
     (install it with: ./install-service.sh)
  2. Start the service:  systemctl --user start llama-server
  3. Check it:           curl -s localhost:8080/health

EOF
