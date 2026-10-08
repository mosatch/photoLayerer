import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.undoManager) private var undoManager
    @State private var showingInspector = true

    init(document: PhotoDocument) {
        _model = StateObject(wrappedValue: EditorModel(document: document))
    }

    var body: some View {
        CanvasView(model: model)
            .frame(minWidth: 500, minHeight: 400)
            .inspector(isPresented: $showingInspector) {
                VSplitView {
                    LayersPanel(model: model)
                        .frame(minHeight: 160, idealHeight: 260)
                    LayerInspector(model: model)
                        .frame(minHeight: 200)
                }
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .toolbar { toolbar }
            .sheet(isPresented: $model.showingPhotoPicker) {
                PhotoPickerView { image, name in model.addPhoto(image, name: name) }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .focusedSceneObject(model)
            .onAppear { model.undoManager = undoManager }
            .onChange(of: undoManager) { model.undoManager = undoManager }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Tool", selection: $model.tool) {
                ForEach(Tool.allCases) { tool in
                    Label(tool.label, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Move (⌘1), Brush (⌘2), Eraser (⌘3)")
        }
        ToolbarItem {
            ColorPicker("Brush Colour", selection: $model.brushColor, supportsOpacity: true)
                .labelsHidden()
                .help("Brush colour")
        }
        ToolbarItem {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill").font(.system(size: 6))
                Slider(value: $model.brushSize, in: 1...300)
                    .frame(width: 110)
                Image(systemName: "circle.fill").font(.system(size: 13))
                Text("\(Int(model.brushSize)) px").monospacedDigit().frame(width: 48, alignment: .leading)
            }
            .help("Brush size")
        }
        ToolbarItem {
            Button { model.showingPhotoPicker = true } label: {
                Label("Add from Photos", systemImage: "photo.on.rectangle.angled")
            }
            .help("Add a photo from your library as a layer")
        }
        ToolbarItem {
            Menu {
                Button("Zoom to Fit") { model.fitRequest += 1 }
                Button("Actual Size") { model.zoom = 1 }
                Button("Zoom In") { model.zoom = min(32, model.zoom * 1.25) }
                Button("Zoom Out") { model.zoom = max(0.05, model.zoom / 1.25) }
            } label: {
                Text("\(Int((model.zoom * 100).rounded()))%").monospacedDigit()
            }
            .help("Zoom")
        }
        ToolbarItem {
            Button { showingInspector.toggle() } label: {
                Label("Layers", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the layers panel")
        }
    }
}

/// Menu bar commands that act on the frontmost editor window.
struct EditorCommands: Commands {
    @FocusedObject private var model: EditorModel?

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export as PNG…") { model?.export(as: .png) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Export as JPEG…") { model?.export(as: .jpeg) }
                .disabled(model == nil)
        }
        CommandMenu("Layer") {
            Button("New Layer") { model?.addEmptyLayer() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Add Image from File…") { model?.importImageFile() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Add Photo from Library…") { model?.showingPhotoPicker = true }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Duplicate Layer") { model?.duplicateLayer() }
                .keyboardShortcut("j", modifiers: .command)
            Button("Delete Layer") { model?.deleteLayer() }
            Divider()
            Button("Bring Forward") { model?.moveLayer(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Send Backward") { model?.moveLayer(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
            Divider()
            Button("Merge Down") { model?.mergeDown() }
                .keyboardShortcut("e", modifiers: .command)
            Button("Flatten Image") { model?.flatten() }
        }
        CommandMenu("Tools") {
            ForEach(Tool.allCases) { tool in
                // Command-digit rather than bare letters, which would steal keystrokes from text fields.
                Button(tool.label) { model?.tool = tool }
                    .keyboardShortcut(tool.shortcut, modifiers: .command)
            }
        }
    }
}
