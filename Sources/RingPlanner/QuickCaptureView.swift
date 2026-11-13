import SwiftUI
import RingCore

struct CaptureView: View {
    @EnvironmentObject var store: PlannerStore
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) { RingMark(size: 32); SectionLabel(title: "Catch a thought"); Spacer(); Text("⌃⌥Space").font(Theme.body(10)).foregroundStyle(Theme.secondary) }
            Picker("Capture destination", selection: $store.captureDestination) { ForEach(CaptureDestination.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 180).accessibilityLabel("Inbox, Task or Note capture")
            if store.captureDestination == .note { LibraryCaptureFields(library: store.library, close: close) }
            else if store.captureDestination == .inbox { SharedInboxCaptureFields(assets: store.taskCapture, close: close) }
            else { TaskCaptureFields(assets: store.taskCapture, close: close) }
        }.padding(28).frame(width: 600).background(Theme.background).foregroundStyle(Theme.text).tint(Theme.gold)
    }
}
struct TaskCaptureFields: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var assets: TaskCaptureAssets
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What’s on your mind?").font(Theme.display(29))
            LibraryTextEditor(text: $store.inboxDraft, label: "Task capture text", initialFocus: true, onFiles: assets.addFiles, onImage: assets.pasteImage).frame(height: 170).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            CaptureAttachmentStrip(files: assets.files) { file in assets.files.removeAll { $0 == file } }
            if let error = assets.error { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert) }
            HStack {
                Button("Attach images…") { assets.chooseFiles() }.buttonStyle(QuietButton())
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(assets.preparing > 0 ? "Adding images…" : "Review tasks") { AppActions.reviewCapture(store.inboxDraft) }.buttonStyle(GoldButton()).keyboardShortcut(.return, modifiers: .command).disabled(assets.preparing > 0 || (store.inboxDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && assets.files.isEmpty))
            }
            Text("Titles and tags are suggested with your saved AI connection.").font(Theme.body(10)).foregroundStyle(Theme.secondary)
        }
    }
}

struct LibraryCaptureFields: View {
    @ObservedObject var library: LibraryStore
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep something useful").font(Theme.display(27))
            LibraryFolderPicker(folders: library.folders, folder: $library.folder, allowAll: true)
            LibraryTextEditor(text: $library.draft.body, label: "Note capture text", initialFocus: true, onFiles: library.addFiles, onImage: library.pasteImage)
                .frame(height: 170).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
            CaptureAttachmentStrip(files: library.draft.files) { file in library.draft.files.removeAll { $0 == file } }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup("Title, prompt & source (optional)") {
                        TextField("Title", text: $library.draft.title)
                        TextField("Source URL", text: $library.draft.sourceURL)
                        TextField("Comments", text: $library.draft.comments, axis: .vertical)
                        LibraryTextEditor(text: $library.draft.prompt, label: "Exact reusable prompt").frame(height: 90).background(Theme.surface)
                    }
                }.font(Theme.body(12))
            }.frame(maxHeight: 125)
            if let error = library.error { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert).textSelection(.enabled).lineLimit(3) }
            HStack {
                Button("Attach…") { library.chooseFiles() }.buttonStyle(QuietButton())
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(library.saving ? "Saving…" : (library.preparingAttachments > 0 ? "Adding files…" : "Save note")) { Task { if await library.saveDraft() { close() } } }.buttonStyle(GoldButton()).keyboardShortcut(.return, modifiers: .command).disabled(library.saving || library.preparingAttachments > 0 || !library.draft.hasContent)
            }
        }
    }
}

struct SharedInboxCaptureFields: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var assets: TaskCaptureAssets
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep it in Inbox").font(Theme.display(29))
            LibraryTextEditor(text: $store.inboxDraft, label: "Inbox capture text", initialFocus: true, onFiles: assets.addFiles, onImage: assets.pasteImage).frame(height: 170).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            CaptureAttachmentStrip(files: assets.files) { file in assets.files.removeAll { $0 == file } }
            if let error = assets.error ?? store.sharedInbox.error { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert) }
            HStack {
                Button("Attach…") { assets.chooseFiles() }.buttonStyle(QuietButton())
                Spacer(); Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(store.sharedInbox.saving ? "Saving…" : "Save to Inbox") { Task { if await store.captureIntoInbox() { close() } } }.buttonStyle(GoldButton()).keyboardShortcut(.return, modifiers: .command).disabled(assets.preparing > 0 || store.sharedInbox.saving || (store.inboxDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && assets.files.isEmpty))
            }
            Text("Task or note? AI suggests. You choose where it belongs.").font(Theme.body(10)).foregroundStyle(Theme.secondary)
        }
    }
}
