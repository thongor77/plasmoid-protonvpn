#!/usr/bin/env bash
set -euo pipefail

# Installs (or upgrades) the Proton VPN Plasmoid into the current user's
# KDE Plasma 6 session, and checks for the external tools Service.qml
# shells out to. Never installs anything via a package manager itself —
# per docs/Roadmap.md phase 1's own rule for the widget, applied here too:
# missing dependencies are reported, not silently pulled in.

PACKAGE_ID="com.github.thongor77.protonvpn"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/package"

if ! command -v kpackagetool6 >/dev/null 2>&1; then
  echo "Error: kpackagetool6 not found — this plasmoid needs a KDE Plasma 6 session." >&2
  exit 1
fi

missing=()
command -v protonvpn >/dev/null 2>&1 || missing+=("protonvpn (proton-vpn-cli — e.g. from the AUR)")
command -v python3 >/dev/null 2>&1 || missing+=("python3")
command -v nmcli >/dev/null 2>&1 || missing+=("nmcli (NetworkManager — used for fast link status)")
command -v busctl >/dev/null 2>&1 || missing+=("busctl (systemd — desktop notifications)")
if ! command -v konsole >/dev/null 2>&1 && ! command -v xterm >/dev/null 2>&1; then
  missing+=("konsole or xterm (needed for the interactive sign-in prompt)")
fi
command -v wl-copy >/dev/null 2>&1 || missing+=("wl-copy (wl-clipboard — only needed to copy a forwarded port)")

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Warning: the widget will install, but these features won't work until you install:"
  for m in "${missing[@]}"; do echo "  - $m"; done
  echo
fi

if kpackagetool6 --type Plasma/Applet --show "$PACKAGE_ID" >/dev/null 2>&1; then
  echo "Upgrading existing $PACKAGE_ID…"
  kpackagetool6 --type Plasma/Applet --upgrade "$PACKAGE_DIR"
else
  echo "Installing $PACKAGE_ID…"
  kpackagetool6 --type Plasma/Applet --install "$PACKAGE_DIR"
fi

echo
echo 'Done. Add "Proton VPN" from your panel'"'"'s widget picker to use it.'
echo "If it was already on a panel under the old package Id, remove that broken"
echo "instance and add it back fresh — Plasma doesn't recover it automatically."
