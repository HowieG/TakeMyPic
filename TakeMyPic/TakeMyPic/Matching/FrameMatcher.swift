import Vision
import AVFoundation
import CoreImage
import UIKit
import QuartzCore

nonisolated final class FrameMatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TakeMyPic.matcher", qos: .userInitiated)
    private let minInterval: TimeInterval = 0.16
    private let smoothing: Float = 0.35
    private let matchDistance: Float = 0.4
    private let failDistance: Float = 0.9

    private var referenceObservation: VNFeaturePrintObservation?
    private var lastProcessed: TimeInterval = 0
    private var ema: Float = 0

    func setReference(_ image: UIImage?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.ema = 0
            self.lastProcessed = 0
            guard let image, let cgImage = image.cgImage else {
                self.referenceObservation = nil
                return
            }
            let orientation = Self.cgOrientation(image.imageOrientation)
            self.referenceObservation = Self.featurePrint(cgImage: cgImage, orientation: orientation)
        }
    }

    func process(sampleBuffer: CMSampleBuffer, onScore: @escaping @Sendable (Float) -> Void) {
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= minInterval else { return }
        guard referenceObservation != nil else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = now

        queue.async { [weak self] in
            guard let self, let ref = self.referenceObservation else { return }
            guard let liveObs = Self.featurePrint(pixelBuffer: pixelBuffer) else { return }
            var distance: Float = 0
            do {
                try liveObs.computeDistance(&distance, to: ref)
            } catch {
                return
            }
            let span = max(0.001, self.failDistance - self.matchDistance)
            let raw = max(0, min(1, 1 - (distance - self.matchDistance) / span))
            self.ema = self.smoothing * raw + (1 - self.smoothing) * self.ema
            let score = max(0, min(1, self.ema))
            onScore(score)
        }
    }

    private static func featurePrint(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first as? VNFeaturePrintObservation
    }

    private static func featurePrint(pixelBuffer: CVPixelBuffer) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first as? VNFeaturePrintObservation
    }

    private static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
