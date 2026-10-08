import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable {
    case move, brush, eraser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .move: "Move"
        case .brush: "Brush"
        case .eraser: "Eraser"
        }
    }

    var symbol: String {
        switch self {
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .move: "1"
        case .brush: "2"
        case .eraser: "3"
        }
    }
}

/// Per-window editing state, also published to the menu bar via `focusedSceneObject`.
@MainActor
final class EditorModel: ObservableObject {
    let document: PhotoDocument
    var undoManager: UndoManager?

    @Published var tool: Tool = .brush
    @Published var brushColor = Color(red: 0.95, green: 0.55, blue: 0.2)
    @Published var brushSize: Double = 24
    @Published var zoom: CGFloat = 1
    /// Bumped to ask the canvas to zoom to fit its window.
    @Published var fitRequest = 0
    @Published var showingPhotoPicker = false
    @Published var errorMessage: String?

    init(document: PhotoDocument) {
        self.document = document
    }

    func addEmptyLayer() { document.addEmptyLayer(undoManager: undoManager) }
    func duplicateLayer() { document.duplicateSelected(undoManager: undoManager) }
    func deleteLayer() { document.deleteSelected(undoManager: undoManager) }
    func mergeDown() { document.mergeDown(undoManager: undoManager) }
    func flatten() { document.flatten(undoManager: undoManager) }
    func moveLayer(by step: Int) { document.moveSelected(by: step, undoManager: undoManager) }

    func addPhoto(_ image: CGImage, name: String) {
        let replacesCanvas = document.isUntouched
        document.addImageLayer(image, name: name, undoManager: undoManager)
        if replacesCanvas { fitRequest += 1 }
    }

    func importImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to add as layers"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = PhotoDocument.orientedImage(from: source)
            else {
                errorMessage = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            addPhoto(image, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    func export(as type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "Untitled.\(type.preferredFilenameExtension ?? "png")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let canvas = document.canvas
        // JPEG has no transparency, so flatten onto white rather than let it turn black.
        let background = type == .jpeg ? CGColor(gray: 1, alpha: 1) : nil
        guard let image = Compositor.render(canvas.layers, width: canvas.width, height: canvas.height,
                                            background: background),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else {
            errorMessage = "Couldn't export the image."
            return
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            errorMessage = "Couldn't write \(url.lastPathComponent)."
        }
    }
}
