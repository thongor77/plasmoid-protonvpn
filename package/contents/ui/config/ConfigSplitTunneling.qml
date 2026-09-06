import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

// Moved out of the popup entirely (it used to take over the whole popup
// via an app-picker sub-view reusing the country/server ScrollView) —
// KCM.SimpleKCM is already a Kirigami.ScrollablePage, so the app list
// below scrolls without a manual ScrollView.
//
// Same constraint as ConfigProtections.qml: this page can't reach the
// popup's live Service instance (a config dialog runs in its own QML
// engine), so everything here rides `cfg_*` — the standard KCM
// convention that initializes each from `plasmoid.configuration.<name>`
// and writes it back on Apply/OK. ui/main.qml is what actually turns
// splitEnabled/splitMode/splitApps into CLI-backed changes and mirrors
// the real result back; splitAvailable/splitBlocked/installedApps* are
// mirrored the other way (read-only here, from Service) so this page can
// show the right message/gating without any of that logic duplicated.
KCM.SimpleKCM {
  id: root

  property bool cfg_splitEnabled
  property string cfg_splitMode
  property var cfg_splitApps: []
  property bool cfg_splitAvailable
  property bool cfg_splitBlocked
  property string cfg_installedAppsJson
  property bool cfg_installedAppsLoaded

  readonly property var installedApps: {
    try {
      var parsed = JSON.parse(root.cfg_installedAppsJson || "[]")
      return Array.isArray(parsed) ? parsed : []
    } catch (e) {
      return []
    }
  }

  readonly property string description: {
    if (!root.cfg_splitAvailable) return "Sign in first"
    if (root.cfg_splitBlocked) return "Turn the Kill Switch off to use this"
    if (!root.cfg_splitEnabled) return "Keep chosen apps off the VPN"
    var n = root.cfg_splitApps ? root.cfg_splitApps.length : 0
    if (n === 0) return "No apps chosen yet"
    if (root.cfg_splitMode === "include")
      return n === 1 ? "Only 1 app uses the VPN" : "Only " + n + " apps use the VPN"
    return n === 1 ? "1 app skips the VPN" : n + " apps skip the VPN"
  }

  ColumnLayout {
    Layout.fillWidth: true
    spacing: Kirigami.Units.smallSpacing

    Kirigami.FormLayout {
      Layout.fillWidth: true

      RowLayout {
        Kirigami.FormData.label: "Split Tunneling:"
        Controls.Label {
          text: root.description
          opacity: 0.6
          elide: Text.ElideRight
        }
        Controls.Switch {
          enabled: root.cfg_splitAvailable && !root.cfg_splitBlocked
          checked: root.cfg_splitEnabled
          onToggled: root.cfg_splitEnabled = checked
        }
      }

      RowLayout {
        Kirigami.FormData.label: "Mode:"
        visible: root.cfg_splitAvailable && !root.cfg_splitBlocked
        Controls.Button {
          text: "Exclude"
          checkable: true
          checked: root.cfg_splitMode === "exclude"
          onClicked: root.cfg_splitMode = "exclude"
        }
        Controls.Button {
          text: "Include"
          checkable: true
          checked: root.cfg_splitMode === "include"
          onClicked: root.cfg_splitMode = "include"
        }
      }
    }

    Kirigami.Separator {
      Layout.fillWidth: true
      visible: root.cfg_splitAvailable && !root.cfg_splitBlocked
    }

    Repeater {
      model: (root.cfg_splitAvailable && !root.cfg_splitBlocked) ? root.installedApps : []
      delegate: Controls.CheckDelegate {
        id: appDelegate
        required property var modelData
        Layout.fillWidth: true
        text: modelData.label
        checked: root.cfg_splitApps.indexOf(modelData.value) !== -1
        onToggled: {
          var current = root.cfg_splitApps.slice()
          var idx = current.indexOf(modelData.value)
          if (checked && idx === -1) current.push(modelData.value)
          else if (!checked && idx !== -1) current.splice(idx, 1)
          root.cfg_splitApps = current
        }
        // `checked` above is the initial binding only: QtQuick Controls
        // drops it the moment the user clicks. This is what keeps a row
        // in sync when another row's toggle rewrites the whole array
        // (and so changes what `indexOf` returns for every other row too).
        Connections {
          target: root
          function onCfg_splitAppsChanged() {
            appDelegate.checked = root.cfg_splitApps.indexOf(appDelegate.modelData.value) !== -1
          }
        }
      }
    }

    Controls.Label {
      Layout.fillWidth: true
      visible: root.cfg_splitAvailable && !root.cfg_splitBlocked && !root.cfg_installedAppsLoaded
      text: "Scanning installed apps…"
      opacity: 0.6
    }

    Controls.Label {
      Layout.fillWidth: true
      visible: root.cfg_splitAvailable && !root.cfg_splitBlocked
               && root.cfg_installedAppsLoaded && root.installedApps.length === 0
      text: "No candidate apps found."
      opacity: 0.6
    }
  }
}
