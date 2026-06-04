import SwiftUI

struct DiamondBorderMask: View {
    var diamondHalfSize: CGFloat = 18
    var spacing: CGFloat = 46
    var borderFraction: CGFloat = 0.22

    var body: some View {
        Canvas { ctx, size in
            let borderDepth = min(size.width, size.height) * borderFraction
            let centerRect = CGRect(
                x: borderDepth,
                y: borderDepth,
                width: max(0, size.width - 2 * borderDepth),
                height: max(0, size.height - 2 * borderDepth)
            )

            let rows = Int(ceil(size.height / spacing)) + 2
            let cols = Int(ceil(size.width / spacing)) + 2
            for row in -1..<rows {
                let rowOffset: CGFloat = (abs(row) % 2 == 0) ? 0 : spacing / 2
                for col in -1..<cols {
                    let cx = CGFloat(col) * spacing + rowOffset
                    let cy = CGFloat(row) * spacing

                    if centerRect.contains(CGPoint(x: cx, y: cy)) { continue }

                    var path = Path()
                    path.move(to: CGPoint(x: cx, y: cy - diamondHalfSize))
                    path.addLine(to: CGPoint(x: cx + diamondHalfSize, y: cy))
                    path.addLine(to: CGPoint(x: cx, y: cy + diamondHalfSize))
                    path.addLine(to: CGPoint(x: cx - diamondHalfSize, y: cy))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(.black))
                }
            }
        }
    }
}
