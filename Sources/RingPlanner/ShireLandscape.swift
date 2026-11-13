import SwiftUI

/// Original, resolution-independent landscape: rolling hills, a round door and the path home.
struct ShireLandscape: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func c(_ light: UInt, _ dark: UInt) -> Color { Color(nsColor: Theme.rgb(scheme == .dark ? dark : light)) }
            func shape(_ points: [(Double, Double)], fill: Color) {
                var p = Path(); p.move(to: CGPoint(x: points[0].0 * w, y: points[0].1 * h))
                for point in points.dropFirst() { p.addLine(to: CGPoint(x: point.0 * w, y: point.1 * h)) }; p.closeSubpath(); context.fill(p, with: .color(fill))
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [c(0xEEE4BF, 0x354137), c(0xF7EDCE, 0x505442)]), startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
            context.fill(Path(ellipseIn: CGRect(x: w * 0.74, y: -h * 0.27, width: h * 1.1, height: h * 1.1)), with: .color(c(0xFFF3CD, 0x797A50).opacity(0.65)))
            for layer in 0..<3 {
                let y = h * (0.49 + Double(layer) * 0.13)
                var p = Path(); p.move(to: CGPoint(x: 0, y: y))
                p.addCurve(to: CGPoint(x: w, y: y - h * 0.08), control1: CGPoint(x: w * 0.35, y: y - h * 0.5), control2: CGPoint(x: w * 0.64, y: y + h * 0.7))
                p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                let colors: [Color] = [c(0xB7BE85, 0x586347), c(0x8D9F68, 0x42573B), c(0x657F4B, 0x304A35)]
                context.fill(p, with: .color(colors[layer]))
            }
            shape([(0.55,1), (0.72,0.65), (0.81,0.52), (0.77,0.65), (0.68,1)], fill: c(0xD4BE83, 0x7F7956))
            var roof = Path(); roof.move(to: CGPoint(x: w * 0.08, y: h)); roof.addQuadCurve(to: CGPoint(x: w * 0.40, y: h), control: CGPoint(x: w * 0.24, y: -h * 0.02)); roof.closeSubpath()
            context.fill(roof, with: .color(c(0xB9B37C, 0x6D7650)))
            let door = CGRect(x: w * 0.20, y: h * 0.54, width: h * 0.39, height: h * 0.49)
            context.fill(Path(ellipseIn: door.insetBy(dx: -4, dy: -4)), with: .color(c(0xE8CA8A, 0xA78C53)))
            context.fill(Path(ellipseIn: door), with: .color(c(0x9F5E29, 0x9E7840)))
            context.stroke(Path(ellipseIn: door.insetBy(dx: 3, dy: 3)), with: .color(c(0x744A2B, 0xB69B64)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: door.midX + 3, y: door.midY, width: 3, height: 3)), with: .color(Color(nsColor: Theme.rgb(0xF5D38A))))
            var trunk = Path(); trunk.move(to: CGPoint(x: w * 0.115, y: h * 0.74)); trunk.addCurve(to: CGPoint(x: w * 0.10, y: -h * 0.2), control1: CGPoint(x: w * 0.14, y: h * 0.45), control2: CGPoint(x: w * 0.07, y: h * 0.2))
            context.stroke(trunk, with: .color(c(0x645037, 0x283D2D)), style: StrokeStyle(lineWidth: max(7, w * 0.012), lineCap: .round))
            for i in 0..<180 {
                let x = Double((i * 73 + 13) % 257) / 257 * w * 0.38
                let y = Double((i * 47 + 11) % 109) / 109 * h * 0.44 - h * 0.14
                let radius = Double(3 + i % 10)
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2.2, height: radius)), with: .color([c(0x466B42, 0x2C4835), c(0x77934E, 0x496244), c(0xB4B569, 0x72805A)][i % 3].opacity(0.82)))
            }
            // Tiny gold and cream flowers, kept away from the work surface.
            for i in 0..<70 {
                let x = Double((i * 127 + 9) % 991) / 991 * w, y = h * (0.84 + Double(i % 13) / 80)
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(c(0xF1D58D, 0xB5AA74).opacity(0.7)))
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
