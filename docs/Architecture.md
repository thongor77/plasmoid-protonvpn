# Architecture

## Problème

`omarchy-proton-vpn` pilote le CLI `protonvpn` depuis un widget de barre
Quickshell, sur Omarchy uniquement. L'objectif ici est la même fonctionnalité
packagée comme un Plasmoid Plasma 6 standard, installable sur n'importe quel
KDE Plasma 6 (testé sur Arch, plasma-workspace 6.7.4).

## Utilisateurs

Utilisateur KDE Plasma avec un compte Proton VPN (gratuit ou Plus), qui veut
piloter le CLI officiel depuis un widget de panneau plutôt que le terminal ou
l'app GTK (incompatible avec le CLI — les deux ne tournent pas ensemble).

## Cas d'usage (repris de l'upstream)

- Voir l'état de la connexion (protégé / non protégé / en cours) dans la barre
- Se connecter au plus rapide / à un pays-ville / en aléatoire (clic droit /
  panneau)
- Activer Kill Switch, NetShield, Always On
- Split tunneling par application
- Port forwarding NAT-PMP sur serveur P2P
- Voir le débit du tunnel
- Rester connecté à Proton entre redémarrages sans re-saisir mot de passe/2FA

## Inconnues critiques et comment elles ont été tranchées

1. **Comment exécuter des sous-processus en QML pur dans un Plasmoid ?**
   Quickshell fournit `Process`/`FileView`, absents de l'environnement Plasma
   standard. `Plasma5Support.DataSource` (moteur `executable`, présent dans
   `plasma-workspace` 6.7.4 — `libPlasma5Support.so.6.7.4` confirmé installé)
   est la voie idiomatique KDE, mais exécute une **chaîne shell**, pas un
   tableau argv. → tranché par le shim `CliProcess.qml`, voir
   `Decisions-Techniques.md`.
2. **Lecture/écriture de fichiers (état persistant, icône de notification,
   settings.json de Proton pour le split tunneling) sans FileView ?**
   → même mécanisme, via un shim `FileIo.qml` qui shelle `cat`/`printf`+`mv`
   (écriture atomique) au travers de `CliProcess`.
3. **Variables d'environnement (`XDG_STATE_HOME`, `HOME`) sans l'API
   `Quickshell.env()` ?** → résolues une fois au démarrage via `CliProcess`
   (`sh -c 'echo "$HOME|$XDG_STATE_HOME|$XDG_CONFIG_HOME"'`), pas de nouvelle
   dépendance C++.
4. **Binaires spécifiques à Omarchy** (`omarchy-install-app`,
   `omarchy-launch-floating-terminal-with-presentation`) : n'existent pas hors
   Omarchy. → remplacés par `pacman`/AUR direct et un lanceur de terminal
   générique (`konsole -e` avec repli `xdg-terminal-exec`), voir Roadmap
   phase 4.
5. **Outillage de test local** : `plasmoidviewer` (paquet `plasma-sdk`,
   dispo dans `extra`) n'est pas installé sur cette machine au 2026-09-05 —
   à installer avant de tester visuellement (`sudo pacman -S plasma-sdk`).

## Structure cible

```
package/                          # racine du paquet Plasmoid
├── metadata.json                 # KPlugin + X-Plasma-API, Id io.github.<user>.protonvpn-plasmoid
└── contents/
    ├── ui/
    │   ├── main.qml              # PlasmoidItem (compact + full representation)
    │   ├── CompactRepresentation.qml
    │   ├── FullRepresentation.qml # équivalent de Panel.qml
    │   ├── WorldMap.qml           # phase 2, quasi inchangé (Canvas pur)
    │   ├── Traffic.qml            # phase 2, quasi inchangé
    │   └── ProtonIcon.qml          # inchangé (chemin SVG)
    ├── code/
    │   ├── Service.qml            # état + logique, porté depuis l'upstream
    │   ├── CliProcess.qml          # shim exécution processus (nouveau)
    │   ├── FileIo.qml              # shim lecture/écriture fichier (nouveau)
    │   ├── Model.js                # inchangé (JS pur)
    │   └── World.js                # inchangé (JS pur, phase 2)
    └── scripts/
        ├── servers.py              # inchangé
        ├── change.py               # inchangé
        ├── apps.py                 # inchangé
        ├── port.py                 # inchangé
        └── sanitize_keyring.py     # inchangé
```

`Service.qml` garde le même rôle et les mêmes propriétés que l'upstream ; la
migration remplace les types Quickshell par les shims ci-dessus, sans changer
la state machine (polling nmcli rapide + `protonvpn status` à la demande,
`_desired` optimiste pendant les connect/disconnect, Always On comme un seul
invariant reconcilié par le poll existant).

## Notifications

`busctl --user call org.freedesktop.Notifications … Notify …` est l'API D-Bus
standard freedesktop, implémentée nativement par Plasma : conservée telle
quelle. Le hint `omarchy-glyph` (spécifique au démon de notif d'Omarchy) est
simplement laissé de côté, ignoré sans casse par Plasma.
