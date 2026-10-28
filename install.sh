#!/bin/zsh
# Build kvm-follow, write its config, and start it at login.
# usage: ./install.sh <other-mac-mouse-channel>   (1, 2 or 3)
set -euo pipefail

channel="${1:-}"
if [[ ! "$channel" =~ ^[123]$ ]]; then
  echo "usage: ./install.sh <other-mac-mouse-channel>   (the OTHER Mac's Easy-Switch channel: 1, 2 or 3)" >&2
  exit 1
fi

here="${0:A:h}"
bin="$HOME/.local/bin/kvm-follow"
label="com.kvm-follow"
plist="$HOME/Library/LaunchAgents/$label.plist"
logfile="$HOME/Library/Logs/kvm-follow.log"

if ! command -v swiftc >/dev/null; then
  echo "swiftc not found. Install the Command Line Tools first: xcode-select --install" >&2
  exit 1
fi

echo "Building..."
mkdir -p "${bin:h}"
swiftc -O "$here/Sources/kvm-follow.swift" -o "$bin"

"$bin" setup "$channel"

mkdir -p "${plist:h}"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$bin</string><string>watch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$logfile</string>
  <key>StandardErrorPath</key><string>$logfile</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID/$label" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$plist"

echo
echo "Installed and running. Log: $logfile"
echo "If macOS asks whether kvm-follow may use Bluetooth, click Allow."
