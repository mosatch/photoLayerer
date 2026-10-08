import CoreGraphics
import Foundation

struct Layer: Identifiable {
    var id: UUID
    var name: String
    var bitmap: Bitmap
    /// Top-left of the bitmap in canvas coordinates (y grows downward, as in PSD).
    var x: Int
    var y: Int
    var isVisible = true
    var opacity: Double = 1
    var blendMode: BlendMode = .normal
    var effects: [LayerEffect] = []

    init(id: UUID = UUID(), name: String, bitmap: Bitmap, x: Int = 0, y: Int = 0) {
        self.id = id
        self.name = name
        self.bitmap = bitmap
        self.x = x
        self.y = y
    }

    var frame: CGRect {
        CGRect(x: x, y: y, width: bitmap.width, height: bitmap.height)
    }

    /// Same settings and an independent copy of the pixels.
    func deepCopy(newID: Bool = false) -> Layer {
        var copy = self
        copy.bitmap = bitmap.copy()
        if newID { copy.id = UUID() }
        return copy
    }
}

/// Raw values are the four-character Photoshop blend mode keys.
enum BlendMode: String, CaseIterable, Identifiable, Codable {
    case normal = "norm"
    case darken = "dark"
    case multiply = "mul "
    case colorBurn = "idiv"
    case linearBurn = "lbrn"
    case lighten = "lite"
    case screen = "scrn"
    case colorDodge = "div "
    case linearDodge = "lddg"
    case overlay = "over"
    case softLight = "sLit"
    case hardLight = "hLit"
    case difference = "diff"
    case exclusion = "smud"
    case hue = "hue "
    case saturation = "sat "
    case color = "colr"
    case luminosity = "lum "

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .linearBurn: "Linear Burn"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .linearDodge: "Linear Dodge (Add)"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    var ciFilterName: String {
        switch self {
        case .normal: "CISourceOverCompositing"
        case .darken: "CIDarkenBlendMode"
        case .multiply: "CIMultiplyBlendMode"
        case .colorBurn: "CIColorBurnBlendMode"
        case .linearBurn: "CILinearBurnBlendMode"
        case .lighten: "CILightenBlendMode"
        case .screen: "CIScreenBlendMode"
        case .colorDodge: "CIColorDodgeBlendMode"
        case .linearDodge: "CILinearDodgeBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .softLight: "CISoftLightBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        case .difference: "CIDifferenceBlendMode"
        case .exclusion: "CIExclusionBlendMode"
        case .hue: "CIHueBlendMode"
        case .saturation: "CISaturationBlendMode"
        case .color: "CIColorBlendMode"
        case .luminosity: "CILuminosityBlendMode"
        }
    }

    /// Groups for the picker, separated the way Photoshop's menu is.
    static let groups: [[BlendMode]] = [
        [.normal],
        [.darken, .multiply, .colorBurn, .linearBurn],
        [.lighten, .screen, .colorDodge, .linearDodge],
        [.overlay, .softLight, .hardLight],
        [.difference, .exclusion],
        [.hue, .saturation, .color, .luminosity],
    ]
}

/// A non-destructive filter applied to one layer when compositing.
struct LayerEffect: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: Kind
    var isEnabled = true
    var values: [String: Double]

    init(kind: Kind) {
        self.kind = kind
        values = Dictionary(uniqueKeysWithValues: kind.parameters.map { ($0.key, $0.defaultValue) })
    }

    func value(_ key: String) -> Double {
        values[key] ?? kind.parameters.first { $0.key == key }?.defaultValue ?? 0
    }

    struct Parameter: Hashable {
        let key: String
        let label: String
        let range: ClosedRange<Double>
        let defaultValue: Double
    }

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case colorAdjust, exposure, hue, temperature, blur, sharpen, vignette
        case sepia, mono, invert, posterize, dropShadow

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .colorAdjust: "Brightness / Contrast"
            case .exposure: "Exposure"
            case .hue: "Hue Shift"
            case .temperature: "Temperature & Tint"
            case .blur: "Gaussian Blur"
            case .sharpen: "Sharpen"
            case .vignette: "Vignette"
            case .sepia: "Sepia"
            case .mono: "Black & White"
            case .invert: "Invert"
            case .posterize: "Posterize"
            case .dropShadow: "Drop Shadow"
            }
        }

        var parameters: [Parameter] {
            switch self {
            case .colorAdjust: [
                Parameter(key: "brightness", label: "Brightness", range: -1...1, defaultValue: 0),
                Parameter(key: "contrast", label: "Contrast", range: 0.25...2, defaultValue: 1),
                Parameter(key: "saturation", label: "Saturation", range: 0...2, defaultValue: 1),
            ]
            case .exposure: [Parameter(key: "ev", label: "EV", range: -3...3, defaultValue: 0.5)]
            case .hue: [Parameter(key: "angle", label: "Degrees", range: -180...180, defaultValue: 30)]
            case .temperature: [
                Parameter(key: "temperature", label: "Temperature", range: 2000...12000, defaultValue: 6500),
                Parameter(key: "tint", label: "Tint", range: -100...100, defaultValue: 0),
            ]
            case .blur: [Parameter(key: "radius", label: "Radius", range: 0...100, defaultValue: 8)]
            case .sharpen: [Parameter(key: "sharpness", label: "Amount", range: 0...2, defaultValue: 0.6)]
            case .vignette: [
                Parameter(key: "intensity", label: "Intensity", range: 0...1, defaultValue: 0.6),
                Parameter(key: "radius", label: "Radius", range: 0.1...1.5, defaultValue: 0.8),
            ]
            case .sepia: [Parameter(key: "intensity", label: "Intensity", range: 0...1, defaultValue: 1)]
            case .mono, .invert: []
            case .posterize: [Parameter(key: "levels", label: "Levels", range: 2...30, defaultValue: 6)]
            case .dropShadow: [
                Parameter(key: "distance", label: "Distance", range: 0...200, defaultValue: 12),
                Parameter(key: "angle", label: "Angle", range: -180...180, defaultValue: 135),
                Parameter(key: "size", label: "Size", range: 0...100, defaultValue: 10),
                Parameter(key: "opacity", label: "Opacity", range: 0...1, defaultValue: 0.6),
            ]
            }
        }
    }
}
