import SwiftUI

struct SlimSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var trackHeight: CGFloat = 3
    var thumbSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let span = max(totalWidth - thumbSize, 1)
            let fraction = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
            let clampedFraction = max(0, min(1, fraction))
            let thumbX = clampedFraction * span

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.white)
                    .frame(width: thumbX + thumbSize / 2, height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0.5)
                    .offset(x: thumbX)
            }
            .frame(height: max(thumbSize, trackHeight))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let x = max(0, min(span, drag.location.x - thumbSize / 2))
                        let p = Double(x / span)
                        value = range.lowerBound + p * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: max(thumbSize, trackHeight))
    }
}
