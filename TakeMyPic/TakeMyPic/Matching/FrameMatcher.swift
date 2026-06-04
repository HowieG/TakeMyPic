import Vision
import AVFoundation
import CoreImage
import UIKit
import QuartzCore

nonisolated final class FrameMatcher: @unchecked Sendable {

    // MARK: - Tunables (edit these to change matching feel)

    /// Stricter as this gets smaller. Translation between reference and live
    /// frame is expressed as a fraction of image size; this is the magnitude
    /// at which the score hits 0. Typical: 0.05 (very strict) ... 0.18 (loose).
    private let translationTolerance: Float = 0.08

    /// How often to score frames. Smaller = more responsive, more CPU.
    private let minInterval: TimeInterval = 0.18

    /// Smoothing 0...1. Higher = snappier, less averaged.
    private let smoothing: Float = 0.45

    /// Resize reference + live frames to this width before Vision runs.
    /// Smaller = faster, less precise; bigger = slower, more precise.
    private let targetWidth: CGFloat = 480

    // MARK: - State

    private let queue = DispatchQueue(label: "TakeMyPic.matcher", qos: .userInitiated)
    private var referenceImage: CIImage?
    private var referenceSize: CGSize = .zero
    private var lastProcessed: TimeInterval = 0
    private var ema: Float = 0

    // MARK: - API

    func setReference(_ image: UIImage?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.ema = 0
            self.lastProcessed = 0

            guard let image, let ciInput = CIImage(image: image) else {
                self.referenceImage = nil
                self.referenceSize = .zero
                return
            }
            let extent = ciInput.extent
            let scale = self.targetWidth / max(extent.width, 1)
            let scaled = ciInput.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            self.referenceImage = scaled
            self.referenceSize = scaled.extent.size
        }
    }

    func process(sampleBuffer: CMSampleBuffer, onScore: @escaping @Sendable (Float) -> Void) {
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= minInterval else { return }
        guard referenceImage != nil else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = now

        var live = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let liveExtent = live.extent
        let scale = targetWidth / max(liveExtent.width, 1)
        live = live.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let livePrepared = live

        queue.async { [weak self] in
            guard let self, let ref = self.referenceImage else { return }

            let request = VNTranslationalImageRegistrationRequest(targetedCIImage: livePrepared)
            let handler = VNImageRequestHandler(ciImage: ref, options: [:])

            var raw: Float = 0
            do {
                try handler.perform([request])
                if let obs = request.results?.first as? VNImageTranslationAlignmentObservation {
                    let transform = obs.alignmentTransform
                    let refW = max(Float(self.referenceSize.width), 1)
                    let refH = max(Float(self.referenceSize.height), 1)
                    let tx = Float(transform.tx) / refW
                    let ty = Float(transform.ty) / refH
                    let translation = sqrt(tx * tx + ty * ty)
                    raw = max(0, min(1, 1 - translation / self.translationTolerance))
                }
            } catch {
                raw = 0
            }

            self.ema = self.smoothing * raw + (1 - self.smoothing) * self.ema
            onScore(max(0, min(1, self.ema)))
        }
    }
}
