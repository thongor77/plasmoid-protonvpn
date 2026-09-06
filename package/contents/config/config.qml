import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("Protections")
        icon: "security-high"
        source: "config/ConfigProtections.qml"
    }
    ConfigCategory {
        name: i18n("Split Tunneling")
        icon: "network-vpn"
        source: "config/ConfigSplitTunneling.qml"
    }
}
