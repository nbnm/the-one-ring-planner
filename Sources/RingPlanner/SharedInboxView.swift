import SwiftUI
import RingCore

struct InboxPage: View {
    @EnvironmentObject var store: PlannerStore
    @State private var query = ""
    @State private var archived = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(archived ? "Inbox archive" : "Inbox").font(Theme.display(32)); Spacer(); TextField("Search Inbox", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 300); Button { AppActions.capture() } label: { Label("Capture", systemImage: "plus") }.buttonStyle(GoldButton()) }
            HStack { Spacer(); Menu { Button(archived ? "Active Inbox" : "Archive") { archived.toggle() } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Inbox collections") }
            DividerLine()
            InboxContents(query: query, wide: true, archived: archived)
        }.padding(30).background(Theme.background)
    }
}
struct InboxContents: View {
    @EnvironmentObject var store: PlannerStore
    var query = ""
    var wide = false
    var archived = false
    private var entries: [InboxItem] {
        store.sharedInbox.items.filter { $0.route == nil && $0.archived == archived }.filter { query.isEmpty || [$0.title, $0.content, $0.tags.joined(separator: " "), $0.sourceURL].joined(separator: "\n").localizedCaseInsensitiveContains(query) }
    }
    private var legacyTasks: [PlannerTask] { (archived ? [] : store.inbox).filter { query.isEmpty || [$0.title,$0.notes,$0.tags.joined(separator: " ")].joined(separator: "\n").localizedCaseInsensitiveContains(query) } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty && legacyTasks.isEmpty { Text(query.isEmpty ? (archived ? "Archive is empty." : "Nothing waiting.") : "No matching items.").font(Theme.display(22)).foregroundStyle(Theme.secondary).padding(.vertical, 28) }
                ForEach(entries) { item in SharedInboxRow(item: item, wide: wide); DividerLine() }
                ForEach(legacyTasks) { task in InboxTaskRow(task: task); DividerLine() }
                if let error = store.sharedInbox.error { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert).textSelection(.enabled).padding(.vertical, 12) }
            }
        }
    }
}
struct SharedInboxRow: View {
    @EnvironmentObject var store: PlannerStore
    let item: InboxItem
    var wide = false
    private var voiceJob: TelegramInboundJob? { store.telegram.state.jobs.first { TelegramCapture.identity(botID: store.telegram.settings.botID ?? -1, updateID: $0.id) == item.id } }
    private var issue: String? { voiceJob?.lastError ?? store.sharedInbox.jobs.first { $0.itemID == item.id }?.lastError }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaskDragTitle(taskID: "inbox:" + item.id, title: item.title, fontSize: 13, lineSpacing: 3) { store.sharedInbox.selected = item }
            HStack(spacing: 5) {
                Image(systemName: item.suggestedKind == .task ? "checkmark.circle" : item.suggestedKind == .note ? "doc.text" : "sparkle")
                Text(item.awaitingTranscription ? "Transcribing…" : item.suggestedKind == .unknown ? (item.classification == nil && issue == nil ? "Sorting…" : "Unsorted") : "Suggested \(item.suggestedKind.rawValue.lowercased())")
                if !item.attachments.isEmpty { Text("· \(item.attachments.count) attached") }
            }.font(Theme.body(10)).foregroundStyle(Theme.secondary)
            if wide && item.content.count > 180 { Text(item.content).font(Theme.body(12)).lineLimit(2).foregroundStyle(Theme.secondary) }
            TaskTagsView(tags: item.tags)
            if !item.sourceURL.isEmpty { ReferenceLinksView(text: "", sourceURL: item.sourceURL) }
            HStack(spacing: 8) {
                Menu(item.archived ? "Restore" : "Move") { if item.archived { Button("Restore to Inbox") { store.sharedInbox.restore(item) } } else { InboxMoveActions(item: item) } }.disabled(!item.archived && item.awaitingTranscription).menuStyle(.borderlessButton).fixedSize().font(Theme.body(11)).foregroundStyle(Theme.gold).accessibilityLabel("Move Inbox item: \(item.title)")
                Spacer(minLength: 4)
                CopyTextIcon(text: item.content, label: "Copy Inbox text: \(item.title)")
                Button { store.sharedInbox.selected = item } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).foregroundStyle(Theme.secondary).accessibilityLabel("Edit Inbox item: \(item.title)")
                Menu {
                    if item.archived { Button("Restore to Inbox") { store.sharedInbox.restore(item) } } else { Button("Retry AI suggestion") { store.sharedInbox.retry(item) }; Button("Archive") { store.sharedInbox.archive(item) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Inbox item actions")
            }
            if let issue {
                HStack { Text(voiceJob != nil ? "Telegram capture needs attention" : "AI suggestion unavailable"); if voiceJob != nil { Button("Retry capture") { store.telegram.retryCaptures() } } }.font(Theme.body(10)).foregroundStyle(Theme.alert)
                DisclosureGroup("Error details") { Text(issue).font(Theme.body(10)).textSelection(.enabled) }
            }
        }.padding(.vertical, 14).contentShape(Rectangle()).accessibilityElement(children: .contain)
    }
}
struct InboxMoveActions: View {
    @EnvironmentObject var store: PlannerStore
    let item: InboxItem
    var body: some View {
        Button("Library · Note", systemImage: "books.vertical") { store.placeInboxInLibrary(item) }
        Divider()
        ForEach(Quadrant.allCases) { quadrant in Button("Q\(quadrant.rawValue) · \(quadrant.title)") { store.placeInbox(item, in: quadrant) } }
    }
}
struct InboxItemReader: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let original: InboxItem
    @State private var title: String
    @State private var tags: [String]
    @State private var saving = false
    init(item: InboxItem) { original = item; _title = State(initialValue: item.title); _tags = State(initialValue: item.tags) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Inbox item").font(Theme.display(26)); Spacer(); CopyTextIcon(text: original.content); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            TextField("Title", text: $title).font(Theme.body(16, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(original.content).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    ReferenceLinksView(text: original.content, sourceURL: original.sourceURL)
                    if !original.attachments.isEmpty { TaskImageAttachments(attachments: original.attachments, repository: store.repository) }
                    TaskAreaPicker(tags: $tags)
                    TaskTagEditor(tags: $tags, knownTags: Array(Set(store.knownTags + store.sharedInbox.active.flatMap(\.tags))).sorted())
                }
            }
            HStack {
                Text(original.suggestedKind == .unknown ? "Choose a destination from Inbox" : "Suggested \(original.suggestedKind.rawValue.lowercased())").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Save details") {
                    saving = true
                    var draft = original; draft.titleOverride = title; draft.tagsOverride = tags; draft.revision += 1
                    Task { if await store.sharedInbox.saveEdit(draft, expectedRevision: original.revision) { dismiss() }; saving = false }
                }.buttonStyle(GoldButton()).disabled(saving || title.isEmpty || title.count > 512)
            }
            if let error = store.sharedInbox.error { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert) }
        }.padding(26).frame(width: 760, height: 600).background(Theme.background)
    }
}
