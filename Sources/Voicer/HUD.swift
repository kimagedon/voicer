import AppKit
import Observation
import SwiftUI

enum HUDPhase: Equatable {
    case listening
    case locked      // hands-free: key was tapped, recording until the next tap
    case transcribing
    case done
    case message(String, symbol: String)
}

@Observable
final class HUDModel {
    static let barCount = 30

    var phase: HUDPhase = .listening
    var visible = false
    var startDate = Date()
    /// Scrolling level history, newest last, each 0…1.
    var levels = [CGFloat](repeating: 0, count: barCount)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(CGFloat(level))
    }

    func reset() {
        levels = [CGFloat](repeating: 0, count: Self.barCount)
        startDate = Date()
    }
}

// MARK: - Panel

/// Borderless, non-activating floating panel that never steals focus from the
/// app being dictated into. Sits top-right, where the system volume HUD lives.
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    // Measured off the macOS 27 volume HUD: 290×62 pt, ~24 pt continuous corners,
    // 11 pt from the right screen edge and 11 pt under the menu bar.
    static let hudSize = CGSize(width: 290, height: 62)
    static let cornerRadius: CGFloat = 24
    private static let edgeInset: CGFloat = 11
    private static let margin: CGFloat = 32 // room for scale-in and shadow

    private let glass = NSGlassEffectView()

    init() {
        let size = CGSize(width: Self.hudSize.width + Self.margin * 2, height: Self.hudSize.height + Self.margin * 2)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Native AppKit glass — the same primitive the system HUDs are built on.
        glass.style = .clear
        glass.cornerRadius = Self.cornerRadius
        setGlassVariant(Self.preferredVariant)
        glass.contentView = NSHostingView(rootView: HUDView(model: model))
        glass.alphaValue = 0
        glass.frame = restingFrame(scale: 0.9)

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.addSubview(glass)
        panel.contentView = root
    }

    private var glassVariant: Int?
    private var settingsWatch: Timer?
    /// Tint currently rendered, and the value it is easing toward.
    private var shownTint: Double?
    private var targetTint = 0.0
    private var framesSincePoll = 0

    /// Private variant 11 is the system HUDs' edge-lensing glass (public .clear/.regular
    /// are frosted). With Reduce Transparency on, the standard variant 0 is used untouched,
    /// so the system renders it exactly as it does its own.
    private static var preferredVariant: Int {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0 : 11
    }

    /// Returns true if the variant changed (the glass then rebuilds its layer tree).
    @discardableResult
    private func setGlassVariant(_ variant: Int) -> Bool {
        // Guarded so a future OS without these internals falls back to public .clear.
        guard variant != glassVariant, glass.responds(to: NSSelectorFromString("set_variant:")) else { return false }
        glass.setValue(variant, forKey: "_variant")
        glassVariant = variant
        return true
    }

    /// Re-reads the user's settings on every appearance: Reduce Transparency picks the
    /// variant, and the Liquid Glass clear↔tinted slider drives the tuning.
    private func configureGlass() {
        let variant = Self.preferredVariant
        let rebuilt = setGlassVariant(variant)
        guard variant == 11 else { return }
        targetTint = GlassTuning.tintAmount
        shownTint = targetTint
        let tuning = GlassTuning.current
        if rebuilt {
            // Let the glass build its new layer tree before touching the filter.
            DispatchQueue.main.async { tuning.apply(to: self.glass) }
        } else {
            tuning.apply(to: glass)
        }
    }

    /// While the HUD is on screen, follows the Liquid Glass slider and Reduce
    /// Transparency live. Settings are polled ~10×/s; the rendered tint eases toward
    /// the latest value every frame, so dragging the slider morphs the glass smoothly.
    private func watchSettings() {
        settingsWatch?.invalidate()
        framesSincePoll = 0
        settingsWatch = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.stepGlass()
        }
    }

    private func stepGlass() {
        framesSincePoll += 1
        if framesSincePoll >= 6 {
            framesSincePoll = 0
            if Self.preferredVariant != glassVariant { return configureGlass() }
            targetTint = GlassTuning.tintAmount
        }
        guard glassVariant == 11, let shown = shownTint, shown != targetTint else { return }
        // Exponential ease: ~90% of the way in a quarter second, then snap.
        var next = shown + (targetTint - shown) * 0.15
        if abs(targetTint - next) < 0.002 { next = targetTint }
        shownTint = next
        GlassTuning.clear.mixed(with: .tinted, by: next).applyNow(to: glass)
    }

    /// The HUD rect inside the panel, top-right aligned; `scale` < 1 shrinks it toward its top edge.
    private func restingFrame(scale: CGFloat = 1) -> NSRect {
        let w = Self.hudSize.width * scale, h = Self.hudSize.height * scale
        let panelSize = NSSize(width: Self.hudSize.width + Self.margin * 2, height: Self.hudSize.height + Self.margin * 2)
        let midX = panelSize.width - Self.margin - Self.hudSize.width / 2
        let top = panelSize.height - Self.margin
        return NSRect(x: midX - w / 2, y: top - h, width: w, height: h).integral
    }

    func show(_ phase: HUDPhase) {
        hideWork?.cancel()
        if !model.visible {
            position()
            panel.orderFrontRegardless()
            configureGlass()
            watchSettings()
        }
        model.visible = true
        withAnimation(.smooth(duration: 0.25)) { model.phase = phase }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.1)
            glass.animator().alphaValue = 1
            glass.animator().frame = restingFrame()
        }
    }

    func update(_ phase: HUDPhase) {
        withAnimation(.smooth(duration: 0.3)) { model.phase = phase }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.visible = false
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.glass.animator().alphaValue = 0
                self.glass.animator().frame = self.restingFrame(scale: 0.9)
            }, completionHandler: {
                guard !self.model.visible else { return }
                self.panel.orderOut(nil)
                self.settingsWatch?.invalidate()
                self.settingsWatch = nil
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let size = panel.frame.size
        // Right edge from the full frame (a right-side Dock shrinks visibleFrame); top from the menu bar.
        let menuBarBottom = screen.visibleFrame.maxY
        let origin = CGPoint(
            x: screen.frame.maxX - size.width + Self.margin - Self.edgeInset,
            y: menuBarBottom - size.height + Self.margin - Self.edgeInset
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - Views

/// Same anatomy as the system volume HUD: a title line, then a control row
/// (icon · track · trailing glyph). All content is white over clear glass.
struct HUDView: View {
    let model: HUDModel

    private var title: String {
        switch model.phase {
        case .listening, .locked: "Listening"
        case .transcribing: "Transcribing…"
        case .done: "Pasted"
        case let .message(text, _): text
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.opacity)
                .frame(height: 16)
                .padding(.leading, 1)

            HStack(spacing: 9) {
                SymbolBadge(phase: model.phase)
                track
                    .frame(maxWidth: .infinity)
                trailing
            }
            .frame(height: 22)
        }
        .foregroundStyle(.white)
        // Keeps white glyphs legible over busy content seen through the clear glass.
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        .padding(.horizontal, 15)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: HUDController.hudSize.width, height: HUDController.hudSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var track: some View {
        switch model.phase {
        case .listening, .locked:
            LiveWaveform(levels: model.levels)
                .transition(.opacity)
        case .transcribing:
            ThinkingWave()
                .transition(.opacity)
        default:
            LiveWaveform(levels: [CGFloat](repeating: 0, count: HUDModel.barCount))
                .transition(.opacity)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.phase {
        case .listening, .locked:
            Text(timerInterval: model.startDate...Date.distantFuture, countsDown: false)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 32, alignment: .trailing)
                .transition(.opacity)
        default:
            Color.clear.frame(width: 32)
        }
    }
}

/// The small round glyph in the icon slot. Red with a soft pulse while recording.
/// The pulse runs on TimelineView (no @State: the CLT toolchain ships without
/// the SwiftUI macro plugin).
struct SymbolBadge: View {
    let phase: HUDPhase

    private var symbol: String {
        switch phase {
        case .listening, .locked: "mic.fill"
        case .transcribing: "waveform"
        case .done: "checkmark"
        case let .message(_, symbol): symbol
        }
    }

    private var isRecording: Bool { phase == .listening || phase == .locked }

    var body: some View {
        ZStack {
            Circle()
                .fill(isRecording ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(.white.opacity(0.22)))
            if isRecording {
                TimelineView(.animation) { context in
                    let p = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    let eased = 1 - pow(1 - p, 3)
                    Circle()
                        .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
                        .scaleEffect(1 + eased * 0.5)
                        .opacity(0.9 * (1 - eased))
                }
                .transition(.opacity)
            }
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: phase == .transcribing)
        }
        .frame(width: 22, height: 22)
        .animation(.smooth(duration: 0.3), value: isRecording)
    }
}

/// Scrolling voice-level bars. Silence collapses to the same dotted track the
/// volume HUD shows past its fill.
struct LiveWaveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(levels.indices, id: \.self) { i in
                let level = levels[i]
                Capsule()
                    .fill(.white.opacity(0.45 + 0.55 * min(level * 3, 1)))
                    .frame(width: 3, height: 3 + level * 17)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: 22)
        .animation(.interactiveSpring(duration: 0.14), value: levels)
    }
}

/// Soft travelling wave shown while the model is transcribing.
struct ThinkingWave: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 0) {
                ForEach(0..<HUDModel.barCount, id: \.self) { i in
                    let wave = sin(t * 5.5 - Double(i) * 0.38) * 0.5 + 0.5
                    Capsule()
                        .fill(.white.opacity(0.45 + wave * 0.55))
                        .frame(width: 3, height: 3 + wave * 9)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxHeight: 22)
    }
}
