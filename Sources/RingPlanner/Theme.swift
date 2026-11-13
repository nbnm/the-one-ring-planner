import SwiftUI
import AppKit

// Native adaptive colors: the warm palette follows system Light / Dark appearance.
enum Theme {
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color { Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }) }
    static func rgb(_ hex: UInt) -> NSColor { NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1) }
    static let background = adaptive(rgb(0xF4EDD9), rgb(0x202B23))
    static let sidebar = adaptive(rgb(0x294737), rgb(0x182C23))
    static let navigationText = Color(nsColor: rgb(0xE2E7D4))
    static let navigationSelected = Color(nsColor: rgb(0xF1DBA2))
    static let navigationFill = Color(nsColor: rgb(0x405C43))
    static let statusSurface = adaptive(rgb(0xEDE5CD), rgb(0x233327))
    static let surface = adaptive(rgb(0xFCF8EB), rgb(0x2A382C))
    static let text = adaptive(rgb(0x2D3929), rgb(0xF3ECD9))
    static let secondary = adaptive(rgb(0x68745D), rgb(0xB3BFA4))
    static let line = adaptive(rgb(0xD9D1B6), rgb(0x465140))
    static let gold = adaptive(rgb(0x82632F), rgb(0xD6B56B))
    static let goldFill = adaptive(rgb(0xE8DCB7), rgb(0x4B5133))
    static let green = adaptive(rgb(0x53684A), rgb(0xA0B791))
    static let alert = adaptive(rgb(0x9C583C), rgb(0xDEA487))
    static let calendarTask = adaptive(rgb(0xC5221F), rgb(0xF28B82))
    static let calendarRoutine = adaptive(rgb(0x0B8043), rgb(0x81C995))
    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font { .custom("AvenirNext-\(weight == .bold ? "Bold" : (weight == .semibold ? "DemiBold" : "Regular"))", size: size) }
    static func display(_ size: CGFloat = 34) -> Font { .custom("Palatino-Roman", size: size) }
}

enum RingArtwork {
    static let image: NSImage? = {
        let file = Bundle.main.url(forResource: "OneRing", withExtension: "png")
            ?? Bundle.module.url(forResource: "OneRing", withExtension: "png")
        return file.flatMap { NSImage(contentsOf: $0) }
    }()
    static let menuBarImage: NSImage? = {
        guard let icon = image?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 22, height: 22)
        icon.isTemplate = false
        return icon
    }()
}

struct RingMark: View {
    var size: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        Group {
            if let image = RingArtwork.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "circle").resizable().scaledToFit().foregroundStyle(Theme.gold)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(appeared ? 1 : 0.94)
        .accessibilityLabel("The One Ring Planner logo")
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { appeared = true } }
    }
}
struct GoldButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.body(13, weight: .semibold)).foregroundStyle(Theme.background)
            .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.gold, in: Capsule())
            .opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.75 : 1))
    }
}
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.body(12, weight: .semibold)).foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.line.opacity(configuration.isPressed ? 0.65 : 0.32), in: RoundedRectangle(cornerRadius: 7))
    }
}
struct SectionLabel: View {
    let title: String
    var body: some View { Text(title.uppercased()).font(Theme.body(10, weight: .semibold)).tracking(1.7).foregroundStyle(Theme.secondary) }
}
struct DividerLine: View { var body: some View { Rectangle().fill(Theme.line).frame(height: 1) } }
struct Tag: View {
    let title: String
    var body: some View { Text(title).font(Theme.body(10, weight: .semibold)).foregroundStyle(Theme.gold).padding(.horizontal, 7).padding(.vertical, 4).background(Theme.goldFill, in: RoundedRectangle(cornerRadius: 4)) }
}

private struct LibraryDemoReduceMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var libraryDemoReduceMotion: Bool { get { self[LibraryDemoReduceMotionKey.self] } set { self[LibraryDemoReduceMotionKey.self] = newValue } } }
