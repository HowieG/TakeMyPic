import SwiftUI
import AVFoundation
import UIKit

struct CameraView: View {
    let mode: CameraMode
    @ObservedObject var traceStore: TraceStore
    let onClose: () -> Void

    @StateObject private var controller = CameraController()
    @StateObject private var motion = MotionService()
    @State private var overlayOpacity: Double = 0.4
    @State private var isCapturing = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didCelebrate = false
    @State private var capturedImage: UIImage?
    @State private var capturedData: Data?
    @State private var revealFraction: Double = 0.0
    @State private var pinchStartZoom: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let previewHeight = width * 4.0 / 3.0
            let topSpace = max(60, (geo.size.height - previewHeight) * 0.35)

            VStack(spacing: 0) {
                topChrome
                    .frame(height: topSpace)
                previewArea(width: width, height: previewHeight)
                bottomChrome
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
            if newScore >= 0.8 && !didCelebrate {
                didCelebrate = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else if newScore < 0.65 {
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
                    .opacity(overlayOpacity)
                    .allowsHitTesting(false)

                TiltIndicator(roll: motion.roll)
                    .allowsHitTesting(false)

                MatchBorder(score: controller.matchScore)
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
        capturedImage == nil && (mode.isMatch)
    }

    private var modeLabel: String {
        if capturedImage != nil { return "REVIEW" }
        switch mode {
        case .reference: return "REFERENCE"
        case .match: return "MATCH"
        }
    }

    // MARK: - Bottom chrome

    private var bottomChrome: some View {
        VStack(spacing: 14) {
            if capturedImage == nil {
                zoomRow
                shutterRow
                if case .match = mode {
                    labeledSlider(
                        label: "Transparency",
                        value: $overlayOpacity,
                        range: 0.1...0.85
                    )
                }
            } else {
                if case .match = mode {
                    labeledSlider(
                        label: "Original",
                        value: $revealFraction,
                        range: 0.0...1.0
                    )
                }
                photoActions
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .frame(maxWidth: .infinity)
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

    private func labeledSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 10) {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.white.opacity(0.7))
                Slider(value: value, in: range)
                    .tint(.white)
                Image(systemName: "circle.fill")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.12), in: Capsule())
    }

    private var photoActions: some View {
        HStack(spacing: 18) {
            Button {
                capturedImage = nil
                capturedData = nil
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
            revealFraction = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func keep() async {
        guard let data = capturedData else { return }
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let id = try await PhotoLibraryService.saveJPEG(data)
            if case .reference = mode {
                traceStore.add(id, metadata: TraceMetadata(zoom: Double(controller.displayZoom)))
            }
            onClose()
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

    var body: some View {
        GeometryReader { _ in
            Rectangle()
                .strokeBorder(color, lineWidth: thickness)
                .animation(.easeOut(duration: 0.15), value: score)
        }
    }

    private var color: Color {
        let s = Double(max(0, min(1, score)))
        if s < 0.4 {
            let t = s / 0.4
            return Color(red: 1, green: 0.3 + 0.5 * t, blue: 0.2)
        } else if s < 0.8 {
            let t = (s - 0.4) / 0.4
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
    let roll: Double

    var body: some View {
        GeometryReader { geo in
            let isLevel = abs(roll) < 0.025
            ZStack {
                Rectangle()
                    .fill(isLevel ? Color.yellow.opacity(0) : Color.white.opacity(0.35))
                    .frame(width: geo.size.width * 0.45, height: 1)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                Rectangle()
                    .fill(isLevel ? Color.yellow : Color.white.opacity(0.75))
                    .frame(width: geo.size.width * 0.45, height: isLevel ? 2 : 1)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .rotationEffect(.radians(roll))
            }
            .animation(.easeOut(duration: 0.1), value: isLevel)
        }
    }
}
