import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

// Kill Switch, NetShield, Port Forwarding and Always On used to live
// inline in the popup; moved here (reached via right-click ▸ Configure
// Proton VPN…) to keep the popup to status/connect/servers, matching the
// upstream Omarchy widget's layout.
//
// This page cannot reach the popup's live Service instance directly — a
// config dialog runs in its own QML engine, and a plain QML property on
// the applet's root item isn't visible there (confirmed live: it read as
// undefined). `cfg_*` here is the standard KCM convention: the loader
// initializes each from `plasmoid.configuration.<name>` and writes it back
// there on Apply/OK; ui/main.qml is what actually turns that into a CLI
// call and mirrors the real result back. So a toggle here takes effect
// only once you hit Apply/OK, not instantly like the old popup switches —
// standard for a config dialog, and fine for settings this infrequently
// touched.
KCM.SimpleKCM {
  id: root

  property bool cfg_killSwitch
  property bool cfg_netShield
  property bool cfg_portForwarding
  property bool cfg_alwaysOn

  Kirigami.FormLayout {
    Layout.fillWidth: true

    Controls.Switch {
      Kirigami.FormData.label: "Kill Switch:"
      checked: root.cfg_killSwitch
      onToggled: root.cfg_killSwitch = checked
    }

    Controls.Switch {
      Kirigami.FormData.label: "NetShield:"
      checked: root.cfg_netShield
      onToggled: root.cfg_netShield = checked
    }

    Controls.Switch {
      Kirigami.FormData.label: "Port Forwarding:"
      checked: root.cfg_portForwarding
      onToggled: root.cfg_portForwarding = checked
    }

    Controls.Switch {
      Kirigami.FormData.label: "Always On:"
      checked: root.cfg_alwaysOn
      onToggled: root.cfg_alwaysOn = checked
    }
  }
}
