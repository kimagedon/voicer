import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

// MARK: - Settings

enum Settings {
    /// Whisper Large v3 Turbo (full precision), embedded in the app bundle by build.sh.
    static let modelPath = Bundle.main.path(forResource: "ggml-large-v3-turbo", ofType: "bin")
        ?? Bundle.main.bundlePath + "/Contents/Resources/ggml-large-v3-turbo.bin"
}

/// The last few transcriptions, newest first, persisted across launches.
enum History {
    static let limit = 5
    private static let key = "history"

    static var items: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ text: String) {
        var list = items.filter { $0 != text }
        list.insert(text, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, recording, transcribing }

    private let hud = HUDController()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hotkey = HotkeyMonitor()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var status = "Loading model…"
    private var needsAccessibility = false

    private var state = State.idle
    private var pressedAt = Date()
    private var isLocked = false
    private var modelReady = false

    /// Holding the key longer than this is push-to-talk; a shorter tap locks recording on.
    private let holdThreshold: TimeInterval = 0.35

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voicer")
        menu.delegate = self
        statusItem.menu = menu

        loadModel()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        installHotkey(prompt: true)

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.model.push(level) }
        }
        hotkey.onPress = { [weak self] in self?.keyPressed() }
        hotkey.onRelease = { [weak self] in self?.keyReleased() }
        hotkey.onEscape = { [weak self] in self?.cancel() }
        hotkey.shouldCaptureEscape = { [weak self] in self?.state == .recording }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = recorder.stop()
        transcriber.unload()
    }

    // MARK: Hotkey flow

    private func keyPressed() {
        switch state {
        case .idle:
            startRecording()
        case .recording where isLocked:
            finishRecording()
        default:
            break
        }
    }

    private func keyReleased() {
        guard state == .recording, !isLocked else { return }
        if Date().timeIntervalSince(pressedAt) >= holdThreshold {
            finishRecording()
        } else {
            isLocked = true
            hud.update(.locked)
        }
    }

    private func startRecording() {
        guard modelReady else {
            hud.show(.message("Model is still loading…", symbol: "hourglass"))
            hud.hide(after: 1.6)
            return
        }
        do {
            try recorder.start()
        } catch {
            hud.show(.message("No microphone access", symbol: "mic.slash.fill"))
            hud.hide(after: 2)
            return
        }
        state = .recording
        isLocked = false
        pressedAt = Date()
        hud.model.reset()
        hud.show(.listening)
    }

    private func finishRecording() {
        let (samples, peak) = recorder.stop()
        // Under ~0.3 s or near-silence: nothing worth sending to the model.
        guard samples.count > 4_800, peak > 0.004 else { return cancel() }

        state = .transcribing
        hud.update(.transcribing)
        transcriber.transcribe(samples) { [weak self] text in
            DispatchQueue.main.async { self?.deliver(text) }
        }
    }

    private func deliver(_ text: String) {
        state = .idle
        guard !text.isEmpty else {
            hud.update(.message("Didn't catch that", symbol: "ear"))
            hud.hide(after: 1.2)
            return
        }
        History.add(text)
        Paster.paste(text)
        hud.update(.done)
        hud.hide(after: 0.9)
    }

    private func cancel() {
        _ = recorder.stop()
        state = .idle
        hud.hide()
    }

    // MARK: Setup

    private func loadModel() {
        modelReady = false
        guard FileManager.default.fileExists(atPath: Settings.modelPath) else {
            status = "Model not found"
            return
        }
        transcriber.load(path: Settings.modelPath) { [weak self] ok in
            DispatchQueue.main.async {
                self?.modelReady = ok
                self?.status = ok ? "Ready · Whisper Large v3 Turbo" : "Model failed to load"
            }
        }
    }

    /// The event tap needs Accessibility; keep retrying until the user grants it.
    private func installHotkey(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        needsAccessibility = !(AXIsProcessTrustedWithOptions(options) && hotkey.install())
        guard needsAccessibility else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installHotkey(prompt: false) }
    }

    // MARK: Menu

    /// Rebuilt on every open so status and history are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusItem = NSMenuItem(title: needsAccessibility ? "Accessibility access needed" : status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        if needsAccessibility {
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        // History lives in a hover submenu so the main menu stays compact.
        let history = History.items
        if !history.isEmpty {
            let recent = NSMenu()
            for text in history {
                let entry = item(Self.preview(text), #selector(copyHistory(_:)))
                entry.representedObject = text
                entry.toolTip = text
                recent.addItem(entry)
            }
            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            recentItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            recentItem.submenu = recent
            menu.addItem(recentItem)
        }

        let login = item("Launch at Login", #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voicer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// First words of a transcription, on one line.
    private static func preview(_ text: String, limit: Int = 42) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > limit ? String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hud.show(.message("Copied", symbol: "doc.on.doc"))
        hud.hide(after: 0.9)
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("Voicer: login item toggle failed: \(error)")
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Dev modes

    /// `--demo`: cycles the HUD through every state with a fake voice level.
    func runDemo() {
        hud.model.reset()
        hud.show(.listening)
        var t = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            t += 0.03
            let voice = max(0, sin(t * 2.1)) * (0.55 + 0.45 * sin(t * 17))
            self?.hud.model.push(Float(abs(voice)))
            if t > 3.5 { timer.invalidate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { self.hud.update(.transcribing) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) { self.hud.update(.done) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.6) { self.hud.hide() }
    }
}

// MARK: - Entry

let args = CommandLine.arguments

if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
    // Headless check: transcribe a file with the bundled model path and print it.
    let samples = try AudioRecorder.load(url: URL(fileURLWithPath: args[i + 1]))
    let transcriber = Transcriber()
    let done = DispatchSemaphore(value: 0)
    transcriber.load(path: Settings.modelPath) { ok in
        guard ok else { print("model failed to load"); exit(1) }
        let start = Date()
        transcriber.transcribe(samples) { text in
            print(text)
            print(String(format: "[%.2fs audio → %.2fs]", Double(samples.count) / 16_000, Date().timeIntervalSince(start)))
            done.signal()
        }
    }
    done.wait()
    transcriber.unload()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
if args.contains("--demo") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { delegate.runDemo() }
}
app.run()
