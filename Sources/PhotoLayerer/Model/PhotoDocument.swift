import Combine
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Everything that is saved: canvas size and layers, bottom layer first (PSD order).
struct CanvasState {
    var width: Int
    var height: Int
    var layers: [Layer]

    static func blank(width: Int = 1600, height: Int = 1200) -> CanvasState {
        let background = Bitmap(width: width, height: height)
        background.fill(CGColor(gray: 1, alpha: 1))
        return CanvasState(width: width, height: height, layers: [Layer(name: "Background", bitmap: background)])
    }

    func deepCopy() -> CanvasState {
        CanvasState(width: width, height: height, layers: layers.map { $0.deepCopy() })
    }
}

extension UTType {
    static let photoshopImage = UTType(importedAs: "com.adobe.photoshop-image")
}

/// Every edit goes through `perform` (or a begin/commit pair for drags) so it is undoable, and
/// registering the undo is also what marks the document as edited.
/// Only touched on the main thread except for `fileWrapper`, which works on a snapshot.
final class PhotoDocument: ReferenceFileDocument, @unchecked Sendable {
    static var readableContentTypes: [UTType] { [.photoshopImage, .png, .jpeg, .heic, .tiff, .image] }
    static var writableContentTypes: [UTType] { [.photoshopImage] }

    @Published var canvas: CanvasState {
        didSet { cachedComposite = nil }
    }
    @Published var selectedLayerID: UUID?
    /// A new, never-edited document; adding a photo to it replaces the blank canvas with the photo.
    private(set) var isUntouched: Bool

    private var cachedComposite: CGImage?
    private var editSnapshot: CanvasState?

    init() {
        canvas = .blank()
        isUntouched = true
        selectedLayerID = canvas.layers.last?.id
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        if configuration.contentType.conforms(to: .photoshopImage) {
            canvas = try PSDReader.read(data)
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = PhotoDocument.orientedImage(from: source)
            else { throw CocoaError(.fileReadCorruptFile) }
            canvas = CanvasState(width: image.width, height: image.height,
                                 layers: [Layer(name: "Background", bitmap: Bitmap(image: image))])
        }
        isUntouched = false
        selectedLayerID = canvas.layers.last?.id
    }

    // SwiftUI asks for the snapshot on the main thread, then writes it on a background one.
    func snapshot(contentType: UTType) throws -> CanvasState {
        canvas.deepCopy()
    }

    func fileWrapper(snapshot: CanvasState, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try PSDWriter.write(snapshot))
    }

    // MARK: - Reading

    var composite: CGImage? {
        if let cachedComposite { return cachedComposite }
        cachedComposite = Compositor.render(canvas.layers, width: canvas.width, height: canvas.height)
        return cachedComposite
    }

    var selectedIndex: Int? {
        canvas.layers.firstIndex { $0.id == selectedLayerID }
    }

    var selectedLayer: Layer? {
        selectedIndex.map { canvas.layers[$0] }
    }

    // MARK: - Undoable edits

    func perform(_ actionName: String, undoManager: UndoManager?, _ change: (inout CanvasState) -> Void) {
        let before = canvas
        change(&canvas)
        isUntouched = false
        registerUndo(restoring: before, actionName, undoManager)
    }

    /// For continuous edits (slider drags, moving a layer): snapshot once at the start, apply
    /// changes freely with `update`, then `commitEdit` registers a single undo step.
    func beginEdit() {
        if editSnapshot == nil { editSnapshot = canvas }
    }

    func update(_ change: (inout CanvasState) -> Void) {
        change(&canvas)
    }

    func commitEdit(_ actionName: String, undoManager: UndoManager?) {
        guard let before = editSnapshot else { return }
        editSnapshot = nil
        isUntouched = false
        registerUndo(restoring: before, actionName, undoManager)
    }

    private func registerUndo(restoring before: CanvasState, _ name: String, _ undoManager: UndoManager?) {
        guard let undoManager else { return }
        MainActor.assumeIsolated {
            undoManager.registerUndo(withTarget: self) { doc in
                let after = doc.canvas
                doc.canvas = before
                if doc.selectedIndex == nil { doc.selectedLayerID = before.layers.last?.id }
                doc.registerUndo(restoring: after, name, undoManager)
            }
            undoManager.setActionName(name)
        }
    }

    // MARK: - Layer operations

    func addEmptyLayer(undoManager: UndoManager?) {
        let layer = Layer(name: nextLayerName(), bitmap: Bitmap(width: canvas.width, height: canvas.height))
        insertAboveSelection(layer, "New Layer", undoManager)
    }

    /// Adds `image` as a new layer centred on the canvas. On an untouched new document the photo
    /// becomes the document instead, so "new + add photo" behaves like opening the photo.
    func addImageLayer(_ image: CGImage, name: String, undoManager: UndoManager?) {
        let bitmap = Bitmap(image: image)
        if isUntouched {
            let layer = Layer(name: name, bitmap: bitmap)
            perform("Open Photo", undoManager: undoManager) { state in
                state = CanvasState(width: bitmap.width, height: bitmap.height, layers: [layer])
            }
            selectedLayerID = layer.id
            return
        }
        let layer = Layer(name: name, bitmap: bitmap,
                          x: (canvas.width - bitmap.width) / 2, y: (canvas.height - bitmap.height) / 2)
        insertAboveSelection(layer, "Add Image Layer", undoManager)
    }

    func duplicateSelected(undoManager: UndoManager?) {
        guard let layer = selectedLayer else { return }
        var copy = layer.deepCopy(newID: true)
        copy.name = "\(layer.name) copy"
        insertAboveSelection(copy, "Duplicate Layer", undoManager)
    }

    func deleteSelected(undoManager: UndoManager?) {
        guard let index = selectedIndex, canvas.layers.count > 1 else { return }
        perform("Delete Layer", undoManager: undoManager) { $0.layers.remove(at: index) }
        selectedLayerID = canvas.layers[max(0, index - 1)].id
    }

    /// Bakes the selected layer (with its effects) into the one below it.
    func mergeDown(undoManager: UndoManager?) {
        guard let index = selectedIndex, index > 0 else { return }
        var lower = canvas.layers[index - 1]
        let upper = canvas.layers[index]
        // The lower layer's own opacity and blend mode stay as layer settings on the result.
        let lowerOpacity = lower.opacity, lowerBlend = lower.blendMode, lowerVisible = lower.isVisible
        lower.opacity = 1
        lower.blendMode = .normal
        lower.isVisible = true
        guard let merged = Compositor.render([lower, upper], width: canvas.width, height: canvas.height)
        else { return }
        var result = Layer(id: lower.id, name: lower.name, bitmap: Bitmap(image: merged))
        result.opacity = lowerOpacity
        result.blendMode = lowerBlend
        result.isVisible = lowerVisible
        perform("Merge Down", undoManager: undoManager) { state in
            state.layers.replaceSubrange(index - 1...index, with: [result])
        }
        selectedLayerID = result.id
    }

    func flatten(undoManager: UndoManager?) {
        guard canvas.layers.count > 1,
              let flat = Compositor.render(canvas.layers, width: canvas.width, height: canvas.height)
        else { return }
        let layer = Layer(name: "Background", bitmap: Bitmap(image: flat))
        perform("Flatten Image", undoManager: undoManager) { $0.layers = [layer] }
        selectedLayerID = layer.id
    }

    /// `step` +1 moves the selected layer up the stack (towards the top), -1 down.
    func moveSelected(by step: Int, undoManager: UndoManager?) {
        guard let index = selectedIndex else { return }
        let target = index + step
        guard canvas.layers.indices.contains(target) else { return }
        perform("Reorder Layers", undoManager: undoManager) { $0.layers.swapAt(index, target) }
    }

    /// Reorder from the layers list, which shows the top layer first.
    func moveLayers(fromDisplayOffsets source: IndexSet, toDisplayOffset destination: Int, undoManager: UndoManager?) {
        perform("Reorder Layers", undoManager: undoManager) { state in
            var display = Array(state.layers.reversed())
            display.move(fromOffsets: source, toOffset: destination)
            state.layers = display.reversed()
        }
    }

    func setLayer(_ id: UUID, _ actionName: String, undoManager: UndoManager?, _ change: (inout Layer) -> Void) {
        guard let index = canvas.layers.firstIndex(where: { $0.id == id }) else { return }
        perform(actionName, undoManager: undoManager) { change(&$0.layers[index]) }
    }

    func updateLayer(_ id: UUID, _ change: (inout Layer) -> Void) {
        guard let index = canvas.layers.firstIndex(where: { $0.id == id }) else { return }
        update { change(&$0.layers[index]) }
    }

    // MARK: - Painting

    /// Swaps the target layer's pixels for a private copy so the undo snapshot keeps the originals.
    func beginStroke(undoManager: UndoManager?) -> Bool {
        guard let index = selectedIndex, canvas.layers[index].isVisible else { return false }
        let fresh = canvas.layers[index].bitmap.copy()
        perform("Paint", undoManager: undoManager) { $0.layers[index].bitmap = fresh }
        return true
    }

    func paintSegment(from start: CGPoint, to end: CGPoint, color: CGColor, size: CGFloat, erase: Bool) {
        guard let layer = selectedLayer else { return }
        let ctx = layer.bitmap.context
        let height = CGFloat(layer.bitmap.height)
        // Canvas space is y-down; the bitmap context is y-up.
        func local(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - CGFloat(layer.x), y: height - (p.y - CGFloat(layer.y)))
        }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(size)
        ctx.setBlendMode(erase ? .clear : .normal)
        ctx.setStrokeColor(color)
        ctx.move(to: local(start))
        ctx.addLine(to: local(end))
        ctx.strokePath()
        ctx.restoreGState()
        layer.bitmap.didChange()
        cachedComposite = nil
        objectWillChange.send()
    }

    // MARK: - Helpers

    private func insertAboveSelection(_ layer: Layer, _ actionName: String, _ undoManager: UndoManager?) {
        let index = selectedIndex.map { $0 + 1 } ?? canvas.layers.count
        perform(actionName, undoManager: undoManager) { $0.layers.insert(layer, at: index) }
        selectedLayerID = layer.id
    }

    private func nextLayerName() -> String {
        let used = Set(canvas.layers.map(\.name))
        var n = canvas.layers.count
        while used.contains("Layer \(n)") { n += 1 }
        return "Layer \(n)"
    }

    /// First image in the source, rotated upright per its EXIF orientation.
    static func orientedImage(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 20_000,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
