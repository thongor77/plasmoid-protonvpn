import QtQuick
import org.kde.plasma.plasmoid
import "../code" as Code

PlasmoidItem {
  id: root

  property alias service: vpn

  toolTipMainText: "Proton VPN"
  toolTipSubText: vpn.displayStatus

  Code.Service {
    id: vpn
    panelOpen: root.expanded
  }

  compactRepresentation: CompactRepresentation {
    service: vpn
  }

  fullRepresentation: FullRepresentation {
    service: vpn
  }

  // A one-off scan, not gated on sign-in — safe to kick off unconditionally
  // so the config dialog's app list (see ui/config/ConfigSplitTunneling.qml)
  // has something to mirror by the time it's opened. loadInstalledApps()
  // is idempotent (installedAppsLoaded guards it) so this is a no-op after
  // the first successful scan of this plasmashell run.
  Component.onCompleted: vpn.loadInstalledApps(false)

  // The config dialog (contents/ui/config/*.qml) runs in its own QML
  // engine and cannot see `vpn` directly — a plain QML
  // property on this item isn't visible there (confirmed live: it read as
  // undefined). `Plasmoid.configuration` is the two-way channel Plasma
  // actually provides between the two: mirror the CLI-confirmed state
  // into it one-way here (Binding, not Connections, so a stale value left
  // over from a previous session is overwritten the moment real state is
  // known, not only on the next change), and react the other way — but
  // only when a value truly differs from live state, so re-mirroring our
  // own writes below never bounces back into another toggle call.
  Binding { target: Plasmoid.configuration; property: "killSwitch"; value: vpn.killSwitchOn; when: vpn.configLoaded }
  Binding { target: Plasmoid.configuration; property: "netShield"; value: vpn.netShieldOn; when: vpn.configLoaded }
  Binding { target: Plasmoid.configuration; property: "portForwarding"; value: vpn.portForwardingOn; when: vpn.configLoaded }
  Binding { target: Plasmoid.configuration; property: "alwaysOn"; value: vpn.autoConnect }

  // Same idea for split tunneling, plus two read-only mirrors
  // (splitAvailable/splitBlocked) and the installed-app candidate list
  // (as JSON — configuration entries are plain KConfigXT types, no room
  // for an array-of-objects) so the config page can render its picker and
  // gating without any of that live from Service either.
  Binding { target: Plasmoid.configuration; property: "splitEnabled"; value: vpn.splitOn; when: vpn.splitAvailable }
  Binding { target: Plasmoid.configuration; property: "splitMode"; value: vpn.splitMode; when: vpn.splitAvailable }
  Binding { target: Plasmoid.configuration; property: "splitApps"; value: vpn.splitApps; when: vpn.splitAvailable }
  Binding { target: Plasmoid.configuration; property: "splitAvailable"; value: vpn.splitAvailable }
  Binding { target: Plasmoid.configuration; property: "splitBlocked"; value: vpn.splitBlocked }
  Binding { target: Plasmoid.configuration; property: "installedAppsLoaded"; value: vpn.installedAppsLoaded }
  Binding {
    target: Plasmoid.configuration
    property: "installedAppsJson"
    value: JSON.stringify(vpn.installedApps)
    when: vpn.installedAppsLoaded
  }

  Connections {
    target: Plasmoid.configuration
    function onKillSwitchChanged() {
      if (Plasmoid.configuration.killSwitch !== vpn.killSwitchOn) vpn.toggleKillSwitch()
    }
    function onNetShieldChanged() {
      if (Plasmoid.configuration.netShield !== vpn.netShieldOn) vpn.toggleNetShield()
    }
    function onPortForwardingChanged() {
      if (Plasmoid.configuration.portForwarding !== vpn.portForwardingOn) vpn.togglePortForwarding()
    }
    function onAlwaysOnChanged() {
      if (Plasmoid.configuration.alwaysOn !== vpn.autoConnect) vpn.toggleAutoConnect()
    }
    function onSplitEnabledChanged() {
      if (Plasmoid.configuration.splitEnabled !== vpn.splitOn) vpn.toggleSplitTunnel()
    }
    function onSplitModeChanged() {
      if (Plasmoid.configuration.splitMode !== vpn.splitMode) vpn.setSplitMode(Plasmoid.configuration.splitMode)
    }
    function onSplitAppsChanged() {
      var a = Plasmoid.configuration.splitApps
      var b = vpn.splitApps
      var same = a.length === b.length && a.every(function(p, i) { return p === b[i] })
      if (!same) vpn.setSplitApps(a)
    }
  }
}
