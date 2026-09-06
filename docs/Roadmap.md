# Roadmap

Portage par tranches verticales, chacune testable indépendamment.

## Phase 0 — Squelette + shims — **fait**

- [x] `package/metadata.json` (Plasma/Applet, KF6)
- [x] `CliProcess.qml` (argv → shell échappé sur `Plasma5Support.DataSource`)
- [x] `FileIo.qml` (lecture/écriture via `CliProcess`)
- [x] `main.qml` minimal (PlasmoidItem, icône + statut compact)

## Phase 1 — Statut, connexion, notifications — **fait**

- [x] `Service.qml` : détection installation (`which protonvpn`, conflit
      `proton-vpn-gtk-app`)
- [x] Poll `nmcli` (lien rapide) + `protonvpn status`/`info` à la demande
- [x] Connect fastest / disconnect, état optimiste (`_desired`)
- [x] Notifications D-Bus (`busctl` inchangé)
- [x] `FullRepresentation.qml` minimal : statut, bouton connect/disconnect,
      compte

Non porté dans cette phase : pays/ville, Secure Core/Tor/P2P, Always On,
recents, config kill-switch/NetShield/port-forwarding, split tunneling.

## Phase 2 — Carte, trafic, sélecteur pays/ville — **fait**

- [x] `WorldMap.qml` + `World.js` (quasi tel quel, `Shape`/QML pur)
- [x] `Traffic.qml` (sparkline, quasi tel quel)
- [x] Liste pays/ville (`protonvpn countries list`, `servers.py`), recherche,
      drill-down ville par pays — vérifié en direct (carte, filtre, liste de
      villes par pays)
- [x] Connect random/country/server/P2P/Secure Core/Tor (`connectTo`
      généralisé, `change.py` pour les hops free-plan)
- [ ] Badges PLUS sur les pays sans ville gratuite (`Model.countryNeedsPlus`
      existe déjà, pas encore câblé dans la liste — laissé pour une passe de
      polish, pas bloquant)

Non porté dans cette phase : recents (persistance), tags Secure
Core/route sur la carte au-delà de l'affichage de base.

## Phase 3 — Kill Switch, NetShield, Always On, port forwarding — **fait** (hors split tunneling)

- [x] `protonvpn config set/list` (kill-switch, netshield, port-forwarding),
      cycle kill-switch (disconnect → set → reconnect fastest, la seule
      manière dont le CLI accepte ce réglage)
- [x] Always On (reconciliation sur le poll nmcli existant, backoff 30s sur
      échec, `_autoHold` sur déconnexion manuelle)
- [x] Port forwarding NAT-PMP (`port.py`), renouvellement 45s, copie du port
- [ ] Split tunneling (`apps.py`, édition de `settings.json` de Proton) —
      **reporté explicitement** : nécessite son propre sélecteur d'apps et
      une lecture/écriture prudente d'un fichier qui n'est pas le nôtre ;
      pas fait dans cette passe pour ne pas la bâcler. Reste en phase 4.

Non vérifié en direct : Kill Switch et Always On déclenchent une vraie
déconnexion/reconnexion CLI, avec le même effet de bord réseau que "Connect"
— à tester à un moment où couper temporairement la session ne gêne pas.

## Phase 4 — Split tunneling, sign-in, persistance de session — **fait** (hors réglages Plasmoid)

- [x] Split tunneling : lecture/écriture async de `settings.json` de Proton
      (`FileIo`, jamais de champ touché hors `features.split_tunneling`),
      mode Exclude/Include, sélecteur d'apps (`apps.py`, liste + `--expand`),
      case à cocher par app avec resynchronisation sur écriture concurrente
- [x] Flux de sign-in : `launchTerminal()` essaie `konsole -e`, repli `xterm`
      (remplace `omarchy-launch-floating-terminal-with-presentation`) ;
      mot de passe/2FA tapés dans ce terminal, jamais vus par le widget
- [x] `sanitize_keyring.py --persist` (persistance session Proton au
      redémarrage), appelé au sign-in et à chaque confirmation "signed in"
      (limité à 1×/60s)
- [x] Bouton "Sign out" (`protonvpn signout`)
- [ ] Résolution `omarchy-install-app` → laissé tel quel (message d'invite
      manuelle "installe proton-vpn-cli puis Refresh", décidé en phase 1 :
      pas d'auto-install `pacman` sans confirmation depuis le widget)
- [ ] Schéma de config Plasmoid (refresh interval, watch interval,
      notifications on/off) via `Plasmoid.configuration` — pas fait, les
      valeurs par défaut codées dans `Service.qml` suffisent pour l'instant

Non vérifié en direct : le flux de sign-in complet (nécessite un compte
Proton qui n'est pas encore connecté) et l'écriture réelle de
`settings.json` par un clic sur une case à cocher d'app.

## Phase 5 — Packaging, install, tests

Diffusion décidée le 2026-09-06 : Store KDE (store.kde.org), avec un dépôt
GitHub dédié comme source/Website.

- [x] Id définitif choisi et appliqué : `com.github.thongor77.protonvpn`
      (`package/metadata.json` — `Authors`/`Website`/`Bugs` renseignés aussi)
- [x] Dépôt GitHub créé : https://github.com/thongor77/plasmoid-protonvpn
- [ ] Script d'installation (`kpackagetool6 --install`)
- [ ] Reprise des tests upstream (`tests/`) adaptés au nouveau layout
- [ ] `plasmoidviewer` (installer `plasma-sdk`) pour test visuel manuel
- [x] LICENSE (MIT, crédits upstream)
- [ ] Soumission sur store.kde.org (upload manuel via leur formulaire web —
      pas automatisable depuis ici) : captures dans `screenshot/` déjà
      disponibles à joindre à la fiche
