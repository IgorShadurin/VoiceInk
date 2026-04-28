import Foundation
import AppKit
import Carbon
import os

private let logger = Logger(subsystem: "com.VoiceInk", category: "CursorPaster")

class CursorPaster {

    static func pasteAtCursor(_ text: String) {
        let pasteboard = NSPasteboard.general
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")

        var savedContents: [(NSPasteboard.PasteboardType, Data)] = []

        if shouldRestoreClipboard {
            let currentItems = pasteboard.pasteboardItems ?? []

            for item in currentItems {
                for type in item.types {
                    if let data = item.data(forType: type) {
                        savedContents.append((type, data))
                    }
                }
            }
        }

        ClipboardManager.setClipboard(text, transient: shouldRestoreClipboard)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if UserDefaults.standard.bool(forKey: "useAppleScriptPaste") {
                pasteUsingAppleScript()
            } else {
                pasteFromClipboard()
            }
        }

        if shouldRestoreClipboard {
            let restoreDelay = UserDefaults.standard.double(forKey: "clipboardRestoreDelay")
            let delay = max(restoreDelay, 0.25)

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !savedContents.isEmpty {
                    pasteboard.clearContents()
                    for (type, data) in savedContents {
                        pasteboard.setData(data, forType: type)
                    }
                }
            }
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript("tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode   = makeScript("tell application \"System Events\" to key code 9 using command down")

    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    private static func pasteUsingAppleScript() {
        let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error = error {
            logger.error("AppleScript paste failed: \(error, privacy: .public)")
        }
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    private static func pasteFromClipboard() {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility not trusted — cannot paste")
            return
        }

        let source = CGEventSource(stateID: .privateState)

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        cmdDown?.flags = .maskCommand
        vDown?.flags   = .maskCommand
        vUp?.flags     = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        logger.notice("CGEvents posted for Cmd+V")
    }

    // MARK: - Auto Send Keys

    static func performAutoSend(_ key: AutoSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let virtualKey: CGKeyCode
        switch key {
        case .tab:
            virtualKey = 0x30
        default:
            virtualKey = 0x24
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)

        switch key {
        case .none: return
        case .enter, .tab: break
        case .shiftEnter:
            keyDown?.flags = .maskShift
            keyUp?.flags   = .maskShift
        case .commandEnter:
            keyDown?.flags = .maskCommand
            keyUp?.flags   = .maskCommand
        }

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
