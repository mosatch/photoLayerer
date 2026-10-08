import AppKit
import Combine
import ImageIO
import Photos

/// Read access to the user's Photos library.
@MainActor
final class PhotoLibrary: ObservableObject {
    static let shared = PhotoLibrary()

    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [PHAsset] = []

    private let imageManager = PHCachingImageManager()

    var canRead: Bool { status == .authorized || status == .limited }

    /// Shows the system prompt the first time; afterwards returns the stored decision.
    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if canRead { loadAssets() }
    }

    func loadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var fetched: [PHAsset] = []
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in fetched.append(asset) }
        assets = fetched
    }

    func thumbnail(for asset: PHAsset, side: CGFloat) async -> NSImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            var resumed = false
            imageManager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                      contentMode: .aspectFill, options: options) { image, info in
                // Opportunistic delivery can call back twice; take the final (non-degraded) image.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, !degraded || image == nil else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// The full-resolution original, upright.
    func fullImage(for asset: PHAsset) async throws -> CGImage {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.version = .current
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    let error = info?[PHImageErrorKey] as? Error ?? CocoaError(.fileReadUnknown)
                    continuation.resume(throwing: error)
                }
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = PhotoDocument.orientedImage(from: source)
        else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }
}
