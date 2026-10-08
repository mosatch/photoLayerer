import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Builds the composite image from layers with Core Image. Layers are listed bottom-first.
enum Compositor {
    static let context = CIContext(options: [
        .workingColorSpace: Bitmap.colorSpace,
        .outputColorSpace: Bitmap.colorSpace,
    ])

    static func composite(_ layers: [Layer], width: Int, height: Int, background: CGColor? = nil) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        var result = background.map { CIImage(color: CIColor(cgColor: $0)).cropped(to: canvas) }
            ?? CIImage.empty()
        for layer in layers where layer.isVisible && layer.opacity > 0 {
            let top = rendered(layer, canvasHeight: height)
            let blend = CIFilter(name: layer.blendMode.ciFilterName)!
            blend.setValue(top, forKey: kCIInputImageKey)
            blend.setValue(result, forKey: kCIInputBackgroundImageKey)
            result = blend.outputImage ?? result
        }
        return result.cropped(to: canvas)
    }

    static func render(_ layers: [Layer], width: Int, height: Int, background: CGColor? = nil) -> CGImage? {
        let image = composite(layers, width: width, height: height, background: background)
        return context.createCGImage(
            image, from: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: Bitmap.colorSpace)
    }

    /// One layer placed on the canvas (Core Image's y-up space) with its effects and opacity applied.
    static func rendered(_ layer: Layer, canvasHeight: Int) -> CIImage {
        let flippedY = CGFloat(canvasHeight - layer.y - layer.bitmap.height)
        var image = CIImage(cgImage: layer.bitmap.image)
            .transformed(by: CGAffineTransform(translationX: CGFloat(layer.x), y: flippedY))
        let extent = image.extent
        for effect in layer.effects where effect.isEnabled {
            image = apply(effect, to: image, layerExtent: extent)
        }
        if layer.opacity < 1 {
            let fade = CIFilter.colorMatrix()
            fade.inputImage = image
            fade.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.opacity))
            image = fade.outputImage ?? image
        }
        return image
    }

    static func apply(_ effect: LayerEffect, to image: CIImage, layerExtent: CGRect) -> CIImage {
        let v = { (key: String) in Float(effect.value(key)) }
        let output: CIImage?
        switch effect.kind {
        case .colorAdjust:
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.brightness = v("brightness")
            f.contrast = v("contrast")
            f.saturation = v("saturation")
            output = f.outputImage
        case .exposure:
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = v("ev")
            output = f.outputImage
        case .hue:
            let f = CIFilter.hueAdjust()
            f.inputImage = image
            f.angle = v("angle") * .pi / 180
            output = f.outputImage
        case .temperature:
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: CGFloat(v("temperature")), y: CGFloat(v("tint")))
            output = f.outputImage
        case .blur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = image
            f.radius = v("radius")
            output = f.outputImage
        case .sharpen:
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = v("sharpness")
            output = f.outputImage
        case .vignette:
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            f.center = CGPoint(x: layerExtent.midX, y: layerExtent.midY)
            f.radius = v("radius") * Float(hypot(layerExtent.width, layerExtent.height)) / 2
            f.intensity = v("intensity")
            f.falloff = 0.5
            output = f.outputImage?.cropped(to: image.extent)
        case .sepia:
            let f = CIFilter.sepiaTone()
            f.inputImage = image
            f.intensity = v("intensity")
            output = f.outputImage
        case .mono:
            let f = CIFilter.photoEffectMono()
            f.inputImage = image
            output = f.outputImage
        case .invert:
            let f = CIFilter.colorInvert()
            f.inputImage = image
            output = f.outputImage
        case .posterize:
            let f = CIFilter.colorPosterize()
            f.inputImage = image
            f.levels = v("levels")
            output = f.outputImage
        case .dropShadow:
            output = dropShadow(under: image, effect: effect)
        }
        return output ?? image
    }

    private static func dropShadow(under image: CIImage, effect: LayerEffect) -> CIImage {
        // Black silhouette from the alpha channel, softened and offset, then the layer on top.
        let silhouette = CIFilter.colorMatrix()
        silhouette.inputImage = image
        silhouette.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        silhouette.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        silhouette.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        silhouette.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(effect.value("opacity")))
        var shadow = silhouette.outputImage ?? image
        let size = effect.value("size")
        if size > 0 {
            shadow = shadow.applyingGaussianBlur(sigma: size / 2)
        }
        // Photoshop's angle is the direction the light comes from; the shadow falls opposite.
        let radians = effect.value("angle") * .pi / 180
        let distance = effect.value("distance")
        shadow = shadow.transformed(by: CGAffineTransform(
            translationX: -cos(radians) * distance, y: -sin(radians) * distance))
        return image.composited(over: shadow)
    }
}
