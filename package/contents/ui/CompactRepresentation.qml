import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

// The panel/tray icon. Mouse mapping matches the upstream bar widget:
// left-click opens the panel, right-click connects fastest or disconnects,
// middle-click refreshes.
Item {
  id: root

  property var service

  Layout.minimumWidth: Kirigami.Units.iconSizes.small
  Layout.minimumHeight: Kirigami.Units.iconSizes.small
  Layout.preferredWidth: Kirigami.Units.iconSizes.small
  Layout.preferredHeight: Kirigami.Units.iconSizes.small

  ProtonIcon {
    id: icon
    anchors.centerIn: parent
    iconSize: Math.min(root.width, root.height)
    color: root.service && root.service.connected ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
    opacity: root.service && root.service.connected ? 1.0 : 0.55
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) {
        Plasmoid.expanded = !Plasmoid.expanded
      } else if (mouse.button === Qt.RightButton) {
        if (!root.service) return
        if (root.service.connected) root.service.disconnect()
        else root.service.connectFastest()
      } else if (mouse.button === Qt.MiddleButton) {
        if (root.service) root.service.refresh()
      }
    }
  }
}
