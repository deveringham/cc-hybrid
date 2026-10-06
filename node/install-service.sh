#!/usr/bin/env bash
# Install the llama-server systemd *user* service. Run ON THE QUADRO NODE.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="$HOME/.config/llama-server"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

mkdir -p "$UNIT_DIR" "$CONF_DIR"

if [ -f "$CONF_DIR/llama-server.env" ]; then
  log "Keeping existing $CONF_DIR/llama-server.env (edit it by hand to change settings)"
  # Repair a value written without quotes by an earlier version of this script.
  # systemd tolerates it, but `source` from a shell does not.
  if grep -qE '^EXTRA_ARGS=[^"'"'"'].*[[:space:]]' "$CONF_DIR/llama-server.env"; then
    sed -i 's|^EXTRA_ARGS=\(.*\)$|EXTRA_ARGS="\1"|' "$CONF_DIR/llama-server.env"
    log "Quoted EXTRA_ARGS in the existing env file"
  fi
else
  # systemd does not expand %h / $HOME inside an EnvironmentFile, so bake the
  # real home directory into the absolute paths now.
  sed "s|__HOME__|$HOME|g" "$SRC_DIR/llama-server.env.example" > "$CONF_DIR/llama-server.env"
  chmod 600 "$CONF_DIR/llama-server.env"
  log "Installed $CONF_DIR/llama-server.env"
fi

# Read the two paths we care about WITHOUT sourcing the file: a config file
# should never be able to execute anything just because we wanted to check it.
getval() {
  sed -n "s/^$1=//p" "$CONF_DIR/llama-server.env" | tail -1 | sed 's/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/'
}
CFG_LLAMA_BIN=$(getval LLAMA_BIN)
CFG_MODEL=$(getval MODEL)

[ -x "$CFG_LLAMA_BIN" ] || log "WARNING: LLAMA_BIN not executable: ${CFG_LLAMA_BIN:-unset}"
[ -f "$CFG_MODEL" ]     || log "WARNING: MODEL file not found: ${CFG_MODEL:-unset}
         Edit $CONF_DIR/llama-server.env and set MODEL to a real .gguf path.
         Find yours with:  find ~/llm/models -name '*.gguf'"

install -m 644 "$SRC_DIR/llama-server.service" "$UNIT_DIR/llama-server.service"
log "Installed $UNIT_DIR/llama-server.service"

systemctl --user daemon-reload
systemctl --user enable llama-server

# Without lingering, the user service dies when your SSH session closes.
# $USER is not guaranteed to be set (non-login shells, cron, some containers),
# and this script runs under `set -u`.
ME=$(id -un)
if ! loginctl show-user "$ME" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
  log "Enabling lingering so the service survives logout (sudo required)"
  sudo loginctl enable-linger "$ME"
fi

cat <<EOF

Installed. Now:

  1. Verify the MODEL path:   grep ^MODEL ~/.config/llama-server/llama-server.env
  2. Start:                   systemctl --user start llama-server
  3. Watch it load:           journalctl --user -u llama-server -f
  4. Health check:            curl -s localhost:8080/health

If it OOMs, lower CTX_SIZE to 32768 in the env file and restart.

EOF
