#!/bin/zsh
# Stop kvm-follow and remove it.
set -uo pipefail

label="com.kvm-follow"
launchctl bootout "gui/$UID/$label" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/.local/bin/kvm-follow"
rm -rf "$HOME/.config/kvm-follow"
echo "kvm-follow removed."
