import SwiftUI
import RingCore
import ImageIO

struct LibraryReader: View {
    @ObservedObject var library: LibraryStore
    let noteID: String
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var fullImage: LibraryImageSelection?
    @State private var history = ""
    @State private var showDesignConfirmation = false
    var note: LibraryNote? { library.notes.first { $0.id == (library.selectedID ?? noteID) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note {
                HStack(spacing: 16) {
                    Text(note.displayTitle).font(Theme.display(26)).lineLimit(2)
                    Spacer()
                    LibraryFolderPicker(folders: library.folders, folder: Binding(get: { note.folder }, set: { folder in library.mutate(note) { $0.folder = folder } })).frame(maxWidth: 180).disabled(library.saving)
                    CopyTextIcon(text: note.reusableText, label: "Copy exact prompt or note text")
                    Button("Edit") { editing = true }.buttonStyle(QuietButton()).disabled(library.saving)
                    Menu { LibraryNoteActions(library: library, note: note); Divider(); Button("Generate design prompt…") { showDesignConfirmation = true }.disabled(library.working || !note.automationAllowed) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Note actions")
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close note")
                }.padding(24)
                DividerLine()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(note.attachments.filter(\.isImage)) { a in
                            Button { fullImage = LibraryImageSelection(attachment: a) } label: {
                                LibraryOriginalImage(attachment: a, repository: library.repository).frame(maxHeight: 340).frame(maxWidth: .infinity)
                            }.buttonStyle(.plain).accessibilityLabel("View full-size image: \(a.originalName)")
                        }
                        if note.attachments.contains(where: { !$0.isImage }) { TaskImageAttachments(attachments: note.attachments.filter { !$0.isImage }, repository: library.repository) }
                        if !note.body.isEmpty { Text(note.body).font(.system(size: 14, design: .monospaced)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        ReferenceLinksView(text: note.body, sourceURL: note.sourceURL)
                        if !note.prompt.isEmpty { DisclosureGroup("Reusable prompt") { HStack(alignment: .top) { Text(note.prompt).font(.system(size: 13, design: .monospaced)).textSelection(.enabled); Spacer(); CopyTextIcon(text: note.prompt, label: "Copy exact prompt") }.padding(.top, 10) } }
                        if !note.comments.isEmpty { DisclosureGroup("Comments") { Text(note.comments).textSelection(.enabled).padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading) } }
                        DisclosureGroup("About this note") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Theme.secondary)
                                if !note.sourceURL.isEmpty, let url = URL(string: note.sourceURL) { Link(note.sourceURL, destination: url) }
                                if !note.displayTags.isEmpty { Text("Tags: " + note.displayTags.joined(separator: ", ")) }
                                if !note.displayKinds.isEmpty { Text("Kinds: " + note.displayKinds.map(\.rawValue).joined(separator: ", ")) }
                                ForEach(note.attachments) { a in Text("\(a.originalName) · \(ByteCountFormatter.string(fromByteCount: Int64(a.byteCount), countStyle: .file))").textSelection(.enabled) }
                                if let enrichment = note.enrichment {
                                    DisclosureGroup("AI organization") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(enrichment.summary).textSelection(.enabled)
                                            Text("\(enrichment.model) · source revision \(enrichment.inputRevision)").foregroundStyle(Theme.secondary)
                                            if enrichment.partial { Text("Only a bounded excerpt was analyzed. The complete original is kept.").foregroundStyle(Theme.alert) }
                                            ForEach(enrichment.imageDescriptions.keys.sorted(), id: \.self) { key in Text(enrichment.imageDescriptions[key] ?? "").textSelection(.enabled) }
                                            ForEach(enrichment.relatedNoteIDs, id: \.self) { id in
                                                if let related = library.notes.first(where: { $0.id == id && $0.trashedAt == nil }) { Button("Related: " + related.displayTitle) { library.selectedID = related.id } }
                                            }
                                        }.padding(.top, 8)
                                    }
                                }
                                DisclosureGroup("Original captures & history") {
                                    ForEach(note.originals) { source in
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text("\(source.channel) · \(source.capturedAt.formatted())").foregroundStyle(Theme.secondary)
                                            Text(source.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                            if !source.prompt.isEmpty { Text(source.prompt).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                                            CopyTextIcon(text: source.text, label: "Copy original capture")
                                        }.padding(.vertical, 6)
                                    }
                                    if !history.isEmpty { Text(history).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                                    Text("Deletion keeps recoverable notes and earlier Git history.").foregroundStyle(Theme.secondary)
                                }
                            }.font(Theme.body(12)).padding(.top, 14).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let error = library.error { Text(error).font(Theme.body(12)).foregroundStyle(Theme.alert).textSelection(.enabled) }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                .task(id: note.recordPath) { if let repo = library.repository { history = (try? await Task.detached { try repo.gitRead(["log", "--follow", "-8", "--format=%h %ad %s", "--date=short", "--", note.recordPath]) }.value) ?? "" } }
                .sheet(isPresented: $editing) { LibraryNoteEditor(library: library, note: note) }
                .alert("Generate a design prompt?", isPresented: $showDesignConfirmation) {
                    Button("Generate") { Task { await library.generateDesignPrompt(note) } }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Send this note’s text and permitted images to the configured Library model. This is a separate action from organization; the saved prompt is never executed.") }
            } else { Text("This note is unavailable.").padding(30); Button("Close") { dismiss() }.padding() }
        }.frame(width: 870, height: 690).background(Theme.background).foregroundStyle(Theme.text)
        .sheet(item: $fullImage) { selection in LibraryFullImage(selection: selection, repository: library.repository) }
    }
}
private struct LibraryImageSelection: Identifiable { let attachment: LibraryAttachment; var id: String { attachment.hash } }
private struct LibraryOriginalImage: View {
    let attachment: LibraryAttachment
    let repository: DataRepository?
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "photo").foregroundStyle(Theme.secondary) } }
            .task { guard let repository else { return }; image = try? await Task.detached { NSImage(contentsOf: try repository.validatedURL(attachment.path)) }.value }
    }
}
private struct LibraryFullImage: View {
    let selection: LibraryImageSelection
    let repository: DataRepository?
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    @State private var pixelSize = CGSize(width: 850, height: 570)
    var body: some View {
        VStack {
            HStack { Text(selection.attachment.originalName).font(Theme.body(13)); Spacer(); Button("100%") { zoom = 1 }; Slider(value: $zoom, in: 0.1...4).frame(width: 180).accessibilityLabel("Image zoom"); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
            ScrollView([.horizontal, .vertical]) { LibraryOriginalImage(attachment: selection.attachment, repository: repository).frame(width: pixelSize.width * zoom, height: pixelSize.height * zoom) }
        }.frame(width: 950, height: 690).background(Theme.background)
        .task {
            guard let repository else { return }
            if let size = try? await Task.detached(operation: { () -> CGSize? in
                guard let source = CGImageSourceCreateWithURL(try repository.validatedURL(selection.attachment.path) as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
                return CGSize(width: width, height: height)
            }).value { pixelSize = size; zoom = min(1, 850 / size.width, 570 / size.height) }
        }
    }
}
struct LibraryNoteEditor: View {
    @ObservedObject var library: LibraryStore
    let original: LibraryNote
    @State private var draft: LibraryNote
    @State private var tags: String
    @State private var newFiles: [URL] = []
    @State private var preparingImages = 0
    @Environment(\.dismiss) private var dismiss
    init(library: LibraryStore, note: LibraryNote) { self.library = library; original = note; _draft = State(initialValue: note); _tags = State(initialValue: note.displayTags.joined(separator: ", ")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Edit note").font(Theme.display(26)); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(library.saving ? "Saving…" : "Save") { save() }.buttonStyle(GoldButton()).disabled(library.saving || preparingImages > 0) }
            LibraryFolderPicker(folders: library.folders, folder: $draft.folder)
            TextField("Title (optional)", text: $draft.title).font(Theme.body(16))
            LibraryTextEditor(text: $draft.body, label: "Edit exact note text", onFiles: { newFiles += $0 }, onImage: attachImage).frame(minHeight: 210).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup("Prompt, comments & source") {
                        VStack(alignment: .leading) {
                            Text("Reusable prompt"); LibraryTextEditor(text: $draft.prompt, label: "Reusable prompt").frame(height: 110).background(Theme.surface)
                            TextField("Comments", text: $draft.comments, axis: .vertical)
                            TextField("Source URL", text: $draft.sourceURL)
                        }.padding(.top, 10)
                    }
                    TextField("Tags, separated by commas", text: $tags)
                    HStack { ForEach(LibraryKind.allCases, id: \.self) { kind in Toggle(kind.rawValue, isOn: Binding(get: { draft.displayKinds.contains(kind) }, set: { yes in draft.kinds = draft.displayKinds; draft.userFields.insert("kinds"); draft.kinds.removeAll { $0 == kind }; if yes { draft.kinds.append(kind) } })).toggleStyle(.checkbox) } }
                    Toggle("Allow Library AI organization for this note", isOn: $draft.automationAllowed)
                    ForEach(draft.attachments) { a in HStack { Text(a.originalName); Spacer(); Button("Remove") { draft.attachments.removeAll { $0.hash == a.hash } } }.font(Theme.body(12)) }
                    ForEach(newFiles, id: \.self) { file in Text(file.lastPathComponent).font(Theme.body(12)) }
                    Button("Attach files…") { let panel = NSOpenPanel(); panel.allowedContentTypes = LibraryMedia.supported; panel.allowsMultipleSelection = true; if panel.runModal() == .OK { newFiles += panel.urls } }
                    if let error = library.error { Text(error).foregroundStyle(Theme.alert).textSelection(.enabled) }
                }.font(Theme.body(12))
            }.frame(maxHeight: 225)
        }.padding(26).frame(width: 820, height: 660).background(Theme.background)
    }
    private func attachImage(_ data: Data) {
        guard let repository = library.repository else { return }
        preparingImages += 1
        Task {
            defer { preparingImages -= 1 }
            do { let file = try await Task.detached { try LibraryMedia.clipboardImage(data, localState: repository.localState) }.value; newFiles.append(file) }
            catch { library.error = error.localizedDescription }
        }
    }
    private func save() {
        var value = draft; value.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if tags != original.displayTags.joined(separator: ", ") { value.userFields.insert("tags") }
        if value.title != original.title { value.userFields.insert("title") }
        value.revision = original.revision + 1; value.updatedAt = Date()
        Task { if await library.saveEdit(value, expectedRevision: original.revision, files: newFiles) { dismiss() } }
    }
}
