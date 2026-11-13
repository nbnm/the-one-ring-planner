import SwiftUI
import RingCore

@MainActor final class CaptureReview: ObservableObject, Identifiable {
    let id = UUID()
    let source: String
    let originalTask: PlannerTask?
    let files: [URL]
    let demo: Bool
    @Published var preparedAttachments: [LibraryPreparedAttachment] = []
    @Published var assetsReady = false
    var attachments: [LibraryAttachment] {
        var all = originalTask?.attachments ?? []
        for a in preparedAttachments.map(\.attachment) where !all.contains(where: { $0.hash == a.hash }) { all.append(a) }
        return all
    }
    @Published var drafts: [CaptureDraft] = []
    @Published var processing = false
    @Published var message: String?
    private var generation: Task<Void, Never>?
    init(source: String, originalTask: PlannerTask? = nil, files: [URL] = [], demo: Bool = false) { self.source = source; self.originalTask = originalTask; self.files = files; self.demo = demo }
    func process(settings: CaptureAISettings, knownTags: [String], repository: DataRepository?) {
        guard !processing else { return }
        processing = true; message = nil
        generation = Task { [weak self] in
            guard let self else { return }
            do {
                guard let repository else { throw LibraryError.invalid("Task storage is unavailable. Your capture is retained.") }
                let selectedFiles = files
                let prepared = try await Task.detached { try LibraryMedia.prepare(selectedFiles, repository: repository) }.value
                guard !Task.isCancelled else { return }
                var seen = Set<String>()
                preparedAttachments = prepared.filter { seen.insert($0.attachment.hash).inserted }
                assetsReady = true
                if demo {
                    drafts = [CaptureDraft(title: source.isEmpty ? "Review the Fellowship reference" : String(source.prefix(160)), tags: ["Fellowship"])]; processing = false; return
                }
                let imageFiles = selectedFiles + (originalTask?.attachments ?? []).filter(\.isImage).map { repository.root.appendingPathComponent($0.path) }
                let images = try await Task.detached { try LibraryMedia.aiImages(imageFiles.filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }) }.value
                let key = try await settings.apiKey()
                let result = try await LiteLLMClient().process(source, images: images, knownTags: knownTags, connection: settings.connection, apiKey: key)
                guard !Task.isCancelled else { return }
                drafts = result.enumerated().map { index, draft in
                    var draft = draft
                    if let originalTask = self.originalTask {
                        if draft.tags.isEmpty { draft.tags = originalTask.tags }
                        if index == 0 && draft.notes.isEmpty { draft.notes = originalTask.notes }
                    }
                    return draft
                }
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
                if drafts.isEmpty { drafts = [CaptureDraft(title: String(source.prefix(160)))] }
            }
            processing = false
        }
    }
    func cancel() { generation?.cancel(); generation = nil; processing = false }
    deinit { generation?.cancel() }
}

struct CaptureReviewSheet: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var review: CaptureReview
    private var selected: [CaptureDraft] { review.drafts.filter(\.included) }
    private var valid: Bool { !review.processing && review.assetsReady && !selected.isEmpty && selected.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).count <= 160 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "From thought to task")
                Text(review.processing ? "Finding the next actions…" : "A little clarity, before you begin.").font(Theme.display(28))
                Text(review.originalTask == nil ? "Review the titles, details and tags. Only the tasks you select will be added to Inbox." : "The first selected task updates the original Inbox item. Additional selected tasks are added separately.").font(Theme.body(12)).foregroundStyle(Theme.secondary).lineSpacing(4)
            }.padding(26)
            DividerLine()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if review.processing {
                        HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Turning your capture into concise tasks with LiteLLM…").font(Theme.body(12)) }.padding(.vertical, 28)
                    }
                    if let message = review.message {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(message).font(Theme.body(12)).foregroundStyle(Theme.alert).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Retry cleanup") { review.process(settings: store.captureAI, knownTags: store.knownTags, repository: store.repository) }.disabled(review.processing)
                                Button("Connection settings") { review.cancel(); dismiss(); store.page = .settings }
                            }.font(Theme.body(11)).buttonStyle(.plain).foregroundStyle(Theme.gold)
                        }
                    }
                    if !review.files.isEmpty { CaptureAttachmentStrip(files: review.files, remove: { _ in }).disabled(true) }
                    ForEach($review.drafts) { $draft in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                Toggle("Include task", isOn: $draft.included).labelsHidden().toggleStyle(.checkbox).accessibilityLabel("Include \(draft.title.isEmpty ? "new task" : draft.title)")
                                TextField("Actionable task title", text: $draft.title, axis: .vertical).font(Theme.body(15, weight: .semibold)).lineLimit(1...3).textFieldStyle(.plain).accessibilityLabel("Proposed task title")
                            }
                            TextField("Supporting details (optional)", text: $draft.notes, axis: .vertical).lineLimit(2...5).font(Theme.body(12)).textFieldStyle(.roundedBorder).accessibilityLabel("Task details")
                            TaskAreaPicker(tags: $draft.tags)
                    TaskTagEditor(tags: $draft.tags, knownTags: store.knownTags)
                            if draft.title.count > 160 { Text("Keep the title under 160 characters; move extra detail to notes.").font(Theme.body(11)).foregroundStyle(Theme.alert) }
                        }.opacity(draft.included ? 1 : 0.5)
                        DividerLine()
                    }
                    if !review.processing {
                        Button { review.drafts.append(CaptureDraft()) } label: { Label("Add another task", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(Theme.gold).font(Theme.body(12)).disabled(review.drafts.count >= 12)
                    }
                    DisclosureGroup("Original capture") { Text(review.source).font(Theme.body(12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }.font(Theme.body(11)).foregroundStyle(Theme.secondary)
                }.padding(26)
            }.frame(maxHeight: .infinity)
            DividerLine()
            HStack {
                Button("Back to capture") { review.cancel(); dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Spacer()
                Text("Nothing saved yet").font(Theme.body(10)).foregroundStyle(Theme.secondary)
                Button(review.originalTask == nil ? (selected.count == 1 ? "Add 1 task" : "Add \(selected.count) tasks") : "Confirm \(selected.count) task\(selected.count == 1 ? "" : "s")") {
                    if store.confirmCapture(review) { dismiss() }
                }.buttonStyle(GoldButton()).disabled(!valid).keyboardShortcut(.return, modifiers: .command)
            }.padding(22)
        }.frame(width: 660, height: 720).background(Theme.background).foregroundStyle(Theme.text)
            .onDisappear { review.cancel() }
    }
}
