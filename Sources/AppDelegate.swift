import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private lazy var store = HistoryStore(limit: settings.historyLimit)
    private lazy var monitor = ClipboardMonitor(store: store, extraIgnoredApps: settings.extraIgnoredBundleIDs)
    private lazy var paster = Paster(monitor: monitor)
    private lazy var panel = HistoryPanel(store: store)
    private lazy var hotKey = HotKey { [weak self] in self?.panel.toggle() }
    private var statusItem: NSStatusItem?
    private var promptedForAccessibilityThisSession = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "MultiCopy")
        item.button?.toolTip = "MultiCopy"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        panel.onPaste = { [weak self] items in self?.paste(items) }
        panel.onDelete = { [weak self] ids in self?.store.remove(ids) }
        store.onChange = { [weak self] in self?.panel.historyDidChange() }

        registerShortcut()
        monitor.start()
        observeLockAndSleep()

        if settings.autoPaste, !Paster.canSendKeystrokes, !settings.didPromptForAccessibility {
            settings.didPromptForAccessibility = true
            Paster.requestAccessibility()
        }
    }

    private func paste(_ items: [ClipItem]) {
        var autoPaste = settings.autoPaste
        if autoPaste, !Paster.canSendKeystrokes {
            // Still useful without permission: the item is on the clipboard, ready for ⌘V.
            autoPaste = false
            if !promptedForAccessibilityThisSession {
                promptedForAccessibilityThisSession = true
                Paster.requestAccessibility()
            }
        }
        paster.paste(items, autoPaste: autoPaste)
        if items.count == 1 { store.promote(items[0].id) }
    }

    private func registerShortcut() {
        let shortcut = settings.shortcut
        if !hotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers) {
            showAlert("\(shortcut.title) is already in use",
                      "Choose another shortcut in the MultiCopy menu under Settings ▸ Shortcut.")
        }
    }

    private func observeLockAndSleep() {
        let selector = #selector(sessionWillLock)
        DistributedNotificationCenter.default().addObserver(
            self, selector: selector, name: .init("com.apple.screenIsLocked"), object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: selector, name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: selector, name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    }

    @objc private func sessionWillLock() {
        panel.hide()
        if settings.clearOnLock { store.clear() }
    }

    // MARK: Menu bar menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let show = addItem(to: menu, "Show Clipboard History", #selector(showPanel))
        show.keyEquivalent = "v"
        show.keyEquivalentModifierMask = settings.shortcut.menuModifiers
        menu.addItem(.separator())

        if store.items.isEmpty {
            addItem(to: menu, "Nothing copied yet", nil).isEnabled = false
        }
        for (index, clip) in store.items.prefix(10).enumerated() {
            let item = addItem(to: menu, clip.title.truncated(to: 60), #selector(pasteFromMenu(_:)))
            item.representedObject = clip.id
            item.image = clip.icon?.fitted(to: 16)
            item.toolTip = clip.preview
            if index < 9 {
                item.keyEquivalent = "\(index + 1)"
                item.keyEquivalentModifierMask = []
            }
        }
        if store.items.count > 10 {
            addItem(to: menu, "\(store.items.count - 10) more…", #selector(showPanel))
        }

        menu.addItem(.separator())
        addItem(to: menu, "Clear History", #selector(clearHistory)).isEnabled = !store.items.isEmpty
        addItem(to: menu, "Pause Capturing", #selector(togglePause)).state = monitor.isPaused ? .on : .off
        menu.addItem(settingsMenuItem())

        if settings.autoPaste, !Paster.canSendKeystrokes {
            addItem(to: menu, "Allow Auto-Paste (Accessibility)…", #selector(openAccessibilitySettings))
        }
        if #available(macOS 15.4, *), [.ask, .alwaysDeny].contains(NSPasteboard.general.accessBehavior) {
            addItem(to: menu, "Allow Clipboard Access…", #selector(openPrivacySettings))
        }

        menu.addItem(.separator())
        addItem(to: menu, "Quit MultiCopy", #selector(quit)).keyEquivalent = "q"
    }

    private func settingsMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addItem(to: menu, "Paste Automatically", #selector(toggleAutoPaste)).state = settings.autoPaste ? .on : .off
        addItem(to: menu, "Clear History on Lock & Sleep", #selector(toggleClearOnLock)).state = settings.clearOnLock ? .on : .off
        addItem(to: menu, "Launch at Login", #selector(toggleLaunchAtLogin)).state = LoginItem.isEnabled ? .on : .off
        menu.addItem(.separator())

        let sizes = NSMenu()
        for size in Settings.historySizes {
            let item = addItem(to: sizes, "\(size) items", #selector(setHistorySize(_:)))
            item.tag = size
            item.state = size == settings.historyLimit ? .on : .off
        }
        menu.addItem(withTitle: "History Size", action: nil, keyEquivalent: "").submenu = sizes

        let shortcuts = NSMenu()
        for (index, shortcut) in Shortcut.presets.enumerated() {
            let item = addItem(to: shortcuts, shortcut.title, #selector(setShortcut(_:)))
            item.tag = index
            item.state = index == settings.shortcutIndex ? .on : .off
        }
        menu.addItem(withTitle: "Shortcut", action: nil, keyEquivalent: "").submenu = shortcuts

        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Menu actions

    @objc private func showPanel() {
        panel.show()
    }

    @objc private func pasteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let clip = store.items.first(where: { $0.id == id }) else { return }
        paste([clip])
    }

    @objc private func clearHistory() {
        store.clear()
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        statusItem?.button?.appearsDisabled = monitor.isPaused
    }

    @objc private func toggleAutoPaste() {
        settings.autoPaste.toggle()
        if settings.autoPaste, !Paster.canSendKeystrokes { Paster.requestAccessibility() }
    }

    @objc private func toggleClearOnLock() {
        settings.clearOnLock.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            showAlert("Couldn't change Launch at Login", error.localizedDescription)
        }
    }

    @objc private func setHistorySize(_ sender: NSMenuItem) {
        settings.historyLimit = sender.tag
        store.limit = settings.historyLimit
    }

    @objc private func setShortcut(_ sender: NSMenuItem) {
        settings.shortcutIndex = sender.tag
        registerShortcut()
    }

    @objc private func openAccessibilitySettings() {
        Paster.requestAccessibility()
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openPrivacySettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func openSettingsPane(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private extension String {
    func truncated(to length: Int) -> String {
        count > length ? String(prefix(length - 1)) + "…" : self
    }
}

private extension NSImage {
    func fitted(to side: CGFloat) -> NSImage {
        guard let image = copy() as? NSImage else { return self }
        let scale = side / max(size.width, size.height, 1)
        image.size = NSSize(width: size.width * scale, height: size.height * scale)
        return image
    }
}
