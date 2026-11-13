import SwiftUI
import RingCore

/// Independent from the Library draft. Originals join task writes in the same journal.
@MainActor final class TaskCaptureAssets: ObservableObject {
    let repository: DataRepository?
    var captureID = UUID().uuidString.lowercased()
    var createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    @Published var text = "" { didSet { retain() } }
    @Published var files: [URL] = [] { didSet { retain() } }
    @Published var preparing = 0
    @Published var error: String?
    private var draftWrite: Task<Void, Never>?
    init(repository: DataRepository?) {
        self.repository = repository
        if let repository {
            if let draft = try? LibraryStore.read(LibraryDraft.self, file: repository.localState.appendingPathComponent("inbox-capture-draft.json")) { captureID = draft.id; createdAt = draft.createdAt; text = draft.body; files = draft.files }
            else { files = (try? LibraryStore.read([URL].self, file: repository.localState.appendingPathComponent("task-image-draft.json"))) ?? [] }
        }
    }
    func addFiles(_ values: [URL]) {
        guard let repository, !values.isEmpty else { return }
        preparing += 1
        Task {
            defer { preparing -= 1 }
            do {
                let copies = try await Task.detached {
                    try values.map { file -> URL in
                        let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
                        guard ["png", "jpg", "jpeg", "heic", "md", "markdown", "txt"].contains(file.pathExtension.lowercased()), let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= LibraryPolicy.maximumAttachmentBytes else { throw LibraryError.invalid("Attach images or Markdown/text files up to 20 MB each.") }
                        let folder = repository.localState.appendingPathComponent("task-image-drafts/\(UUID().uuidString)")
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let target = folder.appendingPathComponent(file.lastPathComponent)
                        try FileManager.default.copyItem(at: file, to: target); return target
                    }
                }.value
                files += copies; error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    func pasteImage(_ bytes: Data) {
        guard let repository else { return }; preparing += 1
        Task {
            defer { preparing -= 1 }
            do { let file = try await Task.detached { try LibraryMedia.clipboardImage(bytes, localState: repository.localState) }.value; files.append(file); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = LibraryMedia.supported; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
    func removeConfirmed(_ confirmed: [URL]) { files.removeAll { confirmed.contains($0) } }
    func rotateIdentity() { captureID = UUID().uuidString.lowercased(); createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)); retain() }
    private var snapshot: LibraryDraft { var value = LibraryDraft(); value.id = captureID; value.createdAt = createdAt; value.body = text; value.files = files; return value }
    private func retain() {
        draftWrite?.cancel(); guard let repository else { return }; let snapshot = self.snapshot
        draftWrite = Task {
            try? await Task.sleep(for: .milliseconds(200)); guard !Task.isCancelled else { return }
            do { try await Task.detached { try LibraryStore.write(snapshot, file: repository.localState.appendingPathComponent("inbox-capture-draft.json")) }.value }
            catch { self.error = "Image draft could not be retained. Keep capture open and retry." }
        }
    }
    func flush() async {
        while preparing > 0 { try? await Task.sleep(for: .milliseconds(50)) }
        draftWrite?.cancel(); guard let repository else { return }; let snapshot = self.snapshot
        try? await Task.detached { try LibraryStore.write(snapshot, file: repository.localState.appendingPathComponent("inbox-capture-draft.json")) }.value
    }
}

struct CaptureAttachmentStrip: View {
    let files: [URL]
    let remove: (URL) -> Void
    var body: some View {
        if !files.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(files, id: \.self) { file in
                        ZStack(alignment: .topTrailing) {
                            DraftAttachmentPreview(file: file)
                            Button { remove(file) } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.7)).padding(3) }.buttonStyle(.plain).accessibilityLabel("Remove attachment \(file.lastPathComponent)")
                        }.frame(width: 84, height: 66).clipShape(RoundedRectangle(cornerRadius: 10)).help(file.lastPathComponent)
                    }
                }
            }.frame(height: 70)
        }
    }
}
private struct DraftAttachmentPreview: View {
    let file: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "doc.text").frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.surface) }
        }.task(id: file) { image = await Task.detached { NSImage(contentsOf: file) }.value }
    }
}
