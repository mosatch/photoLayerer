import SwiftUI

/// Opacity, blend mode and the effect stack for the selected layer.
struct LayerInspector: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var document: PhotoDocument

    init(model: EditorModel) {
        self.model = model
        document = model.document
    }

    var body: some View {
        if let layer = document.selectedLayer {
            Form {
                Section("Layer") {
                    Picker("Blend", selection: blendBinding(layer)) {
                        ForEach(Array(BlendMode.groups.enumerated()), id: \.offset) { index, group in
                            if index > 0 { Divider() }
                            ForEach(group) { Text($0.displayName).tag($0) }
                        }
                    }
                    EditSlider(label: "Opacity", value: layerBinding(layer.id, \.opacity), range: 0...1,
                               format: { "\(Int(($0 * 100).rounded()))%" }) { editing in
                        endEdit(editing, "Change Opacity")
                    }
                    LabeledContent("Position", value: "\(layer.x), \(layer.y)")
                    LabeledContent("Size", value: "\(layer.bitmap.width) × \(layer.bitmap.height)")
                }

                Section {
                    if layer.effects.isEmpty {
                        Text("No effects. Effects are non-destructive and saved with the PSD.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(layer.effects) { effect in
                        EffectEditor(effect: effect, layerID: layer.id, model: model)
                    }
                } header: {
                    HStack {
                        Text("Effects")
                        Spacer()
                        Menu {
                            ForEach(LayerEffect.Kind.allCases) { kind in
                                Button(kind.displayName) { addEffect(kind, to: layer.id) }
                            }
                        } label: {
                            Label("Add Effect", systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Layer Selected", systemImage: "square.3.layers.3d")
        }
    }

    private func blendBinding(_ layer: Layer) -> Binding<BlendMode> {
        Binding(
            get: { layer.blendMode },
            set: { mode in
                document.setLayer(layer.id, "Change Blend Mode", undoManager: model.undoManager) { $0.blendMode = mode }
            })
    }

    private func layerBinding(_ id: UUID, _ keyPath: WritableKeyPath<Layer, Double>) -> Binding<Double> {
        Binding(
            get: { document.canvas.layers.first { $0.id == id }?[keyPath: keyPath] ?? 0 },
            set: { value in document.updateLayer(id) { $0[keyPath: keyPath] = value } })
    }

    private func endEdit(_ editing: Bool, _ name: String) {
        if editing { document.beginEdit() } else { document.commitEdit(name, undoManager: model.undoManager) }
    }

    private func addEffect(_ kind: LayerEffect.Kind, to id: UUID) {
        document.setLayer(id, "Add \(kind.displayName)", undoManager: model.undoManager) {
            $0.effects.append(LayerEffect(kind: kind))
        }
    }
}

private struct EffectEditor: View {
    let effect: LayerEffect
    let layerID: UUID
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(
                    get: { effect.isEnabled },
                    set: { on in change(on ? "Enable Effect" : "Disable Effect") { $0.isEnabled = on } })
                ) {
                    Text(effect.kind.displayName).fontWeight(.medium)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button {
                    model.document.setLayer(layerID, "Remove Effect", undoManager: model.undoManager) {
                        $0.effects.removeAll { $0.id == effect.id }
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove effect")
            }
            ForEach(effect.kind.parameters, id: \.key) { parameter in
                EditSlider(label: parameter.label, value: valueBinding(parameter.key), range: parameter.range,
                           format: { format($0, for: parameter) }) { editing in
                    if editing {
                        model.document.beginEdit()
                    } else {
                        model.document.commitEdit("Change \(effect.kind.displayName)", undoManager: model.undoManager)
                    }
                }
                .disabled(!effect.isEnabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func valueBinding(_ key: String) -> Binding<Double> {
        Binding(
            get: { effect.value(key) },
            set: { value in
                model.document.updateLayer(layerID) { layer in
                    guard let i = layer.effects.firstIndex(where: { $0.id == effect.id }) else { return }
                    layer.effects[i].values[key] = value
                }
            })
    }

    private func change(_ name: String, _ body: @escaping (inout LayerEffect) -> Void) {
        model.document.setLayer(layerID, name, undoManager: model.undoManager) { layer in
            guard let i = layer.effects.firstIndex(where: { $0.id == effect.id }) else { return }
            body(&layer.effects[i])
        }
    }

    private func format(_ value: Double, for parameter: LayerEffect.Parameter) -> String {
        let span = parameter.range.upperBound - parameter.range.lowerBound
        return span >= 20 ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }
}

/// A slider with its value printed beside it, reporting drag start/end so callers can group undo.
struct EditSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        LabeledContent(label) {
            HStack {
                Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}
