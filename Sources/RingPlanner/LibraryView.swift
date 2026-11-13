import SwiftUI
import RingCore
import UniformTypeIdentifiers

struct LibraryPage: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var library: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.libraryDemoReduceMotion) private var demoReduceMotion
    @FocusState private var focusedID: String?
    @State private var readerID: String?
    private var reader: Binding<LibraryReaderSelection?> {
        Binding(get: { readerID.map { LibraryReaderSelection(id: $0) } }, set: { if $0 == nil { focusedID = readerID }; readerID = $0?.id })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                Text("Library").font(Theme.display(32))
                Spacer()
                TextField("Search Library", text: $library.query).textFieldStyle(.roundedBorder).frame(maxWidth: 320).accessibilityLabel("Search Library").onSubmit { if library.semantic { library.searchSemantically() } }
                Button { AppActions.captureNote() } label: { Label("New note", systemImage: "plus") }.buttonStyle(GoldButton()).keyboardShortcut("n", modifiers: [.command, .shift])
            }
            HStack(spacing: 16) {
                LibraryFolderControls(library: library)
                Picker("Collection", selection: $library.collection) { ForEach(LibraryCollection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 156).accessibilityLabel("Library collection")
                if library.showingArchived || library.showingTrash {
                    Button(library.showingTrash ? "Trash ×" : "Archive ×") { library.showingArchived = false; library.showingTrash = false }.buttonStyle(.plain).foregroundStyle(Theme.gold)
                }
                if !library.tag.isEmpty { Button(library.tag + " ×") { library.tag = "" }.buttonStyle(.plain).foregroundStyle(Theme.gold) }
                if let kind = library.kind { Button(kind.rawValue + " ×") { library.kind = nil }.buttonStyle(.plain).foregroundStyle(Theme.gold) }
                Spacer()
                if library.semantic { Button(library.working ? "Searching…" : "Find by meaning") { library.searchSemantically() }.disabled(library.working || library.query.isEmpty) }
                Menu {
                    Menu("Tag") { Button("Any tag") { library.tag = "" }; ForEach(library.allTags, id: \.self) { tag in Button(tag) { library.tag = tag } } }
                    Menu("Kind") { Button("Any kind") { library.kind = nil }; ForEach(LibraryKind.allCases, id: \.self) { kind in Button(kind.rawValue) { library.kind = kind } } }
                    Toggle("Semantic search", isOn: $library.semantic).disabled(library.capabilities.embeddingConfiguration == nil)
                    Divider()
                    Button("Archive") { library.showingArchived = true; library.showingTrash = false }
                    Button("Trash") { library.showingTrash = true; library.showingArchived = false }
                    Button("Retry background jobs") { Task { await library.retryJobs() } }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Library actions")
                Picker("View", selection: $library.gallery) { Label("Gallery", systemImage: "square.grid.2x2").labelStyle(.iconOnly).tag(true); Label("List", systemImage: "list.bullet").labelStyle(.iconOnly).tag(false) }.pickerStyle(.segmented).labelsHidden().frame(width: 76).accessibilityLabel("Library gallery or list view")
            }.font(Theme.body(12))
            DividerLine()
            if let error = library.error {
                HStack(alignment: .top) { Text(error).font(Theme.body(12)).foregroundStyle(Theme.alert).textSelection(.enabled); Spacer(); Button { library.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss Library message") }
            }
            if library.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if library.results.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "books.vertical").font(.system(size: 30)).foregroundStyle(Theme.gold)
                    Text(library.showingTrash ? "Trash is empty" : (library.showingArchived ? "No archived notes" : (library.query.isEmpty ? "A place for what’s useful" : "No matching notes"))).font(Theme.display(26))
                    if !library.showingTrash && !library.showingArchived {
                        Text(library.query.isEmpty ? "Keep an image, a prompt, or a thought. Organize it later." : "Try a title, phrase, tag, or text inside an image.").foregroundStyle(Theme.secondary)
                        if library.query.isEmpty { Button("New note") { AppActions.captureNote() }.buttonStyle(QuietButton()) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    if library.gallery {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 218, maximum: 320), spacing: 22)], alignment: .leading, spacing: 24) {
                            ForEach(library.results) { note in noteButton(note, gallery: true) }
                        }.padding(.vertical, 4)
                    } else {
                        LazyVStack(spacing: 0) { ForEach(library.results) { note in noteButton(note, gallery: false); DividerLine() } }
                    }
                }
            }
        }.padding(30).background(Theme.background)
        .background { GeometryReader { geo in Color.clear.preference(key: LibraryDropRegionsKey.self, value: [geo.frame(in: .named(PlannerDragSpace.workspace))]) } }
        .overlay { if store.taskDrag.map({ drag in store.libraryDropRegions.contains { $0.contains(drag.location) } }) == true { RoundedRectangle(cornerRadius: 8).stroke(Theme.gold, lineWidth: 2).padding(8).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.tiff.identifier, UTType.url.identifier, UTType.plainText.identifier], isTargeted: nil) { providers in
            AppActions.captureNote()
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        if let data, let url = URL(dataRepresentation: data, relativeTo: nil) { Task { @MainActor in library.addFiles([url]) } }
                    }
                } else if ![UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.tiff.identifier].contains(where: { provider.hasItemConformingToTypeIdentifier($0) }) && (provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)) {
                    let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.plainText.identifier
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                        if let data, let text = String(data: data, encoding: .utf8) { Task { @MainActor in library.draft.body += (library.draft.body.isEmpty ? "" : "\n") + text } }
                    }
                } else {
                    guard let type = [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.tiff.identifier].first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { continue }
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in if let data { Task { @MainActor in library.pasteImage(data) } } }
                }
            }
            return !providers.isEmpty
        }
        .sheet(item: reader) { selection in LibraryReader(library: library, noteID: selection.id).onDisappear { DispatchQueue.main.async { focusedID = selection.id } } }
        .animation((reduceMotion || demoReduceMotion) ? nil : .easeOut(duration: 0.14), value: library.gallery)
        .onChange(of: readerID) { _, id in if let id { library.selectedID = id } }
    }
    private func noteButton(_ note: LibraryNote, gallery: Bool) -> some View {
        Button { library.selectedID = note.id; readerID = note.id } label: {
            Group {
                if gallery {
                    VStack(alignment: .leading, spacing: 12) {
                        LibraryThumbnail(note: note, repository: library.repository).frame(height: 164).frame(minWidth: 0, maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 6)).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        Text(note.displayTitle).font(Theme.body(14, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(spacing: 16) { LibraryThumbnail(note: note, repository: library.repository).frame(width: 58, height: 48).clipped(); Text(note.displayTitle).font(Theme.body(14)); Spacer() }.padding(.vertical, 12).frame(maxWidth: .infinity)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).focusable().focused($focusedID, equals: note.id)
        .onKeyPress(.return) { library.selectedID = note.id; readerID = note.id; return .handled }
        .onKeyPress(.space) { library.selectedID = note.id; readerID = note.id; return .handled }
        .onMoveCommand { direction in
            guard let index = library.results.firstIndex(where: { $0.id == note.id }) else { return }
            let columns = library.gallery ? max(1, Int(((NSApp.keyWindow?.frame.width ?? 1280) - 222) / 240)) : 1
            let delta = direction == .up ? -columns : direction == .down ? columns : direction == .left ? -1 : 1
            focusedID = library.results[max(0, min(library.results.count - 1, index + delta))].id
        }
        .accessibilityLabel("Open note: \(note.displayTitle)").contextMenu { LibraryNoteActions(library: library, note: note) }
    }
}
private struct LibraryReaderSelection: Identifiable { let id: String }
struct LibraryThumbnail: View {
    let note: LibraryNote
    let repository: DataRepository?
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Text(note.body.isEmpty ? (note.prompt.isEmpty ? "Saved reference" : note.prompt) : note.body).font(Theme.body(13)).lineSpacing(5).lineLimit(7).foregroundStyle(Theme.secondary).padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Theme.surface) }
        }.accessibilityHidden(true)
        .task(id: note.attachments.first(where: \.isImage)?.hash) {
            guard let a = note.attachments.first(where: \.isImage), let repository else { return }
            if let file = try? await Task.detached(priority: .utility, operation: { try LibraryMedia.thumbnail(a, repository: repository) }).value { image = NSImage(contentsOf: file) }
        }
    }
}
struct LibraryNoteActions: View {
    @ObservedObject var library: LibraryStore
    let note: LibraryNote
    var body: some View {
        Button("Copy exact text") { library.copy(note.body) }
        Button("Copy reusable prompt") { library.copy(note.reusableText) }
        Button(note.favorite ? "Remove favorite" : "Favorite") { library.mutate(note) { $0.favorite.toggle() } }
        Button(note.unreviewed ? "Mark reviewed" : "Mark unreviewed") { library.mutate(note) { $0.unreviewed.toggle() } }
        Menu("Move to folder") {
            Button("Unfiled") { library.mutate(note) { $0.folder = nil } }
            ForEach(library.folders, id: \.self) { folder in Button(folder) { library.mutate(note) { $0.folder = folder } } }
        }.disabled(library.saving)
        Button("Export Markdown & attachments…") { library.export(note) }
        Divider()
        if note.trashedAt != nil || note.archived { Button("Restore to Library") { library.mutate(note) { $0.trashedAt = nil; $0.archived = false } } }
        else { Button("Archive") { library.mutate(note) { $0.archived = true } } }
        if note.trashedAt == nil { Button("Move to Trash", role: .destructive) { library.mutate(note) { $0.trashedAt = Date() } } }
    }
}
