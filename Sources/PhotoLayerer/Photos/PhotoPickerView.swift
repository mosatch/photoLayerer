import Photos
import SwiftUI

/// Sheet listing the Photos library; double-click (or Add) hands the chosen image back.
struct PhotoPickerView: View {
    let onPick: (CGImage, String) -> Void

    @StateObject private var library = PhotoLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).lineLimit(1)
                } else if library.canRead {
                    Text("\(library.assets.count) photos").foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { pickSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || isLoading)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            await library.requestAccess()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch library.status {
        case .authorized, .limited:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(library.assets, id: \.localIdentifier) { asset in
                        PhotoThumbnail(asset: asset, isSelected: selection == asset.localIdentifier)
                            .onTapGesture(count: 2) {
                                selection = asset.localIdentifier
                                pickSelected()
                            }
                            .simultaneousGesture(TapGesture().onEnded { selection = asset.localIdentifier })
                    }
                }
                .padding(8)
            }
        case .notDetermined:
            ProgressView("Asking for access to Photos…")
        default:
            ContentUnavailableView {
                Label("No Access to Photos", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("Allow PhotoLayerer under Privacy & Security › Photos in System Settings.")
            } actions: {
                Button("Open System Settings") { PhotoLibrary.openPrivacySettings() }
            }
        }
    }

    private func pickSelected() {
        guard let id = selection, let asset = library.assets.first(where: { $0.localIdentifier == id }) else { return }
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let image = try await library.fullImage(for: asset)
                let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Photo"
                onPick(image, (name as NSString).deletingPathExtension)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PhotoThumbnail: View {
    let asset: PHAsset
    let isSelected: Bool
    @State private var image: NSImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) {
                image = await PhotoLibrary.shared.thumbnail(for: asset, side: 320)
            }
    }
}
