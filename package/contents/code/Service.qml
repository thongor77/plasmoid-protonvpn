import QtQuick
import org.kde.kirigami as Kirigami
import "Model.js" as Model

// Proton VPN state for the Plasmoid — ported from omarchy-proton-vpn's
// Service.qml (Quickshell). See docs/Decisions-Techniques.md for why every
// external command now goes through CliProcess/Cmd instead of
// Quickshell.Io.Process/execDetached.
//
// PHASE 1+2+3 SCOPE: install detection, link watch, status/account probing,
// connect actions (fastest/random/country/server/P2P/Secure Core/Tor),
// notifications, country/city picking, the world map, the traffic graph,
// Kill Switch/NetShield/port forwarding, and Always On. Split tunneling
// and the settings/sign-in flow are NOT ported yet — see docs/Roadmap.md
// phase 4. Properties/functions that exist only to support those are
// intentionally left out rather than half-wired. No on-disk persistence yet
// (recents, Always On's own setting, session survival across reboot): the
// Always On switch and recents both reset to off/empty on every plasmashell
// restart until phase 4 adds state.json.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false

  property bool installed: false
  // The GTK app and the CLI share one backend and can't run at the same
  // time; a user who installed the app from Proton's site hits an opaque
  // failure, so the panel warns instead.
  property bool gtkAppInstalled: false

  property bool signedIn: false
  // `protonvpn info` costs ~1s, so signedIn is false-but-unknown until the
  // first probe lands. Without this the widget briefly claims "Signed out"
  // over a tunnel that is plainly up.
  property bool accountProbed: false
  property string account: ""
  property string plan: ""
  readonly property bool plusPlan: Model.planIsPaid(plan)

  // nmcli-derived, fast
  property bool linkActive: false
  property string linkServer: ""
  property string linkDevice: ""

  // Whether the in-flight (or current) connect asked for a P2P server.
  property bool p2pRequested: false

  property var countries: []
  property bool countriesLoaded: false
  property bool _wantCountries: false

  // Every Proton city with coordinates, for the map. From the client's own
  // cache, so it exists as soon as the user has connected once.
  property var cities: []
  property bool citiesLoaded: false
  // {code, city, lat, lon, name} for the server we're on, or null.
  property var currentPlace: null
  property string _locatePending: ""

  // Server drill-down for one country, read from the client's own cache.
  property var servers: []
  property string serversCountry: ""
  property string serversCountryName: ""
  property bool serversLoading: false

  // Tunnel throughput, from the kernel's own counters for the tunnel
  // interface. Sampled once a second, only while the panel is open and a
  // tunnel is up.
  property var rxHistory: []
  property var txHistory: []
  property real rxRate: 0
  property real txRate: 0
  property real sessionRx: 0
  property real sessionTx: 0
  property int uptimeSec: 0
  property real _lastRx: -1
  property real _lastTx: -1
  property real _lastSampleMs: 0
  property real _linkUpMs: 0
  readonly property int trafficSamples: 60

  // `protonvpn config list`, keyed by setting name.
  property var config: ({})
  property bool configLoaded: false
  readonly property bool killSwitchOn: String(config["kill-switch"] || "") === "standard"
  readonly property bool netShieldOn: configLoaded && String(config["netshield"] || "off") !== "off"
  readonly property bool portForwardingOn: configLoaded && String(config["port-forwarding"] || "off") === "on"
  // The only values setConfig() will ever pass to the CLI.
  readonly property var configValues: ({
    "kill-switch": ["off", "standard"],
    "netshield": ["off", "malware-only", "malware-ads-trackers"],
    "port-forwarding": ["off", "on"]
  })
  property bool _wantConfig: false
  // "" unless that row is the one mid-change; cleared once the re-read
  // after a `config set` confirms it, which covers both CLI calls with one
  // flag rather than throwing the switch early and hoping.
  property string configPending: ""
  property string configPendingValue: ""
  property string _configKey: ""
  property string _configValue: ""

  function configPendingLabel(key) {
    if (configPending !== key) return ""
    return configPendingValue === "off" ? "Turning off…" : "Turning on…"
  }

  // Second step of a Kill Switch change: the CLI only accepts the setting
  // with the tunnel down, so a change while connected disconnects first,
  // sets it, then reconnects to fastest.
  property bool _ksCycle: false
  property string _ksValue: ""

  // The port Proton assigned on a P2P server, or "" when there isn't one.
  // Proton hands it out over NAT-PMP on the tunnel gateway and drops the
  // mapping unless renewed every ~60s; port.py does that exchange every 45s
  // while the switch is on and the tunnel is up (the guide's cadence).
  property string forwardedPort: ""
  readonly property string portScriptPath: Qt.resolvedUrl("../scripts/port.py").toString().replace(/^file:\/\//, "")
  readonly property bool portWanted: portForwardingOn && connected && linkActive && !busy

  onPortWantedChanged: {
    if (portWanted) refreshPort()
    else forwardedPort = ""
  }
  onConnectedChanged: if (!connected) forwardedPort = ""

  function refreshPort() {
    if (!portWanted || portProcess.running) return
    portProcess.command = ["python3", portScriptPath]
    portProcess.running = true
  }

  // Copy is the only thing the widget does with the port.
  function copyForwardedPort() {
    if (forwardedPort === "") return
    cmd.execDetached(["wl-copy", "--", forwardedPort])
  }

  // ── Always On ────────────────────────────────────────────────────────────
  // One invariant, not a set of triggers: if the switch is on and the tunnel
  // isn't up, bring it up. The nmcli poll that already runs for the bar icon
  // is the whole mechanism — no second watcher, no second process.
  property bool autoConnect: false
  readonly property bool autoReady: installed && signedIn && accountProbed && autoConnect
  readonly property int autoRetryMs: 30000
  property real _autoNextMs: 0
  property bool _autoAttempt: false
  // Manual disconnect while Always On: stay down until the user connects
  // again. Drops, boot, and kill-switch cycling still reconnect.
  property bool _autoHold: false

  function toggleAutoConnect() {
    autoConnect = !autoConnect
    _autoNextMs = 0
    if (autoConnect) _autoHold = false
    autoReconcile()
  }

  function autoReconcile() {
    if (!autoReady) return
    // The kill switch cycle drops the tunnel on purpose and puts it back
    // itself; Always On stepping in here would fight it.
    if (_ksCycle) return
    if (_autoHold) return
    if (connected || linkActive || busy) return
    if (_autoNextMs > 0 && Date.now() < _autoNextMs) return
    _autoAttempt = true
    connectTo([], "Reconnecting to fastest…")
  }

  // `protonvpn status`-derived, slow
  property bool statusConnected: false
  property bool statusConnecting: false
  property string statusText: "Checking…"
  property string serverName: ""
  property string location: ""
  property var fields: []

  property string actionStatus: ""
  property string lastError: ""
  property string pendingLabel: ""

  // -1 = follow reality; 0/1 = a requested state still catching up.
  property int _desired: -1
  property bool _changingServer: false
  property string _changeFromServer: ""
  property bool _expectDown: false
  property real _actionEndedMs: 0
  property real _watchStartedMs: 0

  readonly property bool connected: _desired === -1 ? (linkActive || statusConnected) : (_desired === 1)
  readonly property bool busy: actionProcess.running || connectProcess.running
  property bool _probeRunning: false
  readonly property bool cliBusy: _probeRunning || busy
  property bool _wantStatus: false
  property bool _wantAccount: false
  readonly property bool _probesPending: _wantStatus || _wantAccount || _wantCountries || _wantConfig

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property int watchIntervalSec: intSetting("watchIntervalSec", 4, 2, 60)
  readonly property bool notificationsOn: String(setting("notifications", "on")) !== "off"

  readonly property string displayServer: linkActive && linkServer !== "" ? linkServer : serverName
  readonly property string displayStatus: {
    if (!installed) return "Not installed"
    if (pendingLabel !== "") return pendingLabel
    if (connected) return "Protected"
    if (statusConnecting) return "Connecting…"
    if (!accountProbed) return "Checking…"
    if (!signedIn) return "Signed out"
    return "Not protected"
  }

  // Resolved once at startup via envProcess (see below); "" until then.
  property string stateDir: ""
  property string configHome: ""
  property real _lastPersistMs: 0
  readonly property string notificationIconPath: stateDir !== "" ? stateDir + "/notification-icon.svg" : ""
  readonly property string protonMarkPath: "m10.176 20.058.858-1.28 6.513-9.838c.57-.86.026-2.014-1.005-2.131L.378 4.95l8.373 15.055a.84.84 0 0 0 1.424.052h.001zM23.586 7.14l-9.662 14.61c-1.036 1.567-3.38 1.478-4.293-.162l-.093-.168c.3-.01.594-.086.855-.235a1.85 1.85 0 0 0 .612-.57l.86-1.28 6.516-9.844c.46-.694.525-1.56.173-2.314a2.375 2.375 0 0 0-1.899-1.364L.493 3.956l-.476-.054C-.163 2.392 1.101.95 2.784 1.143l18.991 2.16c1.856.21 2.835 2.289 1.812 3.838z"

  readonly property string scriptPath: Qt.resolvedUrl("../scripts/servers.py").toString().replace(/^file:\/\//, "")
  readonly property string changePath: Qt.resolvedUrl("../scripts/change.py").toString().replace(/^file:\/\//, "")
  readonly property string appsScriptPath: Qt.resolvedUrl("../scripts/apps.py").toString().replace(/^file:\/\//, "")
  readonly property string sanitizePath: Qt.resolvedUrl("../scripts/sanitize_keyring.py").toString().replace(/^file:\/\//, "")
  // The only argv a connect-by-name may carry: `--country US`, `--p2p`, or a
  // server name like US-TX#572.
  readonly property var connectArg: /^[A-Za-z0-9#-]{1,64}$/

  // ── Split tunneling ──────────────────────────────────────────────────────
  // Proton has no CLI command for this, so the widget edits Proton's own
  // settings file. The rules are strict: read it fresh, change nothing
  // outside `features.split_tunneling`, hand every other key back exactly
  // as found, and never create the file. A missing or unreadable file means
  // Proton has not run here yet.
  //
  // Two limits come from Proton, not from us: split tunneling is skipped
  // entirely while the kill switch is on, and an app already running when
  // the tunnel came up keeps using it until it restarts (sockets are marked
  // as they're created).
  readonly property string protonSettingsPath: (configHome !== "" ? configHome : "") + "/Proton/VPN/settings.json"
  property var protonSettings: null
  property bool splitLoaded: false
  property string splitError: ""
  property var _splitMutate: null
  // The CLI only ever writes settings.json from an explicit `config set`
  // (never on sign-in/connect) and deletes it again on sign-out, so a
  // freshly signed-in session usually has no file yet. One-shot per
  // sign-in: re-apply NetShield's own already-reported value once both
  // probes are in, which makes the CLI (re)create the file without
  // changing anything. Reset alongside `signedIn` going false.
  property bool _settingsBootstrapTried: false

  readonly property bool splitAvailable: splitLoaded && protonSettings !== null
  // Blocked until the CLI has confirmed the kill switch is off, not merely
  // until it has confirmed it's on: an unread config is not permission to
  // write.
  readonly property bool splitBlocked: !configLoaded || killSwitchOn
  readonly property bool splitOn: splitAvailable && splitSection()["enabled"] === true
  readonly property bool splitActive: splitAvailable && splitOn && !splitBlocked
  readonly property string splitMode: {
    var m = String(splitSection()["mode"] || "exclude")
    return m === "include" ? "include" : "exclude"
  }
  // App paths for the mode in force. Proton keeps a separate list per mode.
  readonly property var splitApps: splitAppsFor(splitMode)

  property var installedApps: []
  property bool installedAppsLoaded: false
  property var _pendingSplitApps: []

  function loadProtonSettings() {
    splitFile.readFile(protonSettingsPath)
  }

  function readProtonSettings(text) {
    var data = null
    try { data = JSON.parse(text) } catch (e) { data = null }
    // Unparsable is treated exactly like missing: never rewrite a file we
    // couldn't read, that would throw away whatever is in it.
    protonSettings = (data && typeof data === "object" && data["features"]) ? data : null
    splitLoaded = true
    maybeBootstrapProtonSettings()
  }

  function maybeBootstrapProtonSettings() {
    if (protonSettings !== null) return
    if (!signedIn || !configLoaded || !splitLoaded) return
    if (_settingsBootstrapTried) return
    if (busy || setConfigProcess.running || configPending !== "") return
    _settingsBootstrapTried = true
    setConfig("netshield", String(config["netshield"] || "off"))
  }

  function splitSection() {
    if (!protonSettings) return ({})
    var f = protonSettings["features"]
    var st = f ? f["split_tunneling"] : null
    return st ? st : ({})
  }

  function splitAppsFor(mode) {
    var byMode = splitSection()["config_by_mode"]
    var cfg = byMode ? byMode[mode] : null
    var paths = cfg ? cfg["app_paths"] : null
    if (!paths || typeof paths.length !== "number") return []
    var out = []
    for (var i = 0; i < paths.length; i++) out.push(String(paths[i]))
    return out
  }

  function splitDescription() {
    if (!splitLoaded) return "Loading…"
    if (!splitAvailable) return signedIn ? "Preparing split tunneling…" : "Sign in first"
    if (!configLoaded) return "Loading…"
    if (splitBlocked) return "Turn the Kill Switch off to use this"
    if (splitError !== "") return splitError
    if (!splitOn) return "Keep chosen apps off the VPN"
    var n = Model.collapseSplitPaths(splitApps).length
    if (n === 0) return "No apps chosen yet"
    if (splitMode === "include")
      return n === 1 ? "Only 1 app uses the VPN" : "Only " + n + " apps use the VPN"
    return n === 1 ? "1 app skips the VPN" : n + " apps skip the VPN"
  }

  function applySplitSettings() {
    // Only a running connector reads the file, so this is what makes a
    // change take hold now instead of at the next connect.
    if (linkActive) refreshStatus()
  }

  // Every split tunneling change funnels through here: read the file fresh,
  // let `mutate` change `features.split_tunneling` in place, write the whole
  // thing back. `evenWhenBlocked` is only for turning split tunneling off:
  // turning it on while the kill switch is on would write a setting Proton
  // ignores, but turning it off is always honest.
  function writeSplit(mutate, evenWhenBlocked) {
    if (!splitAvailable) return false
    if (splitBlocked && evenWhenBlocked !== true) return false
    // The CLI rewrites this same file, so never write across one of its runs.
    if (busy || setConfigProcess.running || configPending !== "") return false
    _splitMutate = mutate
    splitFile.readFile(protonSettingsPath)
    return true
  }

  function _applySplitWrite(text, ok, mutate) {
    var data = null
    try { data = ok ? JSON.parse(text) : null } catch (e) { data = null }
    if (!data || typeof data !== "object" || !data["features"] || typeof data["features"]["split_tunneling"] !== "object") {
      splitError = "Could not read Proton's settings"
      return
    }
    var st = data["features"]["split_tunneling"]
    if (!st["config_by_mode"]) {
      st["config_by_mode"] = {
        "exclude": { "mode": "exclude", "app_paths": [], "ip_ranges": [] },
        "include": { "mode": "include", "app_paths": [], "ip_ranges": [] }
      }
    }
    mutate(st)
    splitError = ""
    // Proton writes this file with an indent of 4; match it so a diff after
    // one of our writes shows the one section that changed and nothing else.
    splitFile.writeFile(protonSettingsPath, JSON.stringify(data, null, 4))
    protonSettings = data
    applySplitSettings()
  }

  function toggleSplitTunnel() {
    var on = !splitOn
    writeSplit(function(st) { st["enabled"] = on })
  }

  function setSplitMode(mode) {
    if (mode !== "exclude" && mode !== "include") return
    if (mode === splitMode) return
    writeSplit(function(st) { st["mode"] = mode })
  }

  function loadInstalledApps(force) {
    if (installedAppsLoaded && force !== true) return
    if (appsListProcess.running) return
    appsListProcess.command = ["python3", appsScriptPath]
    appsListProcess.running = true
  }

  // The panel hands back the full selection rather than one add or remove.
  // Paths are only ever accepted from the installed-app scan, so a path
  // that isn't absolute never reaches the file.
  function setSplitApps(paths) {
    var clean = []
    var seen = ({})
    var arr = (paths && typeof paths.length === "number") ? paths : []
    for (var i = 0; i < arr.length; i++) {
      var p = String(arr[i])
      if (p.charAt(0) !== "/" || p.indexOf("\u0000") !== -1) continue
      if (seen[p]) continue
      seen[p] = true
      clean.push(p)
    }
    _pendingSplitApps = clean
    var argv = ["python3", appsScriptPath, "--expand"].concat(clean)
    expandSplitProcess.command = argv
    expandSplitProcess.running = true
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function refresh() {
    if (!installed) { probeInstalled(); return }
    watchLink()
    refreshAccount()
    refreshStatus()
  }

  function probeInstalled() {
    if (!whichProcess.running) {
      whichProcess.command = ["which", "protonvpn"]
      whichProcess.running = true
    }
    if (!pacmanProcess.running) {
      pacmanProcess.command = ["pacman", "-Q", "proton-vpn-gtk-app"]
      pacmanProcess.running = true
    }
  }

  function watchLink() {
    if (watchProcess.running) return
    _watchStartedMs = Date.now()
    watchProcess.command = ["nmcli", "-t", "-f", "NAME,TYPE,DEVICE,STATE", "connection", "show", "--active"]
    watchProcess.running = true
  }

  function refreshStatus() {
    if (!installed) return
    if (cliBusy) { _wantStatus = true; return }
    _probeRunning = true
    statusProcess.command = ["protonvpn", "status"]
    statusProcess.running = true
  }

  function refreshAccount() {
    if (!installed) return
    if (cliBusy) { _wantAccount = true; return }
    _probeRunning = true
    accountProcess.command = ["protonvpn", "info"]
    accountProcess.running = true
  }

  // Start exactly one deferred probe, the moment a slot frees up.
  function drainProbes() {
    if (cliBusy) return
    if (_wantAccount) { _wantAccount = false; refreshAccount(); return }
    if (_wantConfig) { _wantConfig = false; loadConfig(); return }
    if (_wantCountries) { _wantCountries = false; loadCountries(false); return }
    if (_wantStatus) { _wantStatus = false; refreshStatus(); return }
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    // A probe that overlapped an action still reports the previous tunnel.
    if (_desired === 1 && !parsed.connected) return
    if (_desired === 0 && parsed.connected) return
    statusConnected = parsed.connected
    statusConnecting = parsed.connecting
    statusText = parsed.statusText
    serverName = parsed.serverName
    location = parsed.location
    fields = parsed.fields
    reconcile()
  }

  // Drop the optimistic override once the world agrees with it. Does not
  // release on disagreement alone: mid-connect the link poll can still show
  // the old state, and releasing then would flash "Not protected" over a
  // connect that is succeeding. A 15s safety valve prevents a permanent
  // latch if something else undoes the requested state outright.
  function reconcile() {
    if (_desired === -1) return
    if (_changingServer) return
    var real = linkActive || statusConnected
    if (real === (_desired === 1)) {
      _desired = -1
      pendingLabel = ""
      return
    }
    if (!busy && _actionEndedMs > 0 && Date.now() - _actionEndedMs > 15000) {
      _desired = -1
      clearChanging()
      pendingLabel = ""
    }
  }

  function markChanging() {
    _changingServer = true
    _changeFromServer = displayServer || ""
    _expectDown = true
  }

  function clearChanging() {
    _changingServer = false
    _changeFromServer = ""
    _expectDown = false
  }

  // Free-plan CLI used to reject a named/country connect outright; a named
  // single-server connect on free plan instead hops through Proton's
  // session API (change.py), the same way the desktop app does. Always try
  // the native CLI first, even for a named server: whether that's accepted
  // depends on the account's real tier, which the CLI checks server-side —
  // `plusPlan` is only a client-side guess, and an unreliable one as of CLI
  // 1.0.3 (`protonvpn info` no longer prints a Plan line at all, so it's
  // permanently "free" for every account). Falling back to change.py only
  // on an actual plan-restriction failure (_apiFallback, consumed in
  // connectProcess.onExited) stays correct regardless of that guess, and
  // never routes a Plus account through change.py at all — which needs
  // Python's `proton` package on PATH, not just protonvpn's own CLI.
  property var _apiFallback: null
  function connectTo(args, label) {
    if (!installed || !signedIn || busy) return
    args = args || []
    var named = args.length === 1 && connectArg.test(args[0]) && args[0].charAt(0) !== "-"
    p2pRequested = args.indexOf("--p2p") !== -1
    _autoHold = false
    if (linkActive || statusConnected) markChanging()
    else clearChanging()
    _desired = 1
    pendingLabel = label || "Connecting…"
    actionStatus = pendingLabel
    lastError = ""
    _apiFallback = named ? ["python3", changePath, "--to", args[0]] : null
    connectProcess.command = ["protonvpn", "connect"].concat(args)
    connectProcess.running = true
  }

  function connectFastest() { connectTo([], "Connecting to fastest…") }
  function connectP2P() { connectTo(["--p2p"], "Connecting to fastest P2P…") }
  function connectSecureCore() { connectTo(["--securecore"], "Connecting via Secure Core…") }
  function connectTor() { connectTo(["--tor"], "Connecting via Tor…") }

  function connectCountry(code, name) {
    var c = String(code || "").trim().toUpperCase()
    if (!/^[A-Z]{2}$/.test(c)) return
    connectTo(["--country", c], "Connecting to " + (name || c) + "…")
  }

  // `protonvpn connect <NAME>` takes precedence over every filter in the
  // CLI's own selection, so a named server connects exactly as asked.
  function connectServer(name, city) {
    var n = String(name || "").trim()
    if (!connectArg.test(n) || n.charAt(0) === "-") return
    connectTo([n], "Connecting to " + (city || n) + "…")
  }

  // Same native-CLI-first approach as connectTo(): try `--random` directly,
  // and only fall back to change.py's shuffle (which excludes the current
  // server, unlike the native flag) on an actual plan-restriction failure.
  function hopRandom(label) {
    if (!installed || !signedIn || busy) return
    p2pRequested = false
    _autoHold = false
    if (linkActive || statusConnected) markChanging()
    else clearChanging()
    _desired = 1
    pendingLabel = label || "Changing server…"
    actionStatus = pendingLabel
    lastError = ""
    var apiArgv = ["python3", changePath, "--current", displayServer || ""]
    if (!plusPlan) apiArgv.push("--free")
    _apiFallback = apiArgv
    connectProcess.command = ["protonvpn", "connect", "--random"]
    connectProcess.running = true
  }

  function connectRandom() { hopRandom("Connecting to a random server…") }
  function changeServer() { if (connected) hopRandom("Changing server…") }

  function loadCountries(force) {
    if (!installed || !signedIn) return
    if (countriesLoaded && force !== true) return
    if (cliBusy) { _wantCountries = true; return }
    _probeRunning = true
    countriesProcess.command = ["protonvpn", "countries", "list"]
    countriesProcess.running = true
  }

  function loadCities(force) {
    if (!installed || citiesProcess.running) return
    if (citiesLoaded && force !== true) return
    citiesProcess.command = ["python3", scriptPath, "--cities"]
    citiesProcess.running = true
  }

  function loadServers(code, name) {
    var c = String(code || "").trim().toUpperCase()
    if (!installed || !/^[A-Z]{2}$/.test(c) || serversProcess.running) return
    serversCountry = c
    serversCountryName = name || c
    servers = []
    serversLoading = true
    serversProcess.command = ["python3", scriptPath, c, "80"]
    serversProcess.running = true
  }

  function clearServers() {
    servers = []
    serversCountry = ""
    serversCountryName = ""
    serversLoading = false
  }

  // Which city the connected server is in. Runs whenever the server name
  // changes; a lookup arriving mid-run is queued, not dropped.
  function locateServer(name) {
    var n = String(name || "").trim()
    if (n === "") { currentPlace = null; _locatePending = ""; return }
    if (currentPlace && currentPlace.name === n) return
    if (locateProcess.running) { _locatePending = n; return }
    locateProcess.command = ["python3", scriptPath, "--locate", n]
    locateProcess.running = true
  }

  onDisplayServerChanged: locateServer(displayServer)

  function countryName(code) {
    var c = String(code || "").toUpperCase()
    for (var i = 0; i < countries.length; i++) if (countries[i].code === c) return countries[i].name
    return c
  }

  function trafficReset() {
    rxHistory = []; txHistory = []
    rxRate = 0; txRate = 0
    sessionRx = 0; sessionTx = 0
    uptimeSec = 0
    _lastRx = -1; _lastTx = -1; _lastSampleMs = 0
    _linkUpMs = Date.now()
  }

  function trafficSample() {
    if (trafficProcess.running || linkDevice === "") return
    var base = "/sys/class/net/" + linkDevice + "/statistics/"
    trafficProcess.command = ["cat", base + "rx_bytes", base + "tx_bytes"]
    trafficProcess.running = true
  }

  function trafficApply(text) {
    var parts = String(text || "").trim().split(/\s+/)
    var rx = parseFloat(parts[0]), tx = parseFloat(parts[1])
    if (!isFinite(rx) || !isFinite(tx)) return
    var now = Date.now()
    if (_lastRx >= 0 && _lastSampleMs > 0) {
      var dt = Math.max(0.25, (now - _lastSampleMs) / 1000)
      var drx = Math.max(0, rx - _lastRx), dtx = Math.max(0, tx - _lastTx)
      rxRate = drx / dt; txRate = dtx / dt
      sessionRx += drx; sessionTx += dtx
      var h = rxHistory.slice(); h.push(rxRate); if (h.length > trafficSamples) h.shift(); rxHistory = h
      var g = txHistory.slice(); g.push(txRate); if (g.length > trafficSamples) g.shift(); txHistory = g
    }
    _lastRx = rx; _lastTx = tx; _lastSampleMs = now
    uptimeSec = _linkUpMs > 0 ? Math.floor((now - _linkUpMs) / 1000) : 0
  }

  function disconnect() {
    if (!installed || busy) return
    // A manual disconnect while Always On is on should stay down until the
    // user connects again, not immediately reconnect itself. The kill
    // switch cycle also disconnects, but that one wants Always On to bring
    // the tunnel straight back, so it's excluded.
    if (!_ksCycle) _autoHold = true
    clearChanging()
    _desired = 0
    _expectDown = true
    pendingLabel = "Disconnecting…"
    actionStatus = ""
    lastError = ""
    actionProcess.command = ["protonvpn", "disconnect"]
    actionProcess.running = true
  }

  function signOut() {
    if (!installed || busy) return
    _desired = 0
    _expectDown = true
    trafficReset()
    pendingLabel = "Signing out…"
    actionProcess.command = ["protonvpn", "signout"]
    actionProcess.running = true
  }

  // Sign-in is interactive (password, then a TOTP token), so it has to
  // happen in a real terminal — the CLI only accepts them from a tty. Tries
  // konsole first, falls back to xterm, sized to a normal terminal window
  // rather than each app's oversized default. The window closes on its own
  // once shellCmd exits successfully; it only drops to an interactive shell
  // (and stays open) so the user can read the error if it failed.
  function launchTerminal(shellCmd) {
    var wrapped = shellCmd + "; st=$?; if [ \"$st\" -ne 0 ]; then exec sh; fi"
    var quoted = Model.shellQuote(wrapped)
    var script = "if command -v konsole >/dev/null 2>&1; then exec konsole -p TerminalColumns=90 -p TerminalRows=25 -e sh -c "
                 + quoted
                 + "; elif command -v xterm >/dev/null 2>&1; then exec xterm -geometry 90x25 -e sh -c "
                 + quoted + "; fi"
    cmd.execDetached(["sh", "-c", script])
  }

  // The username can be typed in the panel; with none given the terminal
  // asks for it. Password and any 2FA token are only ever typed into that
  // terminal, never seen by the widget.
  //
  // protonvpn signin's own exit code can't be trusted as-is: the widget's
  // background pollers (signInWatch/statusTimer) keep calling the CLI every
  // few seconds while this interactive process is running, and that
  // concurrent access has been observed to make an otherwise-successful
  // signin (its "Successfully signed in..." message did print) still exit
  // non-zero, which used to strand the user on an unwanted shell prompt.
  // So on a non-zero exit, double-check the CLI's own account state for the
  // username we just tried before trusting the exit code — `grep -F`
  // ignores glob/regex metacharacters, so this is safe even for the
  // free-typed (unvalidated) username from the empty-prompt branch below.
  function signIn(username) {
    var u = String(username || "").trim()
    var shellCmd
    // $u must be the shell variable actually signed in with, in both
    // branches, since the recheck below tests against it by name.
    var recheck = "; _rc=$?; if [ \"$_rc\" -ne 0 ] && protonvpn info 2>/dev/null | grep -qF \"'$u'\"; then _rc=0; fi; [ \"$_rc\" -eq 0 ]"
    if (u === "") {
      shellCmd = "read -rp 'Proton username: ' u && protonvpn signin \"$u\"" + recheck
    } else if (Model.validUsername(u)) {
      shellCmd = "u=" + Model.shellQuote(u) + " && protonvpn signin \"$u\"" + recheck
    } else {
      lastError = "Usernames can only contain letters, numbers and . _ + @ -"
      return false
    }
    lastError = ""
    launchTerminal(shellCmd)
    signInWatch.restart()
    return true
  }

  // Proton writes JSON+PEM with literal newlines into the passwordless
  // gnome-keyring INI; gnome-keyring then rejects the file on the next boot.
  // sanitize_keyring.py folds those newlines so the session survives a
  // restart. Rate-limited: called on every confirmed-signed-in poll, not
  // just once.
  function persistSession(force) {
    var now = Date.now()
    if (!force && now - _lastPersistMs < 60000) return
    _lastPersistMs = now
    cmd.execDetached(["python3", sanitizePath, "--persist"])
  }

  function loadConfig() {
    if (!installed || !signedIn) { configPending = ""; configPendingValue = ""; return }
    if (cliBusy) { _wantConfig = true; return }
    _probeRunning = true
    configProcess.command = ["protonvpn", "config", "list"]
    configProcess.running = true
  }

  // Both key and value must be in configValues; anything else is dropped.
  // Refuses while a change is still settling, so a second click can't send
  // a contradicting `config set` at a value the panel hasn't been told
  // about yet.
  function setConfig(key, value) {
    if (configPending !== "" || setConfigProcess.running) return
    applyConfig(key, value)
  }

  // The set itself, without the in-flight guard, so the NetShield step-down
  // below can hand off from one failed attempt straight into the next.
  function applyConfig(key, value) {
    var allowed = configValues[key]
    if (!allowed || allowed.indexOf(value) === -1) return
    if (!installed || !signedIn) return
    _configKey = key
    _configValue = value
    configPending = key
    configPendingValue = value
    lastError = ""
    setConfigProcess.command = ["protonvpn", "config", "set", key, value]
    setConfigProcess.running = true
  }

  function toggleKillSwitch() {
    var value = killSwitchOn ? "off" : "standard"
    // Nothing to work around while the tunnel is down: one CLI call.
    if (!connected && !linkActive) { setConfig("kill-switch", value); return }
    if (_ksCycle || configPending !== "" || busy) return
    _ksCycle = true
    _ksValue = value
    // The row says "Turning off…" from the first click to the last step:
    // from the outside this is one change that takes longer, not three
    // things happening to you.
    configPending = "kill-switch"
    configPendingValue = value
    disconnect()
  }

  // Called when the tunnel is down and the setting has been written, whether
  // or not it succeeded: leaving someone disconnected because their kill
  // switch change failed would be the worse half of a bad trade.
  function ksCycleFinish() {
    _ksCycle = false
    var carried = lastError
    connectTo([], "Reconnecting to fastest…")
    if (carried !== "") lastError = carried
  }

  // Full protection first; the CLI refuses ads/trackers on a free plan and
  // the retry below steps down to malware-only.
  function toggleNetShield() { setConfig("netshield", netShieldOn ? "off" : "malware-ads-trackers") }
  function togglePortForwarding() { setConfig("port-forwarding", portForwardingOn ? "off" : "on") }

  function writeNotificationIcon() {
    if (notificationIconPath === "") return
    // Qt prints an opaque colour as #rrggbb and a translucent one as
    // #aarrggbb; SVG wants the former, so drop the alpha if present.
    var hex = String(Kirigami.Theme.highlightColor)
    if (hex.length === 9) hex = "#" + hex.slice(3)
    iconFile.writeFile(notificationIconPath,
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">'
      + '<path fill="' + hex + '" d="' + protonMarkPath + '"/></svg>\n')
  }

  function notify(summary, body, urgency) {
    if (!notificationsOn) return
    // The panel already shows the state change; a toast on top is noise.
    if (panelOpen) return
    var level = urgency === "critical" ? "2" : (urgency === "low" ? "0" : "1")
    cmd.execDetached(["busctl", "--user", "--", "call",
                      "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                      "org.freedesktop.Notifications", "Notify", "susssasa{sv}i",
                      "Proton VPN", "0", notificationIconPath, summary, Model.escapeMarkup(body),
                      "0", "0", "-1"])
  }

  Connections {
    target: Kirigami.Theme
    function onHighlightColorChanged() { root.writeNotificationIcon() }
  }

  Component.onCompleted: {
    envProcess.command = ["sh", "-c", "echo \"$HOME|$XDG_STATE_HOME|$XDG_CONFIG_HOME\""]
    envProcess.running = true
  }

  Cmd { id: cmd }
  FileIo { id: iconFile }
  FileIo { id: splitFile }

  Connections {
    target: splitFile
    function onLoaded(content, ok) {
      if (root._splitMutate) {
        var mutate = root._splitMutate
        root._splitMutate = null
        root._applySplitWrite(content, ok, mutate)
      } else {
        root.readProtonSettings(ok ? content : "")
      }
    }
    function onWritten(ok) {
      if (!ok) root.splitError = "Could not save Proton's settings"
    }
  }

  CliProcess {
    id: envProcess
    onExited: function(code) {
      var parts = String(stdoutText || "").split("|")
      var home = (parts[0] || "").trim()
      var xdgState = (parts[1] || "").trim()
      var xdgConfig = (parts[2] || "").trim()
      root.stateDir = (xdgState !== "" ? xdgState : (home + "/.local/state")) + "/iamfitsum-proton-vpn"
      root.configHome = xdgConfig !== "" ? xdgConfig : (home + "/.config")
      iconFile.ensureDir(root.stateDir)
      iconWriteDelay.restart()
      root.refresh()
      root.loadProtonSettings()
    }
  }

  Timer {
    id: iconWriteDelay
    interval: 500
    repeat: false
    onTriggered: root.writeNotificationIcon()
  }

  onPanelOpenChanged: if (panelOpen) {
    refresh(); loadCountries(false); loadCities(false); loadConfig(); loadProtonSettings()
  }

  Timer {
    id: signInWatch
    interval: 3000
    repeat: true
    triggeredOnStart: false
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks += 1
      root.refreshAccount()
      if (root.signedIn || ticks > 40) stop()
    }
  }

  Timer {
    id: watchTimer
    interval: root.watchIntervalSec * 1000
    repeat: true
    running: root.installed
    triggeredOnStart: true
    onTriggered: root.watchLink()
  }

  Timer {
    id: statusTimer
    interval: (root.panelOpen ? 5 : root.refreshIntervalSec) * 1000
    repeat: true
    running: root.installed && root.signedIn && !root.busy
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: delayedRefresh
    interval: 1200
    repeat: false
    onTriggered: { root.watchLink(); root.refreshStatus() }
  }

  Timer {
    id: probeRetry
    interval: 600
    repeat: true
    running: root._probesPending && root.installed
    onTriggered: root.drainProbes()
  }

  Timer {
    id: accountRetry
    interval: 5000
    repeat: false
    onTriggered: root.refreshAccount()
  }

  Timer {
    id: actionStatusTimer
    interval: 6000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: trafficTimer
    interval: 1000
    repeat: true
    running: root.panelOpen && root.linkActive && root.linkDevice !== ""
    triggeredOnStart: true
    onTriggered: root.trafficSample()
  }

  CliProcess {
    id: whichProcess
    onExited: function(exitCode) {
      var was = root.installed
      root.installed = exitCode === 0
      if (root.installed) {
        if (!was) { root.lastError = ""; root.statusText = "Checking…" }
        root.refresh()
        root.loadCities(false)
        root.loadConfig()
      } else {
        root.statusText = "Proton VPN CLI not installed"
      }
    }
  }

  CliProcess {
    id: pacmanProcess
    onExited: function(exitCode) { root.gtkAppInstalled = exitCode === 0 }
  }

  CliProcess {
    id: watchProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      if (root._actionEndedMs > 0 && root._watchStartedMs < root._actionEndedMs) {
        root.watchLink()
        return
      }
      var link = Model.parseActiveVpn(String(stdoutText || ""))
      var was = root.linkActive
      root.linkActive = link.active
      root.linkServer = link.server
      root.linkDevice = link.device
      if (link.active !== was) root.trafficReset()
      // A tunnel we didn't ask to close is the one thing a person must hear
      // about. A connect in flight is not that (switching servers tears the
      // old one down first, and every `protonvpn connect` briefly
      // double-activates as NetworkManager preempts its own activation).
      if (was && !link.active) {
        if (!root._expectDown && !root._changingServer
            && !actionProcess.running && !connectProcess.running)
          root.notify("VPN Disconnected", "You're no longer protected.", "critical")
        if (!root._changingServer) root._expectDown = false
      }
      if (link.active && root._changingServer && !connectProcess.running) {
        var swapped = link.server !== "" && root._changeFromServer !== ""
                      && link.server !== root._changeFromServer
        if (swapped || !was) root.clearChanging()
      }
      root.reconcile()
      root.autoReconcile()
      // The tunnel came up or went away behind our back, pull detail rows
      // back in sync.
      if (was !== link.active) root.refreshStatus()
      if (link.active && !root.signedIn) root.refreshAccount()
    }
  }

  CliProcess {
    id: statusProcess
    onExited: function(exitCode) {
      root._probeRunning = false
      Qt.callLater(root.drainProbes)
      if (exitCode === 0) {
        root.applyStatus(String(stdoutText || ""))
        root.lastError = ""
      } else {
        root.lastError = Model.elide(String(stderrText || "") || "protonvpn status failed")
      }
    }
  }

  CliProcess {
    id: accountProcess
    onExited: function(exitCode) {
      root._probeRunning = false
      Qt.callLater(root.drainProbes)
      // A one-off failure must not latch "signed out" forever.
      if (exitCode !== 0) { accountRetry.restart(); return }
      var info = Model.parseAccount(String(stdoutText || ""))
      var was = root.signedIn
      root.accountProbed = true
      root.signedIn = info.signedIn
      root.account = info.account
      root.plan = info.plan
      if (info.signedIn) root.persistSession(!was)
      if (info.signedIn && !was) { root.loadCountries(true); root.loadConfig() }
      if (!info.signedIn) {
        root.countries = []; root.countriesLoaded = false
        root.config = ({}); root.configLoaded = false
        // Sign-out deletes the CLI's settings.json, so the next sign-in
        // starts from "no file yet" again.
        root._settingsBootstrapTried = false
        root.protonSettings = null
        root.splitLoaded = false
      }
    }
  }

  CliProcess {
    id: connectProcess
    onExited: function(exitCode) {
      root._actionEndedMs = Date.now()
      var out = String(stdoutText || "")
      var err = String(stderrText || "")
      var wasAuto = root._autoAttempt
      root._autoAttempt = false
      if (exitCode !== 0) {
        var text = err || out || "Connect failed"
        // The native CLI rejected this — the only reason it would for a
        // named/random connect is a real tier restriction. Retry once via
        // change.py before reporting anything; this is what stays correct
        // for a free account even though `plusPlan` can't be trusted (see
        // connectTo()), without ever bothering a Plus account with it.
        if (root._apiFallback && Model.isPlanError(text)) {
          var argv = root._apiFallback
          root._apiFallback = null
          connectProcess.command = argv
          connectProcess.running = true
          return
        }
        root._apiFallback = null
        // Don't retry an Always On attempt on the very next poll: a connect
        // against a dead network fails slowly and there is no point
        // hammering it.
        if (wasAuto) root._autoNextMs = Date.now() + root.autoRetryMs
        root._desired = -1
        root.clearChanging()
        root.pendingLabel = ""
        root.lastError = Model.isPlanError(text) ? "Requires a Proton VPN Plus plan" : Model.elide(text)
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root._apiFallback = null
        root.lastError = ""
        var line = Model.elide(Model.connectedLine(out) || out.split("\n")[0] || "", 90)
        root.actionStatus = line
        actionStatusTimer.restart()
        var where = line.replace(/^connected to\s+/i, "").replace(/\.\s*$/, "")
        root.notify("VPN Connected", where, "normal")
      }
      root.watchLink()
      delayedRefresh.restart()
    }
  }

  CliProcess {
    id: actionProcess
    onExited: function(exitCode) {
      root._actionEndedMs = Date.now()
      var out = String(stdoutText || "")
      var err = String(stderrText || "")
      if (exitCode !== 0) {
        root.pendingLabel = ""
        root._desired = -1
        root._expectDown = false
        root.lastError = Model.elide(err || out || "Command failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      // Second step of a kill switch change: the tunnel is down, which is
      // the only state the CLI accepts the setting in. A failed disconnect
      // means the tunnel is still up, so there's nothing to try.
      if (root._ksCycle) {
        if (exitCode !== 0) {
          root._ksCycle = false
          root.configPending = ""
          root.configPendingValue = ""
        } else {
          root.applyConfig("kill-switch", root._ksValue)
        }
      }
      root.refreshAccount()
      delayedRefresh.restart()
    }
  }

  CliProcess {
    id: setConfigProcess
    onExited: function(exitCode) {
      var err = String(stderrText || "") || String(stdoutText || "")
      var key = root._configKey
      var value = root._configValue
      root._configKey = ""
      root._configValue = ""
      if (exitCode !== 0) {
        // The CLI refuses ads/trackers on a free plan; step down to
        // malware-only rather than surface a dead end.
        if (key === "netshield" && value === "malware-ads-trackers" && Model.isPlanError(err)) {
          root.applyConfig("netshield", "malware-only")
          return
        }
        root.lastError = Model.isPlanError(err) ? "Requires a Proton VPN Plus plan" : Model.elide(err || "Setting failed")
      }
      // Whatever the CLI made of it, the tunnel goes back up. Before
      // loadConfig(), so the re-read queues behind the connect instead of
      // racing it.
      if (root._ksCycle) root.ksCycleFinish()
      root.loadConfig()
      // Any `config set` — ours or a real user toggle — is also the only
      // thing that makes the CLI (re)create settings.json, so re-read it
      // here rather than only on panel-open.
      root.loadProtonSettings()
    }
  }

  CliProcess {
    id: countriesProcess
    onExited: function(exitCode) {
      root._probeRunning = false
      Qt.callLater(root.drainProbes)
      if (exitCode !== 0) return
      var list = Model.parseCountries(String(stdoutText || ""))
      root.countries = list
      root.countriesLoaded = list.length > 0
    }
  }

  CliProcess {
    id: citiesProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        var list = JSON.parse(String(stdoutText || "[]"))
        root.cities = Array.isArray(list) ? list : []
        root.citiesLoaded = root.cities.length > 0
      } catch (e) {
        root.cities = []
      }
    }
  }

  CliProcess {
    id: serversProcess
    onExited: function(exitCode) {
      root.serversLoading = false
      if (exitCode !== 0) { root.servers = []; return }
      try {
        root.servers = JSON.parse(String(stdoutText || "[]"))
      } catch (e) {
        root.servers = []
      }
    }
  }

  CliProcess {
    id: locateProcess
    onExited: function(exitCode) {
      try {
        var place = exitCode === 0 ? JSON.parse(String(stdoutText || "{}")) : {}
        root.currentPlace = place && place.lat !== undefined && place.lat !== null ? place : null
      } catch (e) {
        root.currentPlace = null
      }
      if (root._locatePending !== "") {
        var next = root._locatePending
        root._locatePending = ""
        root.locateServer(next)
      }
    }
  }

  // sysfs files report a size of 0, so a plain read looks empty until read
  // to EOF; `cat` does that and costs about a millisecond once a second.
  CliProcess {
    id: trafficProcess
    onExited: function(exitCode) { if (exitCode === 0) root.trafficApply(stdoutText) }
  }

  CliProcess {
    id: configProcess
    onExited: function(exitCode) {
      root._probeRunning = false
      root.configPending = ""
      root.configPendingValue = ""
      Qt.callLater(root.drainProbes)
      if (exitCode !== 0) return
      root.config = Model.parseConfig(String(stdoutText || ""))
      root.configLoaded = true
      root.maybeBootstrapProtonSettings()
    }
  }

  CliProcess {
    id: portProcess
    onExited: function(exitCode) {
      var port = ""
      try {
        var out = exitCode === 0 ? JSON.parse(String(stdoutText || "{}")) : {}
        if (out && out.port) port = String(out.port)
      } catch (e) { port = "" }
      // Digits only, or nothing: this is what goes to the clipboard.
      if (!/^[1-9][0-9]{0,4}$/.test(port)) port = ""
      // A missed renewal (one timeout) shouldn't blank the row for 45s.
      if (port !== "" || !root.portWanted) root.forwardedPort = port
    }
  }

  Timer {
    interval: 45000
    repeat: true
    running: root.portWanted
    onTriggered: root.refreshPort()
  }

  CliProcess {
    id: appsListProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        var list = JSON.parse(String(stdoutText || "[]"))
        root.installedApps = Array.isArray(list) ? list : []
        root.installedAppsLoaded = true
      } catch (e) {
        root.installedApps = []
      }
    }
  }

  CliProcess {
    id: expandSplitProcess
    onExited: function(exitCode) {
      var expanded = root._pendingSplitApps
      try {
        if (exitCode === 0) {
          var parsed = JSON.parse(String(stdoutText || "[]"))
          if (Array.isArray(parsed)) expanded = parsed
        }
      } catch (e) { /* keep the unexpanded selection rather than lose it */ }
      var mode = root.splitMode
      root.writeSplit(function(st) {
        if (!st["config_by_mode"][mode]) st["config_by_mode"][mode] = { mode: mode, app_paths: [], ip_ranges: [] }
        st["config_by_mode"][mode]["app_paths"] = expanded
      })
    }
  }
}
