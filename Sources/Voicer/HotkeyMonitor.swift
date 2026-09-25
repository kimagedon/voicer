import AppKit
import Carbon.HIToolbox

/// Grabs the dictation (microphone) key in the F5 slot before macOS does.
///
/// Carbon hotkeys and NSEvent monitors fire too late — the system has already
/// started its own dictation. A CGEvent tap at the HID level, inserted at the
/// head of the chain, sees the press first and swallows it.
final class HotkeyMonitor: @unchecked Sendable {
    /// Built-in keyboards report the mic key as F5; some external ones use 176.
    static let triggerKeyCodes: Set<Int64> = [Int64(kVK_F5), 176]

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Escape is swallowed only while this returns true (i.e. while recording).
    var shouldCaptureEscape: () -> Bool = { false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    var isInstalled: Bool { tap != nil }

    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue().handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps it considers slow; re-arm immediately.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == Int64(kVK_Escape), type == .keyDown, shouldCaptureEscape() {
            DispatchQueue.main.async { self.onEscape?() }
            return nil
        }

        guard Self.triggerKeyCodes.contains(keyCode) else { return Unmanaged.passUnretained(event) }
        // Leave ⌘/⌥/⌃/⇧ combos alone (⌘F5 is VoiceOver). fn is fine — it's how F-keys are typed.
        let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        guard modifiers.isEmpty || isDown else { return Unmanaged.passUnretained(event) }

        if type == .keyDown {
            if !isDown {
                isDown = true
                DispatchQueue.main.async { self.onPress?() }
            }
        } else if type == .keyUp {
            isDown = false
            DispatchQueue.main.async { self.onRelease?() }
        }
        return nil
    }
}
