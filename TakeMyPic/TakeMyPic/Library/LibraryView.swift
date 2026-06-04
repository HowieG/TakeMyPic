import SwiftUI
import Photos

struct LibraryView: View {
    @ObservedObject var traceStore: TraceStore
    let onPick: (CameraMode) -> Void

    @State private var assets: [PHAsset] = []
    @State private var isLoadingSelection = false
    @State private var showCleanupAlert = false
    @State private var authorizationDenied = false

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                actions
                if authorizationDenied {
                    authorizationDeniedNote
                }
                if assets.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("TakeMyPic")
        .toolbar {
            if !assets.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showCleanupAlert = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .task { await refresh() }
        .onChange(of: traceStore.identifiers) { _, _ in
            Task { await refresh() }
        }
        .alert("Clean up trace photos?", isPresented: $showCleanupAlert) {
            Button("Delete \(assets.count)", role: .destructive) {
                Task { await cleanup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every photo you've taken in reference mode from your camera roll. Photos taken in match mode are not touched.")
        }
        .overlay {
            if isLoadingSelection {
                ProgressView()
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Frame the shot, then trace it.")
                .font(.title3.weight(.semibold))
            Text("Take a reference, hand off the phone, line it up.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }

    private var actions: some View {
        Button {
            onPick(.reference)
        } label: {
            Label("Take new reference", systemImage: "camera.viewfinder")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No references yet")
                .font(.headline)
            Text("Take a reference photo to use as a tracing underlay for your next shot.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 32)
    }

    private var authorizationDeniedNote: some View {
        VStack(spacing: 8) {
            Text("Photo library access denied")
                .font(.headline)
            Text("Open Settings → TakeMyPic → Photos to grant access.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap a reference to match against it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    TraceThumbnail(asset: asset) {
                        Task { await select(asset: asset) }
                    }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func refresh() async {
        let status = await PhotoLibraryService.requestReadWriteAuthorization()
        switch status {
        case .authorized, .limited:
            authorizationDenied = false
        case .denied, .restricted:
            authorizationDenied = true
            assets = []
            return
        case .notDetermined:
            authorizationDenied = false
            return
        @unknown default:
            authorizationDenied = false
        }

        let fetched = PhotoLibraryService.fetchAssets(identifiers: traceStore.identifiers)
        let validIDs = Set(fetched.map(\.localIdentifier))
        let pruned = traceStore.identifiers.filter { validIDs.contains($0) }
        if pruned.count != traceStore.identifiers.count {
            traceStore.setIdentifiers(pruned)
        }
        assets = fetched
    }

    private func select(asset: PHAsset) async {
        isLoadingSelection = true
        defer { isLoadingSelection = false }
        guard let image = await PhotoLibraryService.loadImage(for: asset) else { return }
        onPick(.match(referenceImage: image, referenceAssetID: asset.localIdentifier))
    }

    private func cleanup() async {
        do {
            try await PhotoLibraryService.deleteAssets(assets)
            traceStore.clear()
            assets = []
        } catch {
            await refresh()
        }
    }
}

private struct TraceThumbnail: View {
    let asset: PHAsset
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Color.gray.opacity(0.15)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        let scale = UIScreen.main.scale
        let size = CGSize(width: 130 * scale, height: 130 * scale)
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: size,
            contentMode: .aspectFill,
            options: opts
        ) { img, _ in
            guard let img else { return }
            Task { @MainActor in self.image = img }
        }
    }
}
