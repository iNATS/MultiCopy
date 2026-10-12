import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts history items back on the pasteboard and, if allowed, presses ⌘V in the frontmost app.
final class Paster {
    private let monitor: ClipboardMonitor

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
    }

    /// Accessibility permission is needed only to send the ⌘V keystroke.
    static var canSendKeystrokes: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Several items are pasted in the order they were copied: text is joined with newlines,
    /// files are pasted together, and mixed content (e.g. text + images) is pasted one by one.
    func paste(_ items: [ClipItem], autoPaste: Bool) {
        let ordered = items.sorted { $0.date < $1.date }
        guard let first = ordered.first else { return }

        if ordered.count == 1 {
            write(first.contents)
        } else if ordered.allSatisfy({ $0.kind == .text }) {
            let joined = ordered.compactMap(\.plainText).joined(separator: "\n")
            write([[.string: Data(joined.utf8)]])
        } else if ordered.allSatisfy({ $0.kind == .file }) || !autoPaste {
            write(ordered.flatMap(\.contents))
        } else {
            pasteOneByOne(ordered[...])
            return
        }
        if autoPaste { pressCommandV() }
    }

    private func pasteOneByOne(_ items: ArraySlice<ClipItem>) {
        guard let item = items.first else { return }
        write(item.contents)
        pressCommandV()
        // Give the target app time to read the pasteboard before it changes again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.pasteOneByOne(items.dropFirst())
        }
    }

    private func write(_ contents: ClipItem.Contents) {
        let pasteboard = monitor.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects(contents.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        })
        monitor.skipCurrentContents()
    }

    private func pressCommandV() {
        // Short delay so focus is back in the target app after our panel or menu closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard Self.canSendKeystrokes else { return }
            let source = CGEventSource(stateID: .combinedSessionState)
            // Keep keys the user is still physically holding from leaking into the paste.
            source?.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitSystemDefinedEvents],
                state: .eventSuppressionStateSuppressionInterval)
            let key = Self.keyCodeForV()
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    /// Finds the key that types "v" with ⌘ held, so pasting works on Dvorak, AZERTY, Arabic, etc.
    private static func keyCodeForV() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return fallback
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            for keyCode in 0..<128 {
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown),
                                            UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) {
                    return CGKeyCode(keyCode)
                }
            }
            return fallback
        }
    }
}
