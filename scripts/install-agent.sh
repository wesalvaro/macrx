#!/bin/bash
# Installs (or updates) macrx as a launchd user agent: copies the signed binary to a
# stable path, writes the plist, and (re)starts the service.
#
# Usage: scripts/install-agent.sh <built-binary>
set -euo pipefail

SRC="${1:?usage: install-agent.sh <binary>}"
LABEL="dev.macrx.macrx"
INSTALL_DIR="$HOME/.local/bin"
BIN="$INSTALL_DIR/macrx"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

mkdir -p "$INSTALL_DIR" "$(dirname "$PLIST")"
# Copy to a temp file and rename so a running instance keeps its old inode.
cp "$SRC" "$BIN.new" && mv -f "$BIN.new" "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LANG</key>
    <string>en_US.UTF-8</string>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/macrx.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/macrx.log</string>
</dict>
</plist>
EOF

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  # Already loaded: restart so the new binary (and plist) take effect.
  launchctl bootout "$DOMAIN/$LABEL" || true
  # bootout is asynchronous; bootstrapping while the old job is still being torn down
  # fails with "Input/output error" (5). Wait for it to disappear.
  for _ in $(seq 1 50); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi
for attempt in 1 2 3 4 5; do
  if launchctl bootstrap "$DOMAIN" "$PLIST"; then break; fi
  [ "$attempt" -eq 5 ] && { echo "error: could not bootstrap $LABEL" >&2; exit 1; }
  sleep 0.5
done
echo "installed $LABEL → $BIN (log: /tmp/macrx.log)"
