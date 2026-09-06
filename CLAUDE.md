# CLAUDE.md — protonVPN

## Description

Portage natif Plasma 6 (Plasmoid) du widget [omarchy-proton-vpn](https://github.com/iamfitsum/omarchy-proton-vpn),
qui pilote le CLI officiel `protonvpn`.

## Stack

QML (Plasma 6 / `org.kde.plasma.plasmoid`), `Plasma5Support.DataSource`
(remplace `Quickshell.Io.Process`/`FileView` de l'upstream), scripts Python
repris tels quels de l'upstream (`servers.py`, `change.py`, `apps.py`,
`port.py`, `sanitize_keyring.py`), CLI `protonvpn` + `nmcli`.

## État actuel

En développement — portage initial en cours. Voir `docs/Roadmap.md`.

## Lancer le projet

```bash
plasmoidviewer -a package        # nécessite plasma-sdk (non installé au 2026-09-05)
kpackagetool6 --type Plasma/Applet --install package
```

**Important : le paquet installé est une copie, pas un lien symbolique.**
`~/.local/share/plasma/plasmoids/local.protonvpn/` est indépendant de ce
dépôt — éditer les fichiers ici n'a aucun effet tant que le paquet n'est pas
réinstallé. Après toute modification sous `package/`, il faut lancer :

```bash
kpackagetool6 --type Plasma/Applet --upgrade package
systemctl --user restart plasma-plasmashell.service
```

(`--upgrade`, pas `--install`, une fois le paquet déjà présent). Oublier
cette étape et se contenter de recharger plasmashell fait tourner l'ancien
code sans le moindre message d'erreur — piège vécu le 2026-09-05, où un bug
a été diagnostiqué à tort comme non corrigé alors que le correctif n'avait
simplement jamais été déployé.

## Architecture

Voir `docs/Architecture.md`. Résumé : un paquet Plasmoid standard
(`package/metadata.json` + `package/contents/ui/`), avec un composant service
central (`Service.qml`) qui pilote des sous-processus CLI via un shim
`CliProcess.qml` (argv-list → shell échappé, `Plasma5Support.DataSource`
dessous) et l'IO fichier via `FileIo.qml`.

## Décisions techniques

Voir `docs/Decisions-Techniques.md`. Décision structurante : `CliProcess.qml`
échappe chaque argument avant de construire la chaîne shell envoyée à
`DataSource`, pour préserver la garantie de sécurité de l'argv-list Quickshell
d'origine (le CLI upstream ne fait confiance qu'à un seul point de passage
shell, pour le nom d'utilisateur).

## Roadmap

Voir `docs/Roadmap.md`. Le port se fait par tranches verticales : (0) squelette
+ shims, (1) statut/connexion/notifications, (2) carte + trafic, (3) split
tunneling + port forwarding, (4) réglages + première connexion, (5) script
d'installation/empaquetage.

## Conventions spécifiques

- Aucune, au-delà de `META/Standards.md`. Les scripts Python et `Model.js`
  sont repris tels quels de l'upstream (logique indépendante du DE) : ne pas
  les réécrire sans raison.
- Chaque appel externe (CLI, fichiers) passe par `CliProcess.qml`/`FileIo.qml`
  — ne pas réintroduire d'exécution shell ad hoc ailleurs dans le code.
