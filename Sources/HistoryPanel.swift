import AppKit
import Carbon.HIToolbox

/// Spotlight-style floating list of clipboard history. It's a *non-activating* panel: it takes
/// keyboard focus without activating MultiCopy, so the app you were typing in stays frontmost
/// and receives the paste.
final class HistoryPanel: NSPanel {
    var onPaste: (([ClipItem]) -> Void)?
    var onDelete: ((Set<UUID>) -> Void)?

    private let store: HistoryStore
    private var rows: [ClipItem] = []
    private var anchorRow = 0
    private var cursorRow = 0
    private var isSelectingProgrammatically = false

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private static let quickPasteKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                         kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    // The app has no menu bar of its own, so standard editing shortcuts are routed here.
    private static let editCommands: [Int: Selector] = [
        kVK_ANSI_A: #selector(NSText.selectAll(_:)),
        kVK_ANSI_C: #selector(NSText.copy(_:)),
        kVK_ANSI_V: #selector(NSText.paste(_:)),
        kVK_ANSI_X: #selector(NSText.cut(_:)),
        kVK_ANSI_Z: Selector(("undo:")),
    ]

    init(store: HistoryStore) {
        self.store = store
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        buildContent()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        hide()
    }

    override func cancelOperation(_ sender: Any?) {
        hide()
    }

    // MARK: Showing

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        searchField.stringValue = ""
        reload()
        moveNearMouse()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
        invalidateShadow()
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }

    /// Called whenever the history changes; refreshes the list if it's on screen.
    func historyDidChange() {
        guard isVisible else { return }
        reload(selecting: cursorRow)
    }

    private func moveNearMouse() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            center()
            return
        }
        let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(mouse.x, area.minX), area.maxX - frame.width)
        let y = min(max(mouse.y - frame.height, area.minY), area.maxY - frame.height)
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: List

    private func reload(selecting row: Int = 0) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = query.isEmpty ? store.items : store.items.filter { $0.matches(query) }
        tableView.reloadData()
        emptyLabel.stringValue = store.items.isEmpty ? "Copy something and it will show up here." : "No matches"
        emptyLabel.isHidden = !rows.isEmpty
        cursorRow = max(0, min(row, rows.count - 1))
        anchorRow = cursorRow
        applySelection()
    }

    private func applySelection() {
        guard !rows.isEmpty else { return }
        isSelectingProgrammatically = true
        let range = min(anchorRow, cursorRow)...max(anchorRow, cursorRow)
        tableView.selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
        isSelectingProgrammatically = false
        tableView.scrollRowToVisible(cursorRow)
    }

    private func moveCursor(by delta: Int, extending: Bool) {
        guard !rows.isEmpty else { return }
        cursorRow = min(max(cursorRow + delta, 0), rows.count - 1)
        if !extending { anchorRow = cursorRow }
        applySelection()
    }

    // MARK: Actions

    private func paste(rows indexes: IndexSet) {
        let items = indexes.filter { $0 < rows.count }.map { rows[$0] }
        guard !items.isEmpty else { return }
        hide()
        onPaste?(items)
    }

    @objc private func pasteClickedRow() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        let selection = tableView.selectedRowIndexes
        paste(rows: selection.contains(row) ? selection : IndexSet(integer: row))
    }

    private func removeSelected() {
        let selection = tableView.selectedRowIndexes.filter { $0 < rows.count }
        guard let first = selection.first else { return }
        onDelete?(Set(selection.map { rows[$0].id }))
        reload(selecting: first)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command {
            let key = Int(event.keyCode)
            if let index = Self.quickPasteKeys.firstIndex(of: key) {
                paste(rows: IndexSet(integer: index))
                return true
            }
            if let action = Self.editCommands[key], NSApp.sendAction(action, to: nil, from: self) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Layout

    private func buildContent() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = .roundedRectMask(radius: 12)
        contentView = background

        searchField.placeholderString = "Search clipboard history"
        searchField.focusRingType = .none
        searchField.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 28
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelection = true
        tableView.refusesFirstResponder = true // typing always goes to the search field
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(pasteClickedRow)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let hint = NSTextField(labelWithString:
            "↩ paste  ·  ⇧↑↓ or ⌘-click to pick several  ·  ⌘1–9 quick paste  ·  ⌘⌫ remove  ·  esc close")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        for view in [searchField, scrollView, hint, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }
}

// MARK: - Search field keyboard handling

extension HistoryPanel: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveCursor(by: -1, extending: false)
        case #selector(NSResponder.moveDown(_:)):
            moveCursor(by: 1, extending: false)
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            moveCursor(by: -1, extending: true)
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            moveCursor(by: 1, extending: true)
        case #selector(NSResponder.insertNewline(_:)):
            paste(rows: tableView.selectedRowIndexes)
        case #selector(NSResponder.deleteToBeginningOfLine(_:)): // ⌘⌫
            removeSelected()
        case #selector(NSResponder.cancelOperation(_:)): // esc clears the search, then closes
            if searchField.stringValue.isEmpty {
                hide()
            } else {
                searchField.stringValue = ""
                reload()
            }
        default:
            return false
        }
        return true
    }
}

// MARK: - Table

extension HistoryPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ClipCell.identifier, owner: nil) as? ClipCell ?? ClipCell()
        cell.configure(with: rows[row], number: row < 9 ? row + 1 : nil)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically, tableView.selectedRow >= 0 else { return }
        cursorRow = tableView.selectedRow
        anchorRow = cursorRow
    }
}

/// Draws the selection in the accent color even though the search field, not the table, has focus.
private final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class ClipCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ClipCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = title

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        shortcut.textColor = .secondaryLabelColor
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [icon, title, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(with item: ClipItem, number: Int?) {
        icon.image = item.icon
        title.stringValue = item.title
        shortcut.stringValue = number.map { "⌘\($0)" } ?? ""
        toolTip = item.preview
    }
}

private extension NSImage {
    /// A stretchable mask that gives the blurred panel background rounded corners.
    static func roundedRectMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
