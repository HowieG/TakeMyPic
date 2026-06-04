import SwiftUI
import AVFoundation
import UIKit

struct CameraView: View {
    @ObservedObject var traceStore: TraceStore
    let onClose: () -> Void

    @State private var mode: CameraMode
    @StateObject private var controller = CameraController()
    @StateObject private var motion = MotionService()

    // Live controls
    @State private var overlayOpacity: Double = 0.55
    @State private var pinchStartZoom: CGFloat?

    // Capture state
    @State private var isCapturing = false
    @State private var isSaving = false
    @State private var capturedImage: UIImage?
    @State private var capturedData: Data?
    @State private var capturedRoll: Double?
    @State private var revealFraction: Double = 0.0

    // Misc
    @State private var errorMessage: String?
    @State private var didCelebrate = false

    // MARK: - Tunables (the green border threshold lives here too)

    /// Score above this turns the border green and triggers a haptic.
    /// Raise to make "matched" harder, lower to make it easier.
    private let greenThreshold: Double = 0.85

    init(mode: CameraMode, traceStore: TraceStore, onClose: @escaping () -> Void) {
        self.traceStore = traceStore
        self.onClose = onClose
        self._mode = State(initialValue: mode)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let previewHeight = width * 4.0 / 3.0
            let topSpace = max(60, (geo.size.height - previewHeight) * 0.35)

            VStack(spacing: 0) {
                topChrome
                    .frame(height: topSpace)
                previewArea(width: width, height: previewHeight)
                bottomChrome(screenWidth: width)
                    .frame(maxHeight: .infinity)
            }
            .background(Color.black)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            await prepare()
            controller.start()
            motion.start()
        }
        .onDisappear {
            controller.stop()
            motion.stop()
        }
        .onChange(of: controller.matchScore) { _, newScore in
            if Double(newScore) >= greenThreshold && !didCelebrate {
                didCelebrate = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else if Double(newScore) < greenThreshold - 0.15 {
                didCelebrate = false
            }
        }
        .alert("Camera error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        ), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    // MARK: - Preview region

    @ViewBuilder
    private func previewArea(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black
            if let capturedImage {
                photoPreviewLayer(captured: capturedImage)
            } else {
                liveCameraLayer
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private var liveCameraLayer: some View {
        ZStack {
            CameraPreview(session: controller.session)

            if case .match(let image, _) = mode {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .mask { DiamondBorderMask() }
                    .opacity(overlayOpacity)
                    .allowsHitTesting(false)

                TiltIndicator(
                    currentRoll: motion.roll,
                    targetRoll: targetRoll
                )
                .allowsHitTesting(false)

                MatchBorder(score: controller.matchScore, greenThreshold: greenThreshold)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(pinchGesture)
    }

    @ViewBuilder
    private func photoPreviewLayer(captured: UIImage) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Image(uiImage: captured)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                if case .match(let reference, _) = mode, revealFraction > 0 {
                    Image(uiImage: reference)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: geo.size.width * revealFraction)
                        }

                    if revealFraction < 1 {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 1.5, height: geo.size.height)
                            .offset(x: geo.size.width * revealFraction - 0.75)
                            .shadow(color: Color.black.opacity(0.4), radius: 1)
                    }
                }
            }
        }
    }

    private var targetRoll: Double {
        if case .match(_, let id) = mode {
            return traceStore.roll(for: id) ?? 0
        }
        return 0
    }

    // MARK: - Top chrome

    private var topChrome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                Button(action: handleClose) {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.18), in: Circle())
                }
                Spacer()
                Text(modeLabel)
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.18), in: Capsule())
                Spacer()
                if showsScore {
                    Text("\(Int(controller.matchScore * 100))%")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 56)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.18), in: Capsule())
                } else {
                    Color.clear.frame(width: 56, height: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var showsScore: Bool {
        capturedImage == nil && mode.isMatch
    }

    private var modeLabel: String {
        if capturedImage != nil { return "REVIEW" }
        switch mode {
        case .reference: return "REFERENCE"
        case .match: return "MATCH"
        }
    }

    // MARK: - Bottom chrome

    private func bottomChrome(screenWidth: CGFloat) -> some View {
        let sliderWidth = screenWidth * 0.6

        return VStack(spacing: 14) {
            if capturedImage == nil {
                if case .match = mode {
                    sliderRow(
                        label: "Transparency",
                        value: $overlayOpacity,
                        range: 0.1...0.9
                    )
                    .frame(width: sliderWidth)
                }
                zoomRow
                shutterRow
            } else {
                if case .match = mode {
                    sliderRow(
                        label: "Original",
                        value: $revealFraction,
                        range: 0.0...1.0
                    )
                    .frame(width: sliderWidth)
                }
                photoActions
                    .padding(.horizontal, 16)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity)
    }

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            SlimSlider(value: value, range: range)
        }
    }

    private var zoomRow: some View {
        HStack(spacing: 10) {
            ForEach(controller.zoomPresets, id: \.self) { preset in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    controller.setDisplayZoom(preset)
                } label: {
                    Text(zoomLabel(preset))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isCurrentPreset(preset) ? Color.yellow : .white)
                        .frame(width: 44, height: 32)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func isCurrentPreset(_ p: CGFloat) -> Bool {
        abs(controller.displayZoom - p) < 0.05
    }

    private func zoomLabel(_ preset: CGFloat) -> String {
        if isCurrentPreset(preset) {
            let v = controller.displayZoom
            if v.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(v))x"
            }
            return String(format: "%.1fx", Double(v))
        }
        if preset.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(preset))x"
        }
        return String(format: "%.1fx", Double(preset))
    }

    private var shutterRow: some View {
        Button {
            Task { await shoot() }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle()
                    .fill(isCapturing ? Color.white.opacity(0.5) : Color.white)
                    .frame(width: 64, height: 64)
            }
        }
        .disabled(isCapturing)
    }

    private var photoActions: some View {
        HStack(spacing: 18) {
            Button {
                capturedImage = nil
                capturedData = nil
                capturedRoll = nil
                revealFraction = 0
            } label: {
                Text("Retake")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
            .disabled(isSaving)
            Button {
                Task { await keep() }
            } label: {
                Text(isSaving ? "Saving…" : "Save")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white, in: Capsule())
            }
            .disabled(isSaving)
        }
    }

    // MARK: - Gestures

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartZoom == nil {
                    pinchStartZoom = controller.displayZoom
                }
                let start = pinchStartZoom ?? 1.0
                let target = start * value.magnification
                let clamped = max(controller.minDisplayZoom, min(controller.maxDisplayZoom, target))
                controller.setDisplayZoom(clamped)
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }

    // MARK: - Actions

    private func handleClose() {
        if capturedImage != nil {
            capturedImage = nil
            capturedData = nil
            capturedRoll = nil
            revealFraction = 0
            return
        }
        onClose()
    }

    private func prepare() async {
        _ = await PhotoLibraryService.requestAddAuthorization()
        switch mode {
        case .reference:
            controller.setReference(nil)
        case .match(let image, let id):
            controller.setReference(image)
            controller.setInitialDisplayZoom(CGFloat(traceStore.zoom(for: id)))
        }
    }

    private func shoot() async {
        guard !isCapturing else { return }
        isCapturing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        defer { isCapturing = false }
        do {
            let data = try await capturePhotoData()
            guard let image = UIImage(data: data) else {
                errorMessage = "Could not decode photo."
                return
            }
            capturedData = data
            capturedImage = image
            capturedRoll = motion.roll
            revealFraction = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func keep() async {
        guard let data = capturedData, let image = capturedImage else { return }
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let id = try await PhotoLibraryService.saveJPEG(data)
            if case .reference = mode {
                let meta = TraceMetadata(
                    zoom: Double(controller.displayZoom),
                    roll: capturedRoll
                )
                traceStore.add(id, metadata: meta)
                mode = .match(referenceImage: image, referenceAssetID: id)
                capturedImage = nil
                capturedData = nil
                capturedRoll = nil
                revealFraction = 0
                overlayOpacity = 0.55
                controller.setReference(image)
            } else {
                onClose()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func capturePhotoData() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            controller.capturePhoto { result in
                switch result {
                case .success(let data): cont.resume(returning: data)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }
    }
}

private extension CameraMode {
    var isMatch: Bool {
        if case .match = self { return true }
        return false
    }
}

private struct MatchBorder: View {
    let score: Float
    let greenThreshold: Double

    var body: some View {
        GeometryReader { _ in
            Rectangle()
                .strokeBorder(color, lineWidth: thickness)
                .animation(.easeOut(duration: 0.15), value: score)
        }
    }

    private var color: Color {
        let s = Double(max(0, min(1, score)))
        let amberStart = greenThreshold * 0.5
        if s < amberStart {
            let t = s / max(amberStart, 0.01)
            return Color(red: 1, green: 0.3 + 0.5 * t, blue: 0.2)
        } else if s < greenThreshold {
            let t = (s - amberStart) / max(greenThreshold - amberStart, 0.01)
            return Color(red: 1 - 0.5 * t, green: 0.8 + 0.15 * t, blue: 0)
        } else {
            return Color(red: 0, green: 0.95, blue: 0.3)
        }
    }

    private var thickness: CGFloat {
        let s = CGFloat(max(0, min(1, score)))
        return 3 + 14 * s
    }
}

private struct TiltIndicator: View {
    let currentRoll: Double
    let targetRoll: Double

    private let tolerance: Double = 0.025

    var body: some View {
        let delta = currentRoll - targetRoll
        let isLevel = abs(delta) < tolerance

        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(isLevel ? Color.yellow.opacity(0) : Color.white.opacity(0.45))
                    .frame(width: geo.size.width * 0.5, height: 1)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .rotationEffect(.radians(-targetRoll))

                Rectangle()
                    .fill(isLevel ? Color.yellow : Color.white.opacity(0.85))
                    .frame(width: geo.size.width * 0.5, height: isLevel ? 2.5 : 1.5)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .rotationEffect(.radians(-currentRoll))
            }
            .animation(.easeOut(duration: 0.08), value: isLevel)
        }
    }
}
