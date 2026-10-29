import SwiftUI
import RingCore

struct RoutineCelebration: View {
    let kind: RoutineKind
    let title: String
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    var body: some View {
        ZStack {
            Theme.background.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    Circle().stroke(Theme.gold.opacity(expanded ? 0 : 0.4), lineWidth: 1).frame(width: 130, height: 130).scaleEffect(expanded ? 1.8 : 0.8)
                    ForEach(0..<10) { i in
                        Image(systemName: kind == .guitar ? (i % 2 == 0 ? "music.note" : "music.quarternote.3") : (kind == .movement ? "sparkle" : "star.fill"))
                            .font(.system(size: CGFloat(12 + i % 3 * 4))).foregroundStyle(Theme.gold)
                            .offset(x: cos(Double(i) * .pi / 5) * (expanded ? 108 : 35), y: sin(Double(i) * .pi / 5) * (expanded ? 85 : 25))
                            .rotationEffect(.degrees(expanded ? Double(i * 16 - 70) : 0)).opacity(expanded ? 0.9 : 0)
                    }
                    Image(systemName: kind.symbol)
                        .font(.system(size: 66, weight: .ultraLight)).foregroundStyle(Theme.gold)
                        .rotationEffect(.degrees(kind == .guitar && expanded ? -12 : 0)).offset(y: expanded ? -4 : 3)
                }.frame(width: 280, height: 220)
                Text(kind == .guitar ? "A few notes. A better day." : (kind == .movement ? "A small adventure, complete." : (kind == .review ? "The day is in good hands." : "A little time, well spent."))).font(Theme.display(29))
                Text("\(title), complete. The fellowship approves.").font(Theme.body(13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button("Back to my day", action: dismiss).buttonStyle(QuietButton()).padding(.top, 10)
            }
        }.onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 1.2)) { expanded = true }
            Task { try? await Task.sleep(for: .seconds(3.5)); dismiss() }
        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
    }
}
