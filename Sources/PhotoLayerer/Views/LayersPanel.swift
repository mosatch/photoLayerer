import SwiftUI

/// The layer stack, top layer first, with the add/duplicate/merge/delete bar underneath.
struct LayersPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var document: PhotoDocument

    init(model: EditorModel) {
        self.model = model
        document = model.document
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $document.selectedLayerID) {
                ForEach(document.canvas.layers.reversed()) { layer in
                    LayerRow(layer: layer, model: model)
                        .tag(layer.id)
                }
                .onMove { source, destination in
                    document.moveLayers(fromDisplayOffsets: source, toDisplayOffset: destination,
                                        undoManager: model.undoManager)
                }
            }
            .listStyle(.inset)
            Divider()
            HStack(spacing: 2) {
                Menu {
                    Button("New Empty Layer", action: model.addEmptyLayer)
                    Button("Image from File…", action: model.importImageFile)
                    Button("Photo from Library…") { model.showingPhotoPicker = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a layer")
                barButton("plus.square.on.square", "Duplicate layer", action: model.duplicateLayer)
                barButton("arrow.up", "Move layer up") { model.moveLayer(by: 1) }
                    .disabled(document.selectedIndex == document.canvas.layers.count - 1)
                barButton("arrow.down", "Move layer down") { model.moveLayer(by: -1) }
                    .disabled(document.selectedIndex == 0)
                barButton("square.stack.3d.down.right", "Merge down", action: model.mergeDown)
                    .disabled((document.selectedIndex ?? 0) == 0)
                Spacer()
                barButton("trash", "Delete layer", action: model.deleteLayer)
                    .disabled(document.canvas.layers.count < 2)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func barButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 18) }
            .help(help)
    }
}

private struct LayerRow: View {
    let layer: Layer
    @ObservedObject var model: EditorModel
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.document.setLayer(layer.id, layer.isVisible ? "Hide Layer" : "Show Layer",
                                        undoManager: model.undoManager) { $0.isVisible.toggle() }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)

            Checkerboard()
                .overlay { Image(decorative: layer.bitmap.image, scale: 1).resizable().scaledToFit() }
                .frame(width: 40, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))

            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { if !nameFocused { commitName() } }
                if !layer.effects.isEmpty || layer.blendMode != .normal || layer.opacity < 1 {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear { draftName = layer.name }
        .onChange(of: layer.name) { draftName = layer.name }
    }

    private var summary: String {
        var parts: [String] = []
        if layer.blendMode != .normal { parts.append(layer.blendMode.displayName) }
        if layer.opacity < 1 { parts.append("\(Int((layer.opacity * 100).rounded()))%") }
        if !layer.effects.isEmpty { parts.append(layer.effects.count == 1 ? "1 effect" : "\(layer.effects.count) effects") }
        return parts.joined(separator: " · ")
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { draftName = layer.name; return }
        guard trimmed != layer.name else { return }
        model.document.setLayer(layer.id, "Rename Layer", undoManager: model.undoManager) { $0.name = trimmed }
    }
}
