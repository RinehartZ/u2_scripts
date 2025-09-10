#!/usr/bin/env bash
set -euo pipefail

# One-click installer for u2_magic.py as a systemd service with Python venv
# Steps:
# 1) Download u2_magic.py to /root/u2_scripts via wget/curl (or copy from local if no URL)
# 2) Create venv and install dependencies
# 3) Create and enable systemd service
#
# Usage:
#   sudo ./install_u2_magic_service.sh \
#     [--python /usr/bin/python3] [--user youruser] [--name u2-magic] [--url https://.../u2_magic.py] [--dir /root/u2_scripts]

SERVICE_NAME="u2-magic"
RUN_USER="$(logname 2>/dev/null || echo ${SUDO_USER:-${USER}})"
PYTHON_BIN=""
SRC_URL="https://raw.githubusercontent.com/RinehartZ/u2_scripts/refs/heads/main/u2_magic.py"
WORKDIR="/root/u2_scripts"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python)
      PYTHON_BIN="$2"; shift 2;;
    --user)
      RUN_USER="$2"; shift 2;;
    --name)
      SERVICE_NAME="$2"; shift 2;;
    --url)
      SRC_URL="$2"; shift 2;;
    --dir)
      WORKDIR="$2"; shift 2;;
    *)
      echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

mkdir -p "$WORKDIR"
chown "$RUN_USER":"$RUN_USER" "$WORKDIR"

SCRIPT_PATH="$WORKDIR/u2_magic.py"

fetch_script() {
  if [[ -n "$SRC_URL" ]]; then
    if command -v wget >/dev/null 2>&1; then
      wget -O "$SCRIPT_PATH" "$SRC_URL"
    elif command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$SCRIPT_PATH" "$SRC_URL"
    else
      echo "Neither wget nor curl is installed. Please install one or provide local file." >&2
      exit 1
    fi
  else
    # Fallback: copy from local workspace if exists
    if [[ -f "/workspace/u2_magic.py" ]]; then
      cp "/workspace/u2_magic.py" "$SCRIPT_PATH"
    elif [[ -f "./u2_magic.py" ]]; then
      cp "./u2_magic.py" "$SCRIPT_PATH"
    else
      echo "No --url provided and cannot find local u2_magic.py to copy." >&2
      exit 1
    fi
  fi
  chown "$RUN_USER":"$RUN_USER" "$SCRIPT_PATH"
}

fetch_script

# Choose python
if [[ -z "$PYTHON_BIN" ]]; then
  for cand in /usr/bin/python3.11 /usr/local/bin/python3.11 /usr/bin/python3 /usr/local/bin/python3; do
    if [[ -x "$cand" ]]; then PYTHON_BIN="$cand"; break; fi
  done
fi
if [[ -z "$PYTHON_BIN" ]]; then
  echo "Python3 not found. Install Python 3.11+ first." >&2
  exit 1
fi

VENVDIR="$WORKDIR/.venv_u2_magic"
sudo -u "$RUN_USER" bash -c "cd $WORKDIR && $PYTHON_BIN -m venv $VENVDIR"

# Upgrade pip and install deps
REQ_PKGS=(
  requests bs4 lxml deluge-client loguru func-timeout pytz nest_asyncio aiohttp paramiko qbittorrent-api
)
sudo -u "$RUN_USER" bash -c "$VENVDIR/bin/pip install --upgrade pip wheel setuptools"
sudo -u "$RUN_USER" bash -c "$VENVDIR/bin/pip install ${REQ_PKGS[*]}"

# Create a wrapper
WRAPPER="$WORKDIR/run_u2_magic.sh"
cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /root/u2_scripts
exec /root/u2_scripts/.venv_u2_magic/bin/python /root/u2_scripts/u2_magic.py
EOF
chown "$RUN_USER":"$RUN_USER" "$WRAPPER"
chmod +x "$WRAPPER"

# Prepare systemd unit
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=U2 Magic Service (u2_magic.py)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${WORKDIR}
ExecStart=${WRAPPER}
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "Downloaded u2_magic.py to: $SCRIPT_PATH"
echo "Installed and started service: $SERVICE_NAME"
echo "Logs: journalctl -u $SERVICE_NAME -f | cat"
