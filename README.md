# Proton VPN Plasmoid

Repository: https://github.com/thongor77/plasmoid-protonvpn

A native KDE Plasma 6 widget for Proton VPN: connection status, country/city
picker, Kill Switch, NetShield, Always On, split tunneling, port forwarding,
and traffic monitoring — driven by the official `protonvpn` CLI.

## Why

[omarchy-proton-vpn](https://github.com/iamfitsum/omarchy-proton-vpn) is a
well-built Proton VPN control panel, but it targets Omarchy's Quickshell-based
bar (Quattro) and its own plugin manager. This project ports the same feature
set to a standard Plasma 6 applet (Plasmoid) that installs and runs like any
other widget in the Plasma panel or system tray, on any KDE Plasma 6 desktop.

## Status

**Early port, in progress.** See `docs/Roadmap.md` for what's done and what's
next.

## Stack

- QML / Plasma 6 applet API (`org.kde.plasma.plasmoid`)
- `Plasma5Support.DataSource` (executable engine) in place of Quickshell's
  `Process`/`FileView` — see `docs/Decisions-Techniques.md`
- Python 3 helper scripts (unchanged from upstream): server list, session-API
  server changes, split-tunnel app picker, NAT-PMP port renewal, keyring
  persistence
- Official `protonvpn` CLI + `nmcli` as the actual VPN backend

## Run / install

Development package lives in `package/`. To test locally once
`plasma-sdk` is installed (`sudo pacman -S plasma-sdk`):

```bash
plasmoidviewer -a package
```

To install into the user's Plasma session:

```bash
kpackagetool6 --type Plasma/Applet --install package
# after edits:
kpackagetool6 --type Plasma/Applet --upgrade package
```

This installs the applet as `com.github.thongor77.protonvpn` (see
`package/metadata.json`).

Then add the "Proton VPN" widget from the panel's widget picker.

## Credits

Ported from [omarchy-proton-vpn](https://github.com/iamfitsum/omarchy-proton-vpn)
by iamfitsum (MIT), itself adapted from
[OmaProton VPN](https://github.com/grichard99/omaproton-vpn) (MIT).
Not affiliated with Proton AG.

## License

MIT — see `LICENSE`.
