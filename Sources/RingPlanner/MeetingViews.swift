import SwiftUI
import RingCore

enum EyeArtwork {
    static let image: NSImage? = {
        let url = Bundle.main.url(forResource: "EyeOfSauron", withExtension: "png")
            ?? Bundle.module.url(forResource: "EyeOfSauron", withExtension: "png")
        return url.flatMap { NSImage(contentsOf: $0) }
    }()
    static let menuBarImage: NSImage? = {
        guard let image = image?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 26, height: 26 * image.size.height / image.size.width)
        image.isTemplate = false
        return image
    }()
}

struct EyeMark: View {
    var recording = false
    var body: some View {
        Group {
            if let image = EyeArtwork.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "eye.fill").resizable().scaledToFit().foregroundStyle(Theme.gold)
            }
        }
        .overlay(alignment: .topTrailing) {
            if recording { Circle().fill(Theme.calendarTask).frame(width: 7, height: 7).accessibilityHidden(true) }
        }
        .accessibilityLabel(recording ? "The Eye · recording" : "The Eye")
    }
}

struct MeetingPage: View {
    @ObservedObject var meetings: MeetingStore
    @State private var tab = "Summary"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                EyeMark(recording: meetings.activeID != nil).frame(width: 88, height: 56)
                Text("The Eye").font(Theme.display(30))
                Spacer()
                Button("Audio models") { meetings.showModels = true }.buttonStyle(QuietButton())
                Button { meetings.showSetup = true } label: { Label("Record meeting", systemImage: "record.circle") }.buttonStyle(GoldButton()).disabled(meetings.busy)
            }.padding(24)
            DividerLine()
            HStack(spacing: 0) {
                library.frame(width: 230)
                DividerLine().frame(width: 1).frame(maxHeight: .infinity).background(Theme.line)
                if let record = meetings.selected { detail(record) }
                else {
                    VStack(alignment: .leading, spacing: 18) {
                        EyeMark().frame(width: 160, height: 100)
                        Text("No recordings yet").font(Theme.display(28))
                        Text("Record, transcribe, and review tasks.").font(Theme.body(13)).foregroundStyle(Theme.secondary)
                        Button("Record a meeting") { meetings.showSetup = true }.buttonStyle(GoldButton())
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding(32)
                }
            }
        }
        .onChange(of: meetings.transcriptNavigationID) { _, _ in tab = "Transcript" }
        .sheet(isPresented: $meetings.showSetup) { MeetingSetupView(meetings: meetings) }
        .sheet(isPresented: $meetings.showModels) { MeetingModelSettings(meetings: meetings) }
        .sheet(isPresented: $meetings.showSpeakers) { MeetingSpeakersView(meetings: meetings) }
        .sheet(isPresented: $meetings.showRetranscription) { MeetingRetranscriptionView(meetings: meetings) }
        .sheet(isPresented: $meetings.showTranscriptVersions) { MeetingTranscriptVersionsView(meetings: meetings) }
        .sheet(isPresented: $meetings.showCloudConfirmation) { cloudConfirmation }
        .alert("Meeting needs attention", isPresented: Binding(get: { meetings.error != nil }, set: { if !$0 { meetings.error = nil } })) { Button("OK") { meetings.error = nil } } message: { Text(meetings.error ?? "") }
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Recordings · \(meetings.recordings.count)").padding(18)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(meetings.recordings) { record in
                        Button { if meetings.selectedID != record.id { meetings.selectedID = record.id } } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(record.title).font(Theme.body(13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(Theme.body(10)).foregroundStyle(Theme.secondary)
                                HStack { Image(systemName: record.state == .recording ? "record.circle.fill" : "waveform"); Text(record.state.rawValue.capitalized); Spacer(); Text(MeetingTaskImport.timestamp(record.duration)).monospacedDigit() }.font(Theme.body(10)).foregroundStyle(record.state == .recording ? Theme.calendarTask : Theme.secondary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(meetings.selectedID == record.id ? Theme.goldFill : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8)
            }
        }.background(Theme.sidebar.opacity(0.4))
    }
    private func detail(_ record: MeetingRecording) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Meeting title", text: Binding(get: { record.title }, set: { value in meetings.edit(record.id) { $0.title = String(value.prefix(160)) } })).font(Theme.display(25)).textFieldStyle(.plain).disabled(meetings.busy)
                Text("\(record.source.title) · \(record.language.title) · \(MeetingTaskImport.timestamp(record.duration))\(record.audioConfiguration != nil && !record.segments.isEmpty ? " · " + record.transcriptModel : "")").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                if meetings.activeID == record.id { activeRecording }
                else {
                    HStack(spacing: 10) {
                        if !record.segments.isEmpty { Button("Speakers…") { meetings.showSpeakers = true }.disabled(meetings.busy) }
                        Menu("More") {
                            Button("Re-transcribe…") { meetings.requestRetranscription() }.disabled(meetings.busy)
                            if !(record.transcriptVersions ?? []).isEmpty {
                                Button("Transcript versions…") { meetings.showTranscriptVersions = true }
                            }
                            Divider()
                            Button("Show recording files") { meetings.reveal(record) }
                            Button("Export transcript…") { meetings.export(record) }.disabled(record.segments.isEmpty)
                            Divider()
                            Button("Move recording to Trash", role: .destructive) { meetings.trash(record) }.disabled(meetings.busy)
                        }
                        Spacer()
                        if meetings.workingID == record.id {
                            if let progress = meetings.processingProgress { ProgressView(value: progress).frame(width: 120).tint(Theme.gold).accessibilityLabel("Meeting processing progress") }
                            else { ProgressView().controlSize(.small) }
                            Button("Cancel") { meetings.cancelProcessing() }
                        }
                    }.font(Theme.body(11))
                }
                if meetings.activeID != record.id { MeetingPlaybackView(meetings: meetings, playback: meetings.playback, record: record) }
                if let draft = record.retranscription {
                    let failure = meetings.workingID == record.id ? nil : draft.content.lastError
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("New transcript · \(draft.model)").font(Theme.body(12, weight: .semibold))
                            Spacer()
                            if meetings.workingID != record.id { Button("Resume…") { meetings.resumeRetranscription() }.disabled(meetings.busy) }
                        }
                        Text(failure ?? "Current transcript remains available while the new version processes.").font(Theme.body(11)).foregroundStyle(failure == nil ? Theme.secondary : Theme.alert).lineLimit(3)
                    }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                }
                if let message = record.lastError { Text(message).font(Theme.body(12)).foregroundStyle(Theme.alert).textSelection(.enabled) }
                if !meetings.status.isEmpty { Text(meetings.status).font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            }.padding(24)
            DividerLine()
            if meetings.activeID != record.id {
                HStack(spacing: 10) {
                    Picker("View", selection: $tab) { Text("Summary").tag("Summary"); Text("Transcript").tag("Transcript"); Text("Tasks · \(record.suggestions.count)").tag("Tasks") }.pickerStyle(.segmented).frame(maxWidth: 360)
                    Spacer()
                }.padding(.horizontal, 24).padding(.vertical, 16)
                if tab == "Transcript" {
                    MeetingTranscriptView(meetings: meetings, playback: meetings.playback, record: record)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if tab == "Summary" { summary(record) }
                            else { suggestions(record) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(24).padding(.top, -8)
                    }
                }
            } else { Spacer() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var activeRecording: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Circle().fill(Theme.calendarTask).frame(width: 9, height: 9)
                Text(MeetingTaskImport.timestamp(meetings.recorder.elapsed)).font(Theme.display(32)).monospacedDigit()
                Text(meetings.recorder.status).font(Theme.body(12)).foregroundStyle(Theme.secondary)
                Spacer()
                Button(meetings.recorder.phase == .preparing ? "Cancel recording" : "Stop & save") { Task { await meetings.stopRecording() } }.buttonStyle(GoldButton()).disabled(meetings.finishing)
            }
            HStack(spacing: 30) {
                meter("Microphone", value: meetings.recorder.microphoneLevel, received: meetings.recorder.microphoneHeard)
                meter(meetings.selected?.source.usesSystemAudio == true ? "System audio" : "Call audio", value: meetings.recorder.callLevel, received: meetings.recorder.callHeard)
            }
            Text(meetings.demo ? "Example mode generates test tones. No audio is captured." : "Recording continues when this window closes. Headphones prevent speaker audio from being picked up again by the microphone.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
        }.padding(.vertical, 14)
    }
    private func meter(_ title: String, value: Float, received: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text("\(title) · \(received ? "receiving audio" : "waiting")").font(Theme.body(10)); ProgressView(value: Double(value)).tint(Theme.gold) }.frame(maxWidth: 230)
    }
    @ViewBuilder private func summary(_ record: MeetingRecording) -> some View {
        if !record.segments.isEmpty { MeetingTopicList(meetings: meetings, record: record); DividerLine() }
        if record.summaries.isEmpty {
            Text("From conversation to next steps").font(Theme.display(24))
            DetailNote("Transcription options", "Choose local transcription for one language, or send audio to a configured LiteLLM transcription model for automatic Russian/English detection and speaker labels. Then extract the summary, decisions and tasks.")
        } else {
            SectionLabel(title: "Summary")
            ForEach(Array(record.summaries.enumerated()), id: \.offset) { _, value in Text(value).font(Theme.body(14)).textSelection(.enabled).lineSpacing(5) }
            if !record.decisions.isEmpty { SectionLabel(title: "Decisions"); ForEach(Array(record.decisions.enumerated()), id: \.offset) { _, value in Label(value, systemImage: "checkmark").font(Theme.body(13)).textSelection(.enabled) } }
        }
        DividerLine()
        HStack(spacing: 12) {
            Button("Transcribe locally") { meetings.transcribeLocally() }.buttonStyle(QuietButton()).disabled(meetings.busy || record.language == .automatic || record.importedTaskCount > 0)
            Button(record.state == .interrupted && (!record.completedAudioParts.isEmpty || record.analysisProgress != nil) ? "Resume processing…" : !record.segments.isEmpty ? "Re-transcribe…" : "Process audio with LiteLLM…") {
                if record.state == .interrupted { meetings.resumeCloud() }
                else if !record.segments.isEmpty { meetings.requestRetranscription() } else { meetings.requestCloud(audio: true) }
            }.buttonStyle(GoldButton()).disabled(meetings.busy)
        }
        if record.language == .automatic { Text("For local transcription, select English or Russian below.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
        Picker("Recording language", selection: Binding(get: { record.language }, set: { value in meetings.edit(record.id) { $0.language = value } })) { ForEach(MeetingLanguage.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(maxWidth: 380).disabled(meetings.busy || record.importedTaskCount > 0)
        if !record.segments.isEmpty { Button("Extract tasks from transcript…") { meetings.requestCloud(audio: false) }.buttonStyle(QuietButton()).disabled(meetings.busy) }
        DetailNote("Processing details", "Cloud audio goes to \(meetings.gateway). Local transcription labels microphone/call channels; individual call speakers require a model that supports speaker separation.")
    }
    @ViewBuilder private func suggestions(_ record: MeetingRecording) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) { Text("Review the next steps").font(Theme.display(23)); Text("Edit the proposals, then choose which tasks to add to Inbox.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            Spacer()
            Button("Add selected to Inbox") { meetings.addSelectedTasks() }.buttonStyle(GoldButton()).disabled(meetings.busy || !record.suggestions.contains { $0.included && $0.savedTaskID == nil })
        }
        if record.suggestions.isEmpty { Text(record.state == .ready ? "No actionable commitments were found in this meeting." : "Extract tasks from a transcript in Summary to review them here.").foregroundStyle(Theme.secondary) }
        ForEach(MeetingTaskOwnership.allCases, id: \.self) { ownership in
            let tasks = record.suggestions.filter { record.ownership(of: $0) == ownership }
            if !tasks.isEmpty {
                HStack(spacing: 7) {
                    if ownership == .mine { Circle().fill(MeetingSpeakerStyle.myself).frame(width: 6, height: 6) }
                    Text("\(ownership == .mine ? "Mine" : ownership == .unassigned ? "Unassigned" : "Others") · \(tasks.count)")
                        .font(Theme.body(12, weight: .semibold)).foregroundStyle(ownership == .mine ? MeetingSpeakerStyle.myself : Theme.secondary)
                }
                ForEach(tasks) { proposal in MeetingSuggestionView(meetings: meetings, record: record, proposal: proposal) }
            }
        }
    }
    private var cloudConfirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(meetings.topicsOnly ? "Index discussion topics" : meetings.uploadAudio ? "Process meeting audio" : "Extract meeting tasks").font(Theme.display(27))
            Text("Destination: \(meetings.cloudGateway)").font(Theme.body(14, weight: .semibold))
            Text(meetings.uploadAudio ? "This sends the recorded audio to \(meetings.cloudAudioModel). Completed chunks are reused when resuming. The resulting transcript, meeting title, speaker names and project tags are sent to \(meetings.cloudTextModel) for a summary, discussion timeline and task proposals." : meetings.topicsOnly ? "This sends the transcript, meeting title, speaker names and project tags to \(meetings.cloudTextModel) to index discussion topics. It preserves existing summaries and tasks. Recorded audio stays on this Mac." : "This sends the transcript, meeting title, speaker names and project tags to \(meetings.cloudTextModel) for topics, summary and task proposals. Recorded audio stays on this Mac.").font(Theme.body(13)).lineSpacing(4)
            Text("Only tasks you approve will enter Inbox. Confirm that participants know about recording and that this gateway is appropriate for the conversation.").font(Theme.body(12)).foregroundStyle(Theme.secondary)
            HStack { Button("Cancel") { meetings.showCloudConfirmation = false }.keyboardShortcut(.cancelAction); Spacer(); Button("Send & process") { meetings.showCloudConfirmation = false; meetings.processCloud() }.buttonStyle(GoldButton()) }
        }.padding(28).frame(width: 530)
    }
}

private struct MeetingSuggestionView: View {
    @ObservedObject var meetings: MeetingStore
    let record: MeetingRecording
    let proposal: MeetingTaskSuggestion
    private func binding<T>(_ key: WritableKeyPath<MeetingTaskSuggestion, T>) -> Binding<T> {
        Binding(get: { proposal[keyPath: key] }, set: { value in meetings.edit(record.id) { item in if let i = item.suggestions.firstIndex(where: { $0.id == proposal.id }) { item.suggestions[i][keyPath: key] = value } } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Toggle("Include task", isOn: binding(\.included)).labelsHidden().disabled(meetings.busy || proposal.savedTaskID != nil).accessibilityLabel("Include \(proposal.title)")
                TextField("Task title", text: binding(\.title)).disabled(meetings.busy || proposal.savedTaskID != nil).font(Theme.body(14, weight: .semibold))
                if proposal.savedTaskID != nil { Label("In Inbox", systemImage: "checkmark.circle").font(Theme.body(11)).foregroundStyle(Theme.green) }
            }
            TextField("Details", text: binding(\.notes), axis: .vertical).lineLimit(2...5).disabled(meetings.busy || proposal.savedTaskID != nil)
            HStack {
                TextField("Project tags, comma separated", text: Binding(get: { proposal.tags.joined(separator: ", ") }, set: { value in meetings.edit(record.id) { item in if let i = item.suggestions.firstIndex(where: { $0.id == proposal.id }) { item.suggestions[i].tags = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init) } } }))
                TextField("Explicit timing", text: binding(\.timing))
            }.disabled(meetings.busy || proposal.savedTaskID != nil)
            Picker("Owner", selection: Binding(get: { record.ownerGroup(for: proposal) }, set: { value in meetings.edit(record.id) { $0.assignTaskOwner(proposal.id, groupID: value) } })) {
                Text("Unassigned").tag("")
                ForEach(record.speakerGroups) { Text($0.name).tag($0.id) }
            }.frame(maxWidth: 400).disabled(meetings.busy || proposal.savedTaskID != nil)
            ForEach(record.segments.filter { proposal.evidenceIDs.contains($0.id) }) { segment in
                HStack(alignment: .top, spacing: 8) {
                    Button(MeetingTaskImport.timestamp(segment.start)) { meetings.navigate(record, segmentID: segment.id) }.buttonStyle(.plain).foregroundStyle(Theme.gold).help("Play evidence and open transcript")
                    Text("\(record.speakerName(segment.speakerID)): \(segment.text)").foregroundStyle(Theme.secondary).textSelection(.enabled)
                }.font(Theme.body(11))
            }
        }.padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

struct MeetingSetupView: View {
    @ObservedObject var meetings: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var language = MeetingLanguage.english
    @State private var source = MeetingAudioSource.systemAndMicrophone
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) { EyeMark().frame(width: 72, height: 50); Text("Record a meeting").font(Theme.display(28)) }
            TextField("Meeting title (optional)", text: $title)
            Picker("Audio source", selection: $source) { ForEach(MeetingAudioSource.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("Language", selection: $language) { ForEach(MeetingLanguage.allCases, id: \.self) { Text($0.title).tag($0) } }
            Text(meetings.demo ? "Example mode: generated audio only." : source.usesSystemAudio ? "Records all apps’ output directly from macOS. Only audio is saved. Use headphones to avoid microphone echo; pause other audio you don’t want included." : "Records the microphone and/or an app selected in the macOS picker. Audio is saved locally.").font(Theme.body(12)).foregroundStyle(Theme.secondary).lineSpacing(4)
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(meetings.demo ? "Start example recording" : "Start recording") { meetings.start(title: title, language: language, source: source) }.buttonStyle(GoldButton()) }
        }.padding(30).frame(width: 510)
    }
}

struct MeetingModelSettings: View {
    @ObservedObject var meetings: MeetingStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("The Eye · Audio models").font(Theme.display(27)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Gateway: \(meetings.gateway)\nSummary & tasks: \(meetings.ai.connection.model)").font(Theme.body(12)).foregroundStyle(Theme.secondary)
            TextField("Audio transcription model alias", text: $meetings.audioModel).accessibilityLabel("Meeting audio model alias")
            let options = MeetingTranscriptionOptions.resolve(model: meetings.audioModel, speakerLabels: true)
            Toggle("Speaker separation", isOn: Binding(get: { options.speakerSeparation && meetings.speakerLabels }, set: { meetings.speakerLabels = $0 })).disabled(!options.speakerSeparation)
            if let note = options.note { Text(note).font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            Text("Use a transcription alias from your gateway. Speaker separation needs diarized_json support. Ordinary chat models cannot be used as audio transcription aliases.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
            HStack { Button(meetings.discovering ? "Checking gateway…" : "Check available models") { meetings.discoverModels() }.disabled(meetings.discovering); if meetings.discovering { ProgressView().controlSize(.small) } }
            if let message = meetings.discoveryMessage { Text(message).font(Theme.body(12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if !meetings.models.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(meetings.models) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) { Text(model.id).font(Theme.body(12, weight: .semibold)).textSelection(.enabled); Text(model.description).font(Theme.body(10)).foregroundStyle(Theme.secondary) }
                                Spacer()
                                if model.isAudioCandidate { Button("Use alias") { meetings.audioModel = model.id; meetings.speakerLabels = model.isDiarizationCandidate } }
                            }
                        }
                    }.padding(12)
                }.frame(height: 220).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Checking the catalog sends no recording or transcript. The saved LiteLLM key is read from macOS Keychain.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
        }.padding(28).frame(width: 650)
    }
}

struct EyeMenuView: View {
    @ObservedObject var meetings: MeetingStore
    var open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { EyeMark(recording: meetings.activeID != nil).frame(width: 56, height: 36); Text("The Eye").font(Theme.display(24)); Spacer() }
            if meetings.activeID != nil {
                Text(meetings.recorder.status).font(Theme.body(12))
                Text(MeetingTaskImport.timestamp(meetings.recorder.elapsed)).font(Theme.display(30)).monospacedDigit()
                Button("Stop & save recording") { Task { await meetings.stopRecording() } }.buttonStyle(GoldButton()).disabled(meetings.finishing)
            }
            Button("Open recordings") { open() }.buttonStyle(.plain).font(Theme.body(12))
        }.padding(22).frame(width: 310).background(Theme.background).foregroundStyle(Theme.text)
    }
}
