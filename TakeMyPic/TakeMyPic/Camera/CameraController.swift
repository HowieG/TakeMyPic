import AVFoundation
import UIKit
import Combine

final class CameraController: NSObject, ObservableObject {
    @Published var isRunning: Bool = false
    @Published var matchScore: Float = 0
    @Published var lastError: String?
    @Published private(set) var displayZoom: CGFloat = 1.0
    @Published private(set) var zoomPresets: [CGFloat] = [1.0]
    @Published private(set) var minDisplayZoom: CGFloat = 1.0
    @Published private(set) var maxDisplayZoom: CGFloat = 1.0

    nonisolated let session = AVCaptureSession()
    nonisolated let matcher = FrameMatcher()

    private nonisolated let sessionQueue = DispatchQueue(label: "TakeMyPic.session")
    private nonisolated let videoQueue = DispatchQueue(label: "TakeMyPic.video")
    private nonisolated let photoOutput = AVCapturePhotoOutput()
    private nonisolated let videoOutput = AVCaptureVideoDataOutput()

    private nonisolated(unsafe) var captureDelegate: PhotoCaptureDelegate?
    private nonisolated(unsafe) var configured = false
    private nonisolated(unsafe) var device: AVCaptureDevice?
    private nonisolated(unsafe) var firstSwitchoverFactor: CGFloat = 1.0
    private nonisolated(unsafe) var pendingInitialDisplayZoom: CGFloat?

    func setReference(_ image: UIImage?) {
        matcher.setReference(image)
        matchScore = 0
    }

    nonisolated func setInitialDisplayZoom(_ display: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.device != nil {
                self.applyDisplayZoom(display)
            } else {
                self.pendingInitialDisplayZoom = display
            }
        }
    }

    nonisolated func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            Task { @MainActor in self.isRunning = running }
        }
    }

    nonisolated func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor in self.isRunning = false }
        }
    }

    nonisolated func setDisplayZoom(_ display: CGFloat) {
        sessionQueue.async { [weak self] in
            self?.applyDisplayZoom(display)
        }
    }

    nonisolated func capturePhoto(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            let delegate = PhotoCaptureDelegate { result in completion(result) }
            self.captureDelegate = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private nonisolated func applyDisplayZoom(_ display: CGFloat) {
        guard let device else { return }
        let switchover = firstSwitchoverFactor
        let target = display * switchover
        let minZ = device.minAvailableVideoZoomFactor
        let maxZ = min(device.maxAvailableVideoZoomFactor, 16 * switchover)
        let clamped = max(minZ, min(maxZ, target))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            let actual = clamped / switchover
            Task { @MainActor in self.displayZoom = actual }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in self.lastError = message }
        }
    }

    private nonisolated func configureSessionIfNeeded() {
        guard !configured else { return }
        configured = true

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = Self.bestBackCamera() else {
            session.commitConfiguration()
            Task { @MainActor in self.lastError = "No back camera available." }
            return
        }
        self.device = device

        let switchover = Self.firstSwitchoverFactor(for: device)
        let presets = Self.zoomPresets(for: device)
        firstSwitchoverFactor = switchover
        let minDisplay = max(device.minAvailableVideoZoomFactor / switchover, 0.5)
        let maxDisplay = min(device.maxAvailableVideoZoomFactor / switchover, 16)

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            session.commitConfiguration()
            let message = error.localizedDescription
            Task { @MainActor in self.lastError = message }
            return
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .balanced
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if let conn = photoOutput.connection(with: .video),
           conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }

        session.commitConfiguration()

        let initialDisplay = pendingInitialDisplayZoom ?? 1.0
        pendingInitialDisplayZoom = nil

        Task { @MainActor in
            self.zoomPresets = presets
            self.minDisplayZoom = minDisplay
            self.maxDisplayZoom = maxDisplay
        }
        applyDisplayZoom(initialDisplay)
    }

    private nonisolated static func bestBackCamera() -> AVCaptureDevice? {
        let order: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        for type in order {
            if let d = AVCaptureDevice.default(type, for: .video, position: .back) {
                return d
            }
        }
        return nil
    }

    private nonisolated static func zoomPresets(for device: AVCaptureDevice) -> [CGFloat] {
        let constituents = device.constituentDevices
        let hasUltraWide = constituents.contains { $0.deviceType == .builtInUltraWideCamera }
        let hasTele = constituents.contains { $0.deviceType == .builtInTelephotoCamera }

        var presets: [CGFloat] = []
        if hasUltraWide { presets.append(0.5) }
        presets.append(1.0)
        presets.append(2.0)
        if hasTele { presets.append(5.0) }
        return presets
    }

    private nonisolated static func firstSwitchoverFactor(for device: AVCaptureDevice) -> CGFloat {
        let constituents = device.constituentDevices
        let hasUltraWide = constituents.contains { $0.deviceType == .builtInUltraWideCamera }
        if hasUltraWide,
           let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            return CGFloat(truncating: first)
        }
        return 1.0
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        matcher.process(sampleBuffer: sampleBuffer) { [weak self] score in
            guard let self else { return }
            Task { @MainActor in self.matchScore = score }
        }
    }
}
