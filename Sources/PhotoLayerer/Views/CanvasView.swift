import SwiftUI

struct CanvasView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var document: PhotoDocument

    @State private var lastPoint: CGPoint?
    @State private var moveOrigin: (x: Int, y: Int)?
    @State private var zoomAtGestureStart: CGFloat?

    init(model: EditorModel) {
        self.model = model
        document = model.document
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                canvas
                    .padding(40)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .gesture(MagnifyGesture()
                .onChanged { value in
                    let start = zoomAtGestureStart ?? model.zoom
                    zoomAtGestureStart = start
                    model.zoom = min(32, max(0.05, start * value.magnification))
                }
                .onEnded { _ in zoomAtGestureStart = nil })
            .onAppear { fit(in: geo.size) }
            .onChange(of: model.fitRequest) { fit(in: geo.size) }
        }
    }

    private var canvasSize: CGSize {
        CGSize(width: CGFloat(document.canvas.width) * model.zoom,
               height: CGFloat(document.canvas.height) * model.zoom)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Checkerboard()
            if let image = document.composite {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(model.zoom >= 2 ? .none : .high)
            }
            if model.tool == .move, let layer = document.selectedLayer {
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: layer.frame.width * model.zoom, height: layer.frame.height * model.zoom)
                    .offset(x: layer.frame.minX * model.zoom, y: layer.frame.minY * model.zoom)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipped()
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged(dragChanged).onEnded(dragEnded))
        .onContinuousHover { phase in
            switch phase {
            case .active: (model.tool == .move ? NSCursor.openHand : NSCursor.crosshair).set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }

    private func canvasPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x / model.zoom, y: location.y / model.zoom)
    }

    private func dragChanged(_ value: DragGesture.Value) {
        switch model.tool {
        case .move:
            guard let layer = document.selectedLayer else { return }
            if moveOrigin == nil {
                moveOrigin = (layer.x, layer.y)
                document.beginEdit()
            }
            guard let origin = moveOrigin else { return }
            let dx = Int((value.translation.width / model.zoom).rounded())
            let dy = Int((value.translation.height / model.zoom).rounded())
            document.updateLayer(layer.id) { $0.x = origin.x + dx; $0.y = origin.y + dy }
        case .brush, .eraser:
            let point = canvasPoint(value.location)
            if lastPoint == nil {
                guard document.beginStroke(undoManager: model.undoManager) else { return }
                lastPoint = point
            }
            guard let from = lastPoint else { return }
            document.paintSegment(from: from, to: point, color: NSColor(model.brushColor).cgColor,
                                  size: model.brushSize, erase: model.tool == .eraser)
            lastPoint = point
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        if moveOrigin != nil {
            document.commitEdit("Move Layer", undoManager: model.undoManager)
        }
        moveOrigin = nil
        lastPoint = nil
    }

    private func fit(in size: CGSize) {
        let available = CGSize(width: max(100, size.width - 80), height: max(100, size.height - 80))
        let scale = min(available.width / CGFloat(document.canvas.width),
                        available.height / CGFloat(document.canvas.height))
        model.zoom = min(1, scale)
    }
}

/// Grey-and-white squares behind transparent pixels, drawn as one repeating tile.
struct Checkerboard: View {
    private static let tile: CGImage = {
        let bitmap = Bitmap(width: 16, height: 16)
        bitmap.fill(CGColor(gray: 1, alpha: 1))
        bitmap.context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        bitmap.context.fill([CGRect(x: 0, y: 0, width: 8, height: 8), CGRect(x: 8, y: 8, width: 8, height: 8)])
        return bitmap.image
    }()

    var body: some View {
        Rectangle().fill(ImagePaint(image: Image(decorative: Self.tile, scale: 1)))
    }
}
