import SwiftUI
import AppKit
import RingCore

struct CopyTextIcon: View {
    let text: String
    var label = "Copy text"
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13)).frame(width: 26, height: 26).contentShape(Rectangle()) }
        .buttonStyle(.plain).foregroundStyle(Theme.secondary).help(copied ? "Copied" : label).accessibilityLabel(label)
    }
}
struct ReferenceLinksView: View {
    let text: String
    var sourceURL = ""
    private var links: [URL] {
        var values = ReferenceLinks.extract(text)
        if let source = ReferenceLinks.valid(sourceURL), !values.contains(source) { values.insert(source, at: 0) }; return values
    }
    var body: some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(links, id: \.absoluteString) { url in
                    HStack(spacing: 8) {
                        Link(destination: url) { Label(url.host ?? url.absoluteString, systemImage: "link").lineLimit(1) }.help(url.absoluteString).accessibilityLabel("Open link: \(url.absoluteString)")
                        Spacer(minLength: 4); CopyTextIcon(text: url.absoluteString, label: "Copy link")
                    }.font(Theme.body(12))
                }
            }
        }
    }
}
