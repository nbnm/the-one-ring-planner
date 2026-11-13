import SwiftUI
import RingCore

struct TaskImageAttachments: View {
    let attachments: [LibraryAttachment]
    let repository: DataRepository?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachments.contains(where: \.isImage) {
                ScrollView(.horizontal) { HStack(spacing: 12) { ForEach(attachments.filter(\.isImage)) { attachment in TaskImagePreview(attachment: attachment, repository: repository) } } }.frame(height: 110)
            }
            ForEach(attachments.filter { !$0.isImage }) { attachment in
                Button {
                    guard let repository, let file = try? repository.validatedURL(attachment.path) else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } label: { Label(attachment.originalName, systemImage: "doc") }.buttonStyle(.plain).foregroundStyle(Theme.gold).accessibilityLabel("Show original file: " + attachment.originalName)
            }
        }
    }
}
private struct TaskImagePreview: View {
    let attachment: LibraryAttachment
    let repository: DataRepository?
    @State private var image: NSImage?
    @State private var expanded = false
    var body: some View {
        Button { expanded = true } label: {
            Group { if let image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "photo") } }.frame(width: 130, height: 100).background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel("View task image: \(attachment.originalName)")
        .task { guard let repository else { return }; image = try? await Task.detached { NSImage(contentsOf: try repository.validatedURL(attachment.path)) }.value }
        .sheet(isPresented: $expanded) {
            VStack { HStack { Text(attachment.originalName); Spacer(); Button("Done") { expanded = false }.keyboardShortcut(.cancelAction) }; ScrollView([.horizontal, .vertical]) { if let image { Image(nsImage: image).resizable().scaledToFit().frame(width: min(1100, image.size.width)) } } }.padding(20).frame(width: 900, height: 660).background(Theme.background)
        }
    }
}
