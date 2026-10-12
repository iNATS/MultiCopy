import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// User preferences. Only these settings are persisted — clipboard contents never are.
final class Settings {
    static let shared = Settings()
    static let historySizes = [25, 50, 100, 200]

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "historyLimit": 50,
            "autoPaste": true,
            "clearOnLock": false,
            "shortcutIndex": 0,
        ])
    }

    var historyLimit: Int {
        get { min(max(defaults.integer(forKey: "historyLimit"), 5), 500) }
        set { defaults.set(newValue, forKey: "historyLimit") }
    }

    /// Press ⌘V for the user after they pick an item (needs Accessibility permission).
    var autoPaste: Bool {
        get { defaults.bool(forKey: "autoPaste") }
        set { defaults.set(newValue, forKey: "autoPaste") }
    }

    var clearOnLock: Bool {
        get { defaults.bool(forKey: "clearOnLock") }
        set { defaults.set(newValue, forKey: "clearOnLock") }
    }

    var shortcutIndex: Int {
        get { min(max(defaults.integer(forKey: "shortcutIndex"), 0), Shortcut.presets.count - 1) }
        set { defaults.set(newValue, forKey: "shortcutIndex") }
    }

    var shortcut: Shortcut { Shortcut.presets[shortcutIndex] }

    var didPromptForAccessibility: Bool {
        get { defaults.bool(forKey: "didPromptForAccessibility") }
        set { defaults.set(newValue, forKey: "didPromptForAccessibility") }
    }

    /// Extra apps to never record, set from Terminal:
    /// `defaults write com.mohamedaref.multicopy ignoredBundleIDs -array com.example.Vault`
    var extraIgnoredBundleIDs: Set<String> {
        Set(defaults.stringArray(forKey: "ignoredBundleIDs") ?? [])
    }
}

/// Global shortcut choices for opening the history panel.
struct Shortcut {
    let title: String
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let menuModifiers: NSEvent.ModifierFlags

    static let presets: [Shortcut] = [
        Shortcut(title: "⇧⌘V", keyCode: UInt32(kVK_ANSI_V),
                 carbonModifiers: UInt32(shiftKey | cmdKey), menuModifiers: [.shift, .command]),
        Shortcut(title: "⌥⌘V", keyCode: UInt32(kVK_ANSI_V),
                 carbonModifiers: UInt32(optionKey | cmdKey), menuModifiers: [.option, .command]),
        Shortcut(title: "⌃⌘V", keyCode: UInt32(kVK_ANSI_V),
                 carbonModifiers: UInt32(controlKey | cmdKey), menuModifiers: [.control, .command]),
        Shortcut(title: "⌃⌥⌘V", keyCode: UInt32(kVK_ANSI_V),
                 carbonModifiers: UInt32(controlKey | optionKey | cmdKey), menuModifiers: [.control, .option, .command]),
    ]
}

/// Launch at login: SMAppService on macOS 13+, a per-user LaunchAgent on macOS 12.
enum LoginItem {
    private static var label: String { Bundle.main.bundleIdentifier ?? "com.mohamedaref.multicopy" }

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return
        }
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: agentURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }
}
