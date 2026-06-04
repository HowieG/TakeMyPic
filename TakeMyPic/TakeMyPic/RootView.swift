import SwiftUI
import UIKit

enum CameraMode: Identifiable {
    case reference
    case match(referenceImage: UIImage, referenceAssetID: String)

    var id: String {
        switch self {
        case .reference: return "reference"
        case .match(_, let id): return "match-\(id)"
        }
    }
}

struct RootView: View {
    @StateObject private var traceStore = TraceStore()
    @State private var cameraMode: CameraMode?

    var body: some View {
        NavigationStack {
            LibraryView(traceStore: traceStore) { mode in
                cameraMode = mode
            }
        }
        .fullScreenCover(item: $cameraMode) { mode in
            CameraView(mode: mode, traceStore: traceStore) {
                cameraMode = nil
            }
        }
    }
}

#Preview {
    RootView()
}
