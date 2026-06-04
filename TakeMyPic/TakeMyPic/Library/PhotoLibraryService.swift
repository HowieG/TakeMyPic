import Photos
import UIKit

enum PhotoLibraryService {
    static func requestAddAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cont.resume(returning: status)
            }
        }
    }

    static func requestReadWriteAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
    }

    static func saveJPEG(_ data: Data) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
                placeholder = req.placeholderForCreatedAsset
            } completionHandler: { success, error in
                if let error {
                    cont.resume(throwing: error)
                } else if success, let id = placeholder?.localIdentifier {
                    cont.resume(returning: id)
                } else {
                    cont.resume(throwing: NSError(
                        domain: "PhotoLibraryService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to save photo."]
                    ))
                }
            }
        }
    }

    static func fetchAssets(identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        let order = Dictionary(uniqueKeysWithValues: identifiers.enumerated().map { ($1, $0) })
        return assets.sorted { (order[$0.localIdentifier] ?? 0) > (order[$1.localIdentifier] ?? 0) }
    }

    static func deleteAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
            } completionHandler: { success, error in
                if let error {
                    cont.resume(throwing: error)
                } else if success {
                    cont.resume(returning: ())
                } else {
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    }

    static func loadImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .exact
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .default,
                options: opts
            ) { image, _ in
                cont.resume(returning: image)
            }
        }
    }
}
