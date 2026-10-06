#!/usr/bin/env bash
# Install the laptop side: LiteLLM venv, configs, systemd user units, wrappers.
# Run ON YOUR UBUNTU LAPTOP.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$HOME/.config/cc-hybrid"
UNIT_DIR="$HOME/.config/systemd/user"
VENV_DIR="$HOME/.local/share/cc-hybrid/venv"
BIN_DIR="$HOME/.local/bin"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Do not run this with sudo. Run it as your normal user."
command -v claude >/dev/null || die "Claude Code ('claude') not on PATH. Install it first."

PKGS="python3-venv python3-pip autossh curl openssl"
missing=""
for p in $PKGS; do
  dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
done

if [ -n "$missing" ]; then
  log "Installing missing packages (sudo required):$missing"
  apt_out=$(sudo apt-get update 2>&1) || true
  if printf '%s' "$apt_out" | grep -qE 'NO_PUBKEY|is not signed|GPG error'; then
    warn "Some third-party apt repositories failed to refresh; ignoring."
  fi
  # shellcheck disable=SC2086
  sudo apt-get install -y -qq $missing \
    || die "apt install failed. Install these by hand, then re-run:$missing"
else
  log "All required packages already present"
fi

mkdir -p "$CONF_DIR" "$UNIT_DIR" "$BIN_DIR" "$(dirname "$VENV_DIR")"

# --- LiteLLM in its own venv -------------------------------------------------
log "Creating LiteLLM virtualenv at $VENV_DIR"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
# Pin away from 1.82.7/1.82.8, which carried a supply-chain advisory.
log "Installing litellm[proxy] (this pulls a lot of deps; be patient)"
"$VENV_DIR/bin/pip" install --quiet 'litellm[proxy]>=1.82.9'
"$VENV_DIR/bin/litellm" --version || die "litellm failed to install"

# --- configs (never clobber existing ones) -----------------------------------
# Secrets live only in ~/.config/cc-hybrid, never in the repo: the repo ships
# .example templates and these become the real files on first install.
for f in litellm.env tunnel.env; do
  if [ -f "$CONF_DIR/$f" ]; then
    log "Keeping existing $CONF_DIR/$f"
  else
    install -m 600 "$SRC_DIR/$f.example" "$CONF_DIR/$f"
    log "Installed $CONF_DIR/$f"
  fi
done

# The router config holds no secrets, so refresh it from the repo on every run
# and keep a backup if it was edited locally.
if [ -f "$CONF_DIR/litellm-config.yaml" ] \
   && ! cmp -s "$SRC_DIR/litellm-config.yaml" "$CONF_DIR/litellm-config.yaml"; then
  cp "$CONF_DIR/litellm-config.yaml" "$CONF_DIR/litellm-config.yaml.bak"
  chmod 600 "$CONF_DIR/litellm-config.yaml.bak"
  log "Existing litellm-config.yaml differed; backed it up to litellm-config.yaml.bak"
fi
install -m 600 "$SRC_DIR/litellm-config.yaml" "$CONF_DIR/litellm-config.yaml"
log "Installed $CONF_DIR/litellm-config.yaml"

# Generate a real master key if the placeholder is still there.
if grep -q 'CHANGE-ME' "$CONF_DIR/litellm.env"; then
  key="sk-local-$(openssl rand -hex 24)"
  sed -i "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$key|" "$CONF_DIR/litellm.env"
  log "Generated a LiteLLM master key"
fi
chmod 600 "$CONF_DIR"/*.env

# --- systemd user units ------------------------------------------------------
install -m 644 "$SRC_DIR/cc-tunnel.service"  "$UNIT_DIR/cc-tunnel.service"
install -m 644 "$SRC_DIR/cc-litellm.service" "$UNIT_DIR/cc-litellm.service"
systemctl --user daemon-reload
systemctl --user enable cc-tunnel cc-litellm
log "Installed and enabled cc-tunnel and cc-litellm"

# --- wrappers ----------------------------------------------------------------
for w in cc-local cc-cloud cc-status; do
  install -m 755 "$SRC_DIR/bin/$w" "$BIN_DIR/$w"
done
log "Installed cc-local, cc-cloud, cc-status to $BIN_DIR"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) log "NOTE: $BIN_DIR is not on your PATH. Add to ~/.bashrc:"
     echo "        export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

cat <<EOF

Laptop side installed.

Before starting, edit the SSH target:
    \$EDITOR $CONF_DIR/tunnel.env        # set SSH_TARGET

Make sure key-based SSH to the node works without a prompt:
    ssh \$(grep ^SSH_TARGET $CONF_DIR/tunnel.env | cut -d= -f2) true

Then:
    systemctl --user start cc-tunnel cc-litellm
    cc-status
    cc-local

EOF
