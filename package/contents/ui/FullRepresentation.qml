import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import "../code/Model.js" as Model

// The panel popup. PHASE 1-4: status, an on/off switch (fastest connect /
// disconnect) in the header, country/server picking, P2P/Secure Core/Tor,
// account, sign-in/sign-out, errors, the world map, and the traffic
// graph. Kill Switch/NetShield/port forwarding/Always On/split tunneling
// (mode + app picker) all live in the config dialog (right-click ▸
// Configure Proton VPN…, see ui/config/) — nothing about them shown here,
// to match the upstream Omarchy widget's minimal popup. The Plasmoid
// configuration schema (refresh interval, notifications on/off) is not
// wired up yet — see docs/Roadmap.md.
Item {
  id: root

  property var service
  readonly property bool signedIn: !!(service && service.signedIn)
  readonly property bool plusPlan: !!(service && service.plusPlan)

  property string countryFilter: ""
  readonly property var filteredCountries: service
    ? Model.filterCountries(service.countries, countryFilter) : []

  implicitWidth: Kirigami.Units.gridUnit * 22
  // Reduced from 39 when Kill Switch/NetShield/port forwarding/Always
  // On/split tunneling all moved to the config dialog and the Connect/
  // Change server buttons were replaced by the header switch — see
  // docs/Decisions-Techniques.md. Tuned against the CONNECTED state,
  // which is the tallest one (server/location/load/protocol block +
  // traffic graph + session line, on top of everything the disconnected
  // state already has) — measured live at 404x692 this leaves ~4
  // country/server rows visible below the search field before scrolling.
  // Low-risk to retune further: the only element that absorbs any slack
  // is that scrolling list, which just shows more or fewer rows before it
  // needs scrolling, never clips — the fixed rows above it (bigger once
  // connected) are what actually need the headroom.
  //
  // IMPORTANT when retuning:
  // - An already-placed widget instance does not pick up an
  //   implicitHeight change from a plain plasmashell restart — confirmed
  //   live on 2026-09-06. Remove the widget from the panel and add it
  //   back fresh to see the new size.
  // - console.log from QML does not reach `journalctl --user -u
  //   plasma-plasmashell.service` on this setup (only the engine's own
  //   warnings/errors do) — confirmed live the same day. To measure real
  //   on-screen size instead, temporarily add a Controls.Label bound to
  //   root.width/root.height/scroller.height and read it off a
  //   screenshot.
  implicitHeight: Kirigami.Units.gridUnit * 30
  // Locked to implicit size rather than left resizable: Plasma otherwise
  // lets the user drag the popup to whatever size they like and then
  // remembers that per-instance, so an existing widget doesn't pick up a
  // later implicitHeight bump (e.g. after adding the Server/Location/
  // Load/Protocol block) without a manual resize. Fixing min == max here
  // means the popup is always exactly this size, on every instance.
  Layout.minimumWidth: implicitWidth
  Layout.maximumWidth: implicitWidth
  Layout.minimumHeight: implicitHeight
  Layout.maximumHeight: implicitHeight

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Kirigami.Units.largeSpacing
    spacing: Kirigami.Units.smallSpacing

    RowLayout {
      Layout.fillWidth: true
      spacing: Kirigami.Units.smallSpacing

      ProtonIcon {
        iconSize: Kirigami.Units.iconSizes.medium
        color: root.service && root.service.connected ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
      }

      Kirigami.Heading {
        level: 2
        text: "Proton VPN"
        Layout.fillWidth: true
      }

      Controls.Switch {
        id: connectSwitch
        enabled: !!(root.service && root.service.installed && root.service.signedIn && !root.service.busy)
        checked: !!(root.service && root.service.connected)
        onToggled: {
          if (!root.service) return
          if (checked) root.service.connectFastest()
          else root.service.disconnect()
        }
        Connections {
          target: root.service
          function onConnectedChanged() { connectSwitch.checked = root.service.connected }
        }
      }
    }

    Kirigami.Separator { Layout.fillWidth: true }

    RowLayout {
      Layout.fillWidth: true
      spacing: Kirigami.Units.smallSpacing

      Controls.Label {
        text: (root.service ? root.service.displayStatus : "…")
              + (root.service && root.service.p2pRequested && root.service.connected ? "  ·  P2P" : "")
        font.bold: true
        font.pixelSize: Kirigami.Units.gridUnit
      }
      Controls.Label {
        Layout.fillWidth: true
        visible: root.signedIn
        text: root.service
          ? ("Signed in as " + root.service.account + (root.service.plan !== "" ? " · " + root.service.plan : ""))
          : ""
        opacity: 0.7
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Kirigami.Units.smallSpacing

      Controls.Label {
        // No `visible: text !== ""` here: an invisible item drops out of
        // RowLayout's own layout (not just hidden), which left Sign out as
        // the row's only child and pushed to the left, alone, whenever
        // displayServer was empty (disconnected) — this label just renders
        // nothing then, still reserving the space that keeps Sign out
        // pinned to the right.
        Layout.fillWidth: true
        text: root.service ? root.service.displayServer : ""
        opacity: 0.7
      }
      Controls.ToolButton {
        visible: root.signedIn
        text: "Sign out"
        enabled: !!(root.service && !root.service.busy)
        onClicked: if (root.service) root.service.signOut()
      }
    }

    WorldMap {
      Layout.fillWidth: true
      visible: !!(root.service && root.service.citiesLoaded)
      cities: root.service ? root.service.cities : []
      current: root.service ? root.service.currentPlace : null
      connected: !!(root.service && root.service.connected)
      onCityClicked: function(city) {
        if (root.service) root.service.connectServer(city.name, city.city)
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      visible: !!(root.service && root.service.connected)
      spacing: 0

      RowLayout {
        Layout.fillWidth: true
        visible: root.service && root.service.serverName !== ""
        Controls.Label { text: "Server"; Layout.fillWidth: true; opacity: 0.7 }
        Controls.Label { text: root.service ? root.service.serverName : ""; elide: Text.ElideRight }
      }
      RowLayout {
        Layout.fillWidth: true
        visible: root.service && root.service.location !== ""
        Controls.Label { text: "Location"; Layout.fillWidth: true; opacity: 0.7 }
        Controls.Label { text: root.service ? root.service.location : ""; elide: Text.ElideRight }
      }
      Repeater {
        model: root.service ? root.service.fields : []
        delegate: RowLayout {
          Layout.fillWidth: true
          required property var modelData
          Controls.Label { text: modelData.label; Layout.fillWidth: true; opacity: 0.7 }
          Controls.Label { text: modelData.value; elide: Text.ElideRight }
        }
      }
    }

    Traffic {
      Layout.fillWidth: true
      visible: !!(root.service && root.service.connected && root.service.linkDevice !== "")
      rxHistory: root.service ? root.service.rxHistory : []
      txHistory: root.service ? root.service.txHistory : []
      rxRate: root.service ? root.service.rxRate : 0
      txRate: root.service ? root.service.txRate : 0
      sessionRx: root.service ? root.service.sessionRx : 0
      sessionTx: root.service ? root.service.sessionTx : 0
      uptimeSec: root.service ? root.service.uptimeSec : 0
    }

    Controls.Label {
      visible: !!(root.service && root.service.gtkAppInstalled)
      text: "The Proton VPN GTK app is also installed — it can't run alongside the CLI."
      color: Kirigami.Theme.neutralTextColor
      wrapMode: Text.WordWrap
      Layout.fillWidth: true
    }

    Controls.Label {
      visible: !root.service || !root.service.installed
      text: "Proton VPN CLI not found. Install proton-vpn-cli (e.g. from the AUR), then press Refresh."
      wrapMode: Text.WordWrap
      Layout.fillWidth: true
    }

    RowLayout {
      Layout.fillWidth: true
      visible: !!(root.service && root.service.accountProbed && !root.service.signedIn)

      Controls.Label {
        text: "Signed out."
        Layout.fillWidth: true
      }
      Controls.Button {
        text: "Sign in…"
        enabled: !!(root.service && !root.service.busy)
        onClicked: if (root.service) root.service.signIn("")
      }
    }

    Controls.Label {
      visible: !!(root.service && root.service.lastError !== "")
      text: root.service ? root.service.lastError : ""
      color: Kirigami.Theme.negativeTextColor
      wrapMode: Text.WordWrap
      Layout.fillWidth: true
    }

    RowLayout {
      Layout.fillWidth: true
      visible: root.plusPlan
      spacing: Kirigami.Units.smallSpacing

      Controls.Button {
        Layout.fillWidth: true
        enabled: !!(root.service && !root.service.busy)
        text: "P2P"
        onClicked: if (root.service) root.service.connectP2P()
      }
      Controls.Button {
        Layout.fillWidth: true
        enabled: !!(root.service && !root.service.busy)
        text: "Secure Core"
        onClicked: if (root.service) root.service.connectSecureCore()
      }
      Controls.Button {
        Layout.fillWidth: true
        enabled: !!(root.service && !root.service.busy)
        text: "Tor"
        onClicked: if (root.service) root.service.connectTor()
      }
    }

    RowLayout {
      Layout.fillWidth: true
      visible: !!(root.service && root.service.portForwardingOn && root.service.forwardedPort !== "")
      Controls.Label {
        text: "Forwarded port: " + (root.service ? root.service.forwardedPort : "")
        Layout.fillWidth: true
      }
      Controls.ToolButton {
        icon.name: "edit-copy"
        onClicked: if (root.service) root.service.copyForwardedPort()
      }
    }

    Kirigami.Separator { Layout.fillWidth: true; visible: root.signedIn }

    RowLayout {
      Layout.fillWidth: true
      visible: root.signedIn && root.service && root.service.serversCountry === ""

      Controls.TextField {
        Layout.fillWidth: true
        placeholderText: "Search country…"
        text: root.countryFilter
        onTextChanged: root.countryFilter = text
      }
    }

    RowLayout {
      Layout.fillWidth: true
      visible: root.signedIn && root.service && root.service.serversCountry !== ""

      Controls.ToolButton {
        icon.name: "go-previous"
        text: "Countries"
        onClicked: if (root.service) root.service.clearServers()
      }
      Kirigami.Heading {
        level: 3
        Layout.fillWidth: true
        text: root.service ? root.service.serversCountryName : ""
      }
    }

    Controls.ScrollView {
      id: scroller
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: root.signedIn
      clip: true

      readonly property string mode: root.service && root.service.serversCountry !== "" ? "servers" : "countries"

      // One ColumnLayout, model-gated: an empty model contributes zero
      // height, so a hidden section never inflates the scroll content
      // (three sibling ColumnLayouts, each independently visible, would keep
      // their full size while hidden and leave a blank gap). Referencing
      // `scroller` by id rather than `parent` chains, since ScrollView (QQC2)
      // reparents its content into an internal Flickable at runtime.
      ColumnLayout {
        width: scroller.availableWidth
        spacing: 0

        Repeater {
          model: scroller.mode === "countries" ? root.filteredCountries : []
          delegate: Controls.ItemDelegate {
            required property var modelData
            Layout.fillWidth: true
            text: modelData.name + "  (" + modelData.code + ")"
            onClicked: if (root.service) root.service.loadServers(modelData.code, modelData.name)
          }
        }

        Controls.Label {
          visible: scroller.mode === "countries" && root.service && root.service.countriesLoaded && root.filteredCountries.length === 0
          text: "No match."
          opacity: 0.6
          Layout.fillWidth: true
        }

        Controls.Label {
          visible: scroller.mode === "countries" && root.service && !root.service.countriesLoaded
          text: "Loading countries…"
          opacity: 0.6
          Layout.fillWidth: true
        }

        Repeater {
          model: scroller.mode === "servers" && root.service ? root.service.servers : []
          delegate: Controls.ItemDelegate {
            required property var modelData
            Layout.fillWidth: true
            text: modelData.city
                  + (modelData.load !== undefined && modelData.load !== null ? "  ·  " + modelData.load + "%" : "")
                  + (modelData.tags && modelData.tags.length ? "  ·  " + modelData.tags.join(", ") : "")
            onClicked: if (root.service) root.service.connectServer(modelData.name, modelData.city)
          }
        }

        Controls.Label {
          visible: scroller.mode === "servers" && root.service && root.service.serversLoading
          text: "Loading servers…"
          opacity: 0.6
          Layout.fillWidth: true
        }

        Controls.Label {
          visible: scroller.mode === "servers" && root.service && !root.service.serversLoading && root.service.servers.length === 0
          text: "No server found for this country."
          opacity: 0.6
          Layout.fillWidth: true
        }
      }
    }
  }
}
