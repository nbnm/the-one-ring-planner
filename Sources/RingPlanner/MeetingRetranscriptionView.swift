import SwiftUI
import RingCore

struct MeetingRetranscriptionView: View {
    @ObservedObject var meetings: MeetingStore
    @Environment(\.dismiss) private var dismiss
    private var options: MeetingTranscriptionOptions { .resolve(model: meetings.retranscriptionModel, speakerLabels: true) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Re-transcribe meeting").font(Theme.display(27))
            Text("Choose a model for a fresh attempt. Previous versions stay available.").font(Theme.body(12)).foregroundStyle(Theme.secondary)
            HStack {
                TextField("Audio model alias", text: $meetings.retranscriptionModel).accessibilityLabel("Re-transcription model")
                Menu("Available models") {
                    ForEach(meetings.models.filter(\.isAudioCandidate)) { model in Button(model.id) { meetings.retranscriptionModel = model.id } }
                }.disabled(meetings.models.filter(\.isAudioCandidate).isEmpty)
            }
            HStack {
                Button(meetings.discovering ? "Checking…" : "Check models") { meetings.discoverModels() }.disabled(meetings.discovering || meetings.demo)
                Text("Applies to this meeting.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
            }
            Picker("Language", selection: $meetings.retranscriptionLanguage) { ForEach(MeetingLanguage.allCases, id: \.self) { Text($0.title).tag($0) } }
            Toggle("Speaker separation", isOn: Binding(get: { options.speakerSeparation && meetings.retranscriptionSpeakerLabels }, set: { meetings.retranscriptionSpeakerLabels = $0 })).disabled(!options.speakerSeparation)
            if let note = options.note { Text(note).font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            if options.speakerSeparation { Text("New speaker labels need aliases assigned again.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            if let message = meetings.discoveryMessage { Text(message).font(Theme.body(11)).foregroundStyle(Theme.secondary).lineLimit(3) }
            DividerLine()
            Text(meetings.demo ? "Example mode. No recording is uploaded." : "Audio goes to \(meetings.gateway) using \(meetings.retranscriptionModel). The transcript is analyzed by \(meetings.ai.connection.model). Imported tasks stay in Inbox; review new proposals before adding them.")
                .font(Theme.body(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = meetings.retranscriptionError { Text(error).font(Theme.body(12)).foregroundStyle(Theme.alert) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start new transcript") { meetings.startRetranscription() }.buttonStyle(GoldButton())
                    .disabled(meetings.retranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meetings.busy)
            }
        }.padding(28).frame(width: 580)
    }
}

struct MeetingTranscriptVersionsView: View {
    @ObservedObject var meetings: MeetingStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Transcript versions").font(Theme.display(27)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            if let record = meetings.selected {
                Text("Current: \(record.transcriptModel)").font(Theme.body(13, weight: .semibold))
                Text("Switching keeps the current transcript as another version.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach((record.transcriptVersions ?? []).sorted { $0.savedAt > $1.savedAt }) { version in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(version.model).font(Theme.body(14, weight: .semibold))
                                    Text("\(version.savedAt.formatted(date: .abbreviated, time: .standard)) · \(version.segments.count) passages\(version.state == .interrupted ? " · Partial" : "")").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Button("Use transcript") { meetings.restoreTranscript(version.id) }.disabled(meetings.busy)
                            }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
        }.padding(24).frame(width: 620, height: 420)
    }
}
