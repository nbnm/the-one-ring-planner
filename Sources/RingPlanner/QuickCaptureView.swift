import SwiftUI

struct CaptureView: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var speech: SpeechCapture
    @FocusState private var focused: Bool
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) { RingMark(size: 32); SectionLabel(title: "Catch a thought"); Spacer(); Text("⌃⌥Space").font(Theme.body(10)).foregroundStyle(Theme.secondary) }
            Text("What’s on your mind?").font(Theme.display(29))
            TextEditor(text: $store.inboxDraft).font(Theme.body(16)).scrollContentBackground(.hidden).padding(10).frame(height: 120).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Theme.gold.opacity(0.7) : Theme.line)).focused($focused).disabled(speech.isBusy).accessibilityLabel("Task capture text")
            HStack {
                Button {
                    if speech.isBusy { speech.finish() }
                    else {
                        let prefix = store.inboxDraft
                        Task { await speech.start(locale: store.settings.speechLocale, onTranscript: { value in
                            if !value.isEmpty { store.inboxDraft = prefix + (prefix.isEmpty ? "" : "\n") + value }
                        }, onFinished: { _ in AppActions.reviewCapture(store.inboxDraft) }) }
                    }
                } label: { Label(speech.isBusy ? "Stop recording" : "Record a thought", systemImage: speech.isBusy ? "stop.circle.fill" : "mic").foregroundStyle(speech.isBusy ? Theme.alert : Theme.secondary) }.buttonStyle(.plain).font(Theme.body(12))
                Spacer()
                Text(speech.isStarting ? speech.status : (speech.isFinishing ? "Finishing transcript…" : (speech.recording ? "● Recording · up to 60s" : "On-device speech"))).font(Theme.body(10)).foregroundStyle(speech.isBusy ? Theme.alert : Theme.secondary)
            }
            if let message = speech.message { Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert) }
            if let error = store.error { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert).textSelection(.enabled) }
            DividerLine()
            HStack {
                Text("Clean up, review, then add to Inbox.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Cancel") { speech.stop(); close() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button("Review tasks") { AppActions.reviewCapture(store.inboxDraft) }.buttonStyle(GoldButton()).keyboardShortcut(.return, modifiers: .command).disabled(speech.isBusy || store.inboxDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 580).background(Theme.background).foregroundStyle(Theme.text)
        .onAppear { focused = true }
        .onDisappear { speech.stop() }
    }
}
