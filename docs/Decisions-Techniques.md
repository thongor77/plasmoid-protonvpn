# Décisions techniques

## CliProcess.qml : shim argv → shell échappé sur Plasma5Support.DataSource

**Contexte.** L'upstream utilise `Quickshell.Io.Process`, qui exécute un
tableau argv directement (`QProcess`-like), sans jamais passer par un shell.
Le code d'origine s'appuie explicitement sur cette garantie : un seul
commentaire dans `Service.qml` note que le nom d'utilisateur est le "seul
endroit où une valeur traverse une frontière shell", et il est alors
whitelisté par regex (`Model.js: validUsername`) puis quoté (`shellQuote`)
avant d'atteindre le lanceur de terminal.

`Plasma5Support.DataSource` (moteur `executable`), le remplacement standard
KDE pour exécuter des commandes en QML pur sans plugin C++, ne prend qu'une
**chaîne** shell (il supporte pipes/redirections par conception). Un portage
naïf qui construirait cette chaîne par concaténation directe réintroduirait
de l'injection shell partout où une valeur dynamique existe (chemins
d'application pour le split tunneling, clé/valeur de config, nom de
serveur), pas seulement au point unique que l'upstream protège.

**Décision.** `CliProcess.qml` garde l'API ergonomique de `Process`
(`command: [...]` en argv, `running`, `exited(exitCode)`, `stdoutText`/
`stderrText`) mais échappe **chaque élément** du tableau en single-quotes
POSIX avant de les joindre et de les passer à `DataSource.connectSource()`.
Chaque site d'appel se porte donc quasi mécaniquement (`Process {` →
`CliProcess {`), sans devoir ré-auditer l'échappement à chaque fois.

**Alternatives considérées**
- Concaténer à la main à chaque site d'appel → rejeté, trop facile d'oublier
  un cas, exactement le risque que l'upstream évite par construction.
- Écrire un petit plugin C++ (`QProcess` exposé en QML) → rejeté pour l'instant :
  ajoute une dépendance de build (CMake, dev headers Plasma) alors que
  `Plasma5Support.DataSource` est déjà présent runtime sans rien à compiler.
  À reconsidérer si l'échappement shell s'avère limitant (ex. pas de vrai
  contrôle des flux stdin/stdout par gros volume).

**Conséquences.** Toute nouvelle commande ajoutée au projet doit passer par
`CliProcess`, jamais par une concaténation shell directe. Voir
`CLAUDE.md` → Conventions spécifiques.

## FileIo.qml : shim fichier au-dessus de CliProcess

**Contexte.** `Quickshell.Io.FileView` (lecture réactive + écriture atomique)
n'a pas d'équivalent QML pur en Plasma.

**Décision.** Lecture via `cat -- <path>` (échappé par `CliProcess`), écriture
atomique via `printf '%s' <contenu-quoté> > <tmp> && mv <tmp> <path>` — même
mécanisme que Quickshell (écrire à côté puis renommer), au travers de
`CliProcess` pour garder un seul point d'échappement dans le projet.

## Variables d'environnement

`Quickshell.env()` n'a pas d'équivalent QML pur. Résolues une fois au
démarrage via `CliProcess` (`sh -c 'echo "$HOME|$XDG_STATE_HOME|$XDG_CONFIG_HOME"'`),
plutôt que de coder en dur `~/.local/state` : préserve le comportement de
l'upstream pour un utilisateur qui a personnalisé ses XDG dirs.

## Binaires spécifiques à Omarchy

| Upstream | Remplacement Plasma |
|---|---|
| `omarchy-install-app` | `pacman -S` direct (ou message invitant l'utilisateur, si on préfère ne pas appeler sudo depuis le widget — à trancher phase 4) |
| `omarchy-launch-floating-terminal-with-presentation` | `konsole -e <cmd>`, repli `xdg-terminal-exec` si `konsole` absent |

Ces deux points sont traités en phase 4 (voir Roadmap) — pas encore portés.

## Cible Plasma

Plasma 6 / KF6 uniquement (`kpackagetool6` confirmé présent ; pas de
`plasma-framework`/KF5 sur cette machine). Pas de rétro-compatibilité Plasma 5
prévue.

## Bugs trouvés pendant la mise au point de la phase 1 (à ne pas réintroduire)

Trois bugs distincts, tous découverts en déboguant "le widget ne détecte pas
le CLI même après un refresh" — gardés ici car aucun n'est évident et les
trois se sont combinés pour rendre le diagnostic difficile.

1. **`metadata.json` sans `"KPackageStructure": "Plasma/Applet"`** — champ
   racine obligatoire (à côté de `KPlugin`, pas dedans) sur Plasma 6/KF6.
   Sans lui, `plasmashell` charge quand même le paquet (avec un warning dans
   le journal) mais `kpackagetool6 --list/--upgrade/--remove` ne le reconnaît
   plus après coup ("Plugin ... is not installed"), alors que
   `--show <id>` le trouve très bien. Confirmé en comparant avec deux
   plasmoides tiers déjà installés sur la machine de test
   (`org.scelles.tailscale`, `com.github.p3kj.claudemeter`), qui l'ont tous
   les deux.

2. **Collision de nom d'id/propriété en QML** — `main.qml` déclarait
   `Code.Service { id: service }` puis `FullRepresentation { service: service }`.
   `FullRepresentation.qml` déclare lui-même `property var service`, donc le
   `service` à droite du `:` se résout dans la portée de l'objet en cours de
   création (qui a déjà sa propre propriété `service`) plutôt que vers l'id
   du document englobant. Résultat : la propriété ne recevait jamais la
   vraie instance (`root.service` valait `undefined` en permanence côté UI),
   alors que le `Service` tournait bel et bien en arrière-plan (d'où le
   polling `nmcli`/`protonvpn status` visible dans les logs pendant que
   l'interface affichait encore "CLI not found"). **Règle : ne jamais nommer
   un id comme la propriété du composant enfant à qui on le passe.** Fixé en
   renommant l'id en `vpn` dans `main.qml`.

3. **Le moteur `executable` de `Plasma5Support.DataSource` identifie une
   commande par sa chaîne littérale.** Deux appels concurrents avec le même
   texte de commande (deux instances du widget, ou deux pollers internes qui
   se chevauchent) peuvent se marcher dessus : un second `connectSource()`
   sur un nom déjà "connecté" peut ne rien redéclencher, privant son appelant
   de résultat. `CliProcess.qml`/`Cmd.qml` ajoutent maintenant un commentaire
   shell inerte (`# <horodatage>-<compteur>-<aléatoire>`) en fin de chaîne
   pour rendre chaque invocation unique, sans changer ce qui s'exécute
   réellement.

Diagnostiquer ces trois-là a nécessité de faire tourner `plasmashell
--replace &` en premier plan dans un terminal (`journalctl -f` s'est révélé
peu fiable pour du suivi en direct dans cette session) : `console.log()` en
QML n'apparaît que là, jamais dans les tests `qml6` isolés lancés depuis un
environnement sandboxé sans vrai accès à la session graphique.

## Bug : la fenêtre de sign-in ne se fermait pas malgré un succès (phase 4)

**Symptôme.** `Service.qml: launchTerminal()` décide de garder la fenêtre
ouverte (`exec sh`) uniquement si le code de sortie de la commande est
non nul. En usage réel, l'utilisateur voyait `Successfully signed in as
'...'` s'afficher puis un prompt shell rester ouvert, alors qu'un test
manuel de la même commande `protonvpn signin <compte>` en dehors du widget
rendait bien un code de sortie 0.

**Cause.** Le widget interroge le CLI en arrière-plan pendant tout le temps
où la fenêtre de sign-in interactive est ouverte (`signInWatch`, toutes les
3 s, et `statusTimer`) : plusieurs processus `protonvpn` tournent donc en
concurrence sur le même état local (session/keyring). Ce chevauchement peut
faire remonter un code de sortie non nul sur le process interactif alors
que l'authentification a réellement réussi (le message de succès est bien
affiché avant que ce code corrompu ne soit lu). Reproduit et confirmé côté
utilisateur (capture d'écran) : message de succès suivi d'un prompt shell
inattendu.

**Décision.** `signIn()` ne fait plus confiance aveuglément au code de
sortie de `protonvpn signin`. En cas de code non nul, il revérifie l'état
réel via `protonvpn info | grep -qF "'$u'"` (le compte que l'on vient
d'essayer apparaît-il bien comme connecté ?) avant de décider de garder la
fenêtre ouverte. `grep -F` (chaîne fixe, pas de glob/regex) rend cette
vérification sûre même pour le nom d'utilisateur saisi librement dans la
branche "prompt vide" (non filtré par `Model.validUsername`). Le nom
d'utilisateur testé doit être dans la variable shell `$u` dans les deux
branches de `signIn()` (nommée directement, ou lue via `read`) puisque la
vérification s'appuie dessus par convention de nom.

**Alternative rejetée.** Ignorer complètement le code de sortie et ne se
fier qu'à `protonvpn info` → rejeté : une vraie erreur d'authentification
(mauvais mot de passe) ou un "already signed in" sur un **autre** compte
doivent continuer à laisser la fenêtre ouverte pour que l'utilisateur lise
le message ; comparer explicitement au compte visé (`$u`) évite de masquer
ces cas.

## Bug : un loader restait bloqué sur "Loading…" jusqu'à un restart complet de plasmashell

**Symptôme.** Observé deux fois indépendamment (deux machines différentes) :
après un sign-in, la carte du monde (phase 2) ne s'affichait jamais, alors
que `python3 servers.py --cities` fonctionnait parfaitement en ligne de
commande contre le même cache. Rouvrir le widget (fermer/rouvrir le popup)
ne suffisait pas ; seul un `systemctl --user restart plasma-plasmashell`
débloquait la situation.

**Cause.** `Service.qml: loadCities()` protège contre les appels concurrents
via `if (citiesProcess.running) return`. Si la réponse du
`Plasma5Support.DataSource` (moteur `executable`) sous-jacente au tout
premier appel se perd silencieusement — observé en pratique, cause exacte
non confirmée côté Plasma5Support — `citiesProcess.running` reste bloqué
à `true` **indéfiniment** : ce garde-fou empêche alors tout nouvel essai,
même à la réouverture du panel, puisque rien ne remet jamais `running` à
`false`. Seul un restart complet de plasmashell recrée l'instance QML et
donc réinitialise l'état.

**Décision.** `CliProcess.qml` (le shim partagé par tous les appels CLI du
projet) a maintenant un `Timer` de sécurité (`timeoutMs`, 20s par défaut,
surchageable par site d'appel) : si aucune réponse n'arrive dans ce délai,
il déconnecte proprement la source, force `running = false` et émet
`exited(-1)` comme un échec ordinaire. Un appelant bloqué se débloque donc
tout seul au prochain déclenchement naturel (réouverture du panel, poll
suivant, clic sur Refresh) au lieu de nécessiter un restart de plasmashell.

**Alternative rejetée.** Ajouter une retry automatique dans
`loadCities()`/`onExited` directement → rejeté pour l'instant : risque de
boucle si la cause sous-jacente est permanente plutôt que transitoire: le
timeout dans le shim commun suffit à débloquer l'état sans complexifier
chaque site d'appel, et laisse le rechargement naturel (panel, poll) faire
office de retry.

## Taille du popup (`FullRepresentation.qml`) : fixe plutôt que redimensionnable

**Contexte.** L'ajout du bloc Server/Location/Load/Protocol a fait déborder
le contenu hors du popup sur une instance déjà placée (widget KDE Linux) :
Plasma ne redimensionne le popup depuis `implicitHeight` qu'au tout premier
placement, puis retient la taille glissée par l'utilisateur — un widget déjà
en place ne profite donc jamais d'une augmentation ultérieure
d'`implicitHeight` sans redimensionnement manuel.

**Décision.** `Layout.minimumWidth`/`maximumWidth` et
`Layout.minimumHeight`/`maximumHeight` sont fixés à `implicitWidth`/
`implicitHeight` sur l'item racine de `FullRepresentation.qml` : le popup
est désormais de taille fixe (`gridUnit * 22` × `gridUnit * 39`), non
redimensionnable par l'utilisateur, et donc toujours exactement à la bonne
taille sur chaque instance/reload — plus de dérive possible entre le code
et une instance existante.

**Conséquence à surveiller.** Toute future addition de contenu vertical
(nouvelle section, nouveau bloc conditionnel) doit revérifier
`implicitHeight` en conditions réelles (état connecté, split tunneling
déplié, etc.) puisqu'il n'y a plus de marge de redimensionnement manuel de
secours pour l'utilisateur.
