import AppKit

/// Fine-tunes the private `glassBackground` filter inside an NSGlassEffectView.
///
/// Variant 11 gives the system HUD's crisp edge lensing but ships with blur and
/// face tint switched off, and it ignores the user's Liquid Glass preference
/// (System Settings → Appearance, stored as `NSGlassTintAmount`, 0 = clear,
/// 1 = tinted). `current` maps that slider onto blur only, so the HUD frosts
/// along with the rest of the system while keeping its own shade.
/// Everything here is best-effort: if the layer or filter is missing, nothing happens.
struct GlassTuning {
    var blurRadius: Double
    var faceOpacity: Double
    var faceWhite: Double
    var faceBlack: Double = 0
    var faceSaturation: Double = 1
    /// Alpha of the white face fill the system adds for tinted glass.
    var faceFillAlpha: Double = 0
    /// Frosted fill layered over the refracted backdrop in tinted glass.
    var blurFillOpacity: Double = 0
    var blurFillLightenOpacity: Double = 0
    /// Strength of the specular key highlight (system default for this variant: 0.4).
    var highlightAmount: Double = 0.4
    /// Opacity of the two SDF rim layers that draw the glass edge light.
    var rimOpacity: Float = 1
    /// Lensing just outside the edge (variant 11 default: 10). Tinted glass drops it,
    /// otherwise crisp backdrop detail leaks around a frosted body.
    var outerRefractionAmount: Double = 10

    /// Clear end: matched side by side against the macOS 27 volume HUD over the same
    /// backdrop, then darkened slightly and given a thinner, quieter edge light.
    /// Blur is nearly a step: ≤0.5 renders crisp, 0.6 barely softens, 0.7 reads as matte.
    /// The face matrix only takes effect with saturation ≠ 1.
    static let clear = GlassTuning(
        blurRadius: 0.6, faceOpacity: 1, faceWhite: 0.82, faceBlack: 0.15, faceSaturation: 1.3,
        highlightAmount: 0.2, rimOpacity: 0.5
    )

    /// Tinted end: matched against the volume HUD at `NSGlassTintAmount = 1` over the
    /// same backdrop — heavier blur, calmer saturation, no outer lensing, same shade.
    /// The system's white fill and lightening layer are left out on purpose: the
    /// volume HUD doesn't lighten, it only frosts.
    static let tinted: GlassTuning = {
        var t = clear
        t.blurRadius = 8
        t.faceSaturation = 1.1
        t.outerRefractionAmount = 0
        return t
    }()

    /// The user's current Liquid Glass setting. Synchronizes first, so a change made in
    /// System Settings a moment ago is already visible to this process.
    static var tintAmount: Double {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value = CFPreferencesCopyAppValue("NSGlassTintAmount" as CFString, kCFPreferencesAnyApplication) as? Double ?? 0
        return min(max(value, 0), 1)
    }

    static var current: GlassTuning { clear.mixed(with: tinted, by: tintAmount) }

    func mixed(with other: GlassTuning, by t: Double) -> GlassTuning {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        // Perceived blur tracks log(radius): most of the visible change happens at small
        // radii, so a linear ramp would front-load the whole effect into the first stretch
        // of the slider. Interpolating geometrically makes every step look equal.
        func mixBlur(_ a: Double, _ b: Double) -> Double {
            guard a > 0, b > 0 else { return mix(a, b) }
            return a * pow(b / a, t)
        }
        return GlassTuning(
            blurRadius: mixBlur(blurRadius, other.blurRadius),
            faceOpacity: mix(faceOpacity, other.faceOpacity),
            faceWhite: mix(faceWhite, other.faceWhite),
            faceBlack: mix(faceBlack, other.faceBlack),
            faceSaturation: mix(faceSaturation, other.faceSaturation),
            faceFillAlpha: mix(faceFillAlpha, other.faceFillAlpha),
            blurFillOpacity: mix(blurFillOpacity, other.blurFillOpacity),
            blurFillLightenOpacity: mix(blurFillLightenOpacity, other.blurFillLightenOpacity),
            highlightAmount: mix(highlightAmount, other.highlightAmount),
            rimOpacity: Float(mix(Double(rimOpacity), Double(other.rimOpacity))),
            outerRefractionAmount: mix(outerRefractionAmount, other.outerRefractionAmount)
        )
    }

    /// Applies once the glass has built its layer tree (it does so lazily), retrying briefly.
    func apply(to view: NSView, attempts: Int = 20) {
        guard applyNow(to: view) else {
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.apply(to: view, attempts: attempts - 1) }
            }
            return
        }
    }

    @discardableResult
    func applyNow(to view: NSView) -> Bool {
        guard let root = view.layer, let backdrop = Self.findBackdrop(in: root) else { return false }
        let path = "filters.glassBackground."
        backdrop.setValue(blurRadius, forKeyPath: path + "inputBlurRadius")
        for i in 0...3 { backdrop.setValue(1.0, forKeyPath: path + "inputBlurOpacity\(i)") }
        backdrop.setValue(faceOpacity, forKeyPath: path + "inputFaceOpacity")
        backdrop.setValue(faceWhite, forKeyPath: path + "inputFaceColorMatrixWhite")
        backdrop.setValue(faceBlack, forKeyPath: path + "inputFaceColorMatrixBlack")
        backdrop.setValue(faceSaturation, forKeyPath: path + "inputFaceColorMatrixSaturation")
        backdrop.setValue(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: faceFillAlpha), forKeyPath: path + "inputFaceColorMatrixFillColor")
        backdrop.setValue(8.0, forKeyPath: path + "inputBlurFillBlurRadius")
        backdrop.setValue(blurFillOpacity, forKeyPath: path + "inputBlurFillNormalOpacity")
        backdrop.setValue(blurFillLightenOpacity, forKeyPath: path + "inputBlurFillLightenOpacity")
        backdrop.setValue(highlightAmount, forKeyPath: path + "inputKeyFillHighlightAmount")
        backdrop.setValue(outerRefractionAmount, forKeyPath: path + "inputOuterRefractionAmount")
        for rim in backdrop.superlayer?.sublayers ?? [] where rim.name == "@2" || rim.name == "@3" {
            rim.opacity = rimOpacity
        }
        return true
    }

    private static func findBackdrop(in layer: CALayer) -> CALayer? {
        if String(describing: type(of: layer)) == "CABackdropLayer",
           (layer.filters as? [NSObject])?.contains(where: { ($0.value(forKey: "name") as? String) == "glassBackground" }) == true {
            return layer
        }
        for sub in layer.sublayers ?? [] {
            if let found = findBackdrop(in: sub) { return found }
        }
        return nil
    }
}
