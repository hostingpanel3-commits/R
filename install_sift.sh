#!/usr/bin/env bash
# SiftNodes installer/configurator. Review before running; run as a normal user with sudo.
# This version keeps the existing bot flow but installs/configures LXC/LXD automatically.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

printf '\n=== SiftNodes VPS Bot Setup ===\n'

if [[ "${SIFT_SKIP_INSTALL:-0}" != "1" ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    echo '[1/4] Installing Python, LXC/LXD and required system packages...'
    $SUDO apt-get update
    $SUDO apt-get install -y python3 python3-venv python3-pip ca-certificates curl lxc lxd lxd-client bridge-utils

    # Some newer Ubuntu releases provide LXD through snap instead of apt.
    if ! command -v lxd >/dev/null 2>&1 || ! command -v lxc >/dev/null 2>&1; then
      echo 'LXD was not available from apt; installing the snap package...'
      $SUDO apt-get install -y snapd
      $SUDO snap install lxd
    fi

    echo '[2/4] Initializing LXD...'
    $SUDO systemctl enable --now lxd 2>/dev/null || true
    $SUDO systemctl enable --now snap.lxd.daemon 2>/dev/null || true
    $SUDO lxd waitready --timeout=60 2>/dev/null || true

    # Non-interactive equivalent of `lxd init` with a default storage pool and network.
    # If LXD is already initialized, --auto simply leaves the existing configuration alone.
    if ! $SUDO lxc storage list >/dev/null 2>&1; then
      $SUDO lxd init --auto
    else
      # A partially initialized installation can still need the automatic init.
      if [[ -z "$($SUDO lxc storage list --format csv 2>/dev/null || true)" ]]; then
        $SUDO lxd init --auto
      fi
    fi

    command -v lxc >/dev/null 2>&1 || { echo 'LXC command is unavailable after installation.' >&2; exit 1; }
    command -v lxd >/dev/null 2>&1 || { echo 'LXD command is unavailable after installation.' >&2; exit 1; }

    echo '[3/4] Creating isolated Python environment...'
    python3 -m venv venv
    ./venv/bin/python -m pip install --upgrade pip
    ./venv/bin/python -m pip install 'discord.py>=2.3,<3' 'aiohttp>=3.9,<4'
  else
    echo 'This installer currently supports Debian/Ubuntu apt systems.' >&2
    exit 1
  fi
fi

ENV_FILE="$PWD/sift.env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
setkv() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  grep -v "^${key}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
  chmod 600 "$ENV_FILE"
}

printf '\n[4/4] Configure bot settings\n'
read -r -p 'Website URL (e.g. https://terminal.example.com): ' URL
URL="${URL%/}"
if [[ ! "$URL" =~ ^https?://[^[:space:]]+$ ]]; then
  echo 'Invalid URL. Enter a full http:// or https:// URL.' >&2; exit 1
fi
read -r -p 'Owner Discord User ID (numeric): ' OWNER_ID
if [[ ! "$OWNER_ID" =~ ^[0-9]{15,22}$ ]]; then
  echo 'Invalid Discord ID. Enable Developer Mode and copy your user ID.' >&2; exit 1
fi
read -r -s -p 'Discord bot token (input hidden): ' TOKEN; echo
if [[ -z "$TOKEN" || "$TOKEN" == *$'\n'* ]]; then echo 'Bot token cannot be empty.' >&2; exit 1; fi

setkv SIFT_WEB_URL "$URL"
setkv SIFT_OWNER_ID "$OWNER_ID"
setkv DISCORD_TOKEN "$TOKEN"
unset TOKEN

printf '\nStarting SiftNodes...\n'
PY="$PWD/venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"
[[ -f "$PWD/sift-v4.py" ]] || { echo 'sift-v4.py not found beside installer.' >&2; exit 1; }

if command -v pgrep >/dev/null 2>&1; then
  while read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done < <(pgrep -f "${PY//\//\\/} ${PWD//\//\\/}/sift-v4.py" || true)
fi

nohup "$PY" "$PWD/sift-v4.py" >> "$PWD/sift.log" 2>&1 < /dev/null &
echo "Started. View logs: tail -f '$PWD/sift.log'"
echo "LXC/LXD is ready for VPS deployment."
echo "Config saved with permissions 600 in: $ENV_FILE"
echo 'Keep sift.env private; it contains your Discord bot token.'
