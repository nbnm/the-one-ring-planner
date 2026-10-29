import SwiftUI
import RingCore

enum MeetingSpeakerStyle {
    static func color(_ value: MeetingSpeakerColor) -> Color {
        switch value {
        case .pink: return Theme.adaptive(Theme.rgb(0xBC397A), Theme.rgb(0xF18AB8))
        case .blue: return Theme.adaptive(Theme.rgb(0x3C6FA3), Theme.rgb(0x8BB8E9))
        case .green: return Theme.green
        case .orange: return Theme.adaptive(Theme.rgb(0xA65F25), Theme.rgb(0xE6AC72))
        case .purple: return Theme.adaptive(Theme.rgb(0x7755A0), Theme.rgb(0xBCA0E0))
        case .teal: return Theme.adaptive(Theme.rgb(0x267C7A), Theme.rgb(0x81C5C0))
        case .neutral: return Theme.secondary
        }
    }
    static let myself = color(.pink)
}

struct MeetingSpeakersView: View {
    @ObservedObject var meetings: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var error: String?
    @State private var unlabelledOnly = false
    private var record: MeetingRecording? { meetings.selected }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Speakers").font(Theme.display(27))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let record {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(record.availableSpeakerAliases) { alias in MeetingAliasChip(meetings: meetings, record: record, alias: alias) }
                    }
                }.frame(height: 32)
                HStack {
                    TextField("New alias…", text: $newName).accessibilityLabel("New speaker alias").onSubmit { addAlias(record) }
                    Button("Add alias") { addAlias(record) }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meetings.busy)
                }
                HStack {
                    Text("Assign Me to your labels. Your speaking time is pink.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Toggle("Unlabelled only", isOn: $unlabelledOnly).toggleStyle(.checkbox).font(Theme.body(11))
                }
                DividerLine()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(record.availableSpeakerIDs.enumerated()), id: \.element) { index, speaker in
                            if !unlabelledOnly || record.speakerAlias(for: speaker) == nil {
                                speakerRow(record, speaker: speaker, index: index)
                                DividerLine().padding(.vertical, 10)
                            }
                        }
                    }
                }
                if let error { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert) }
            }
        }.padding(24).frame(width: 680, height: 560).background(Theme.background).foregroundStyle(Theme.text)
    }
    private func addAlias(_ record: MeetingRecording) {
        var updated = record
        do {
            _ = try updated.addSpeakerAlias(name: newName)
            meetings.edit(record.id) { $0 = updated }; newName = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func speakerRow(_ record: MeetingRecording, speaker: String, index: Int) -> some View {
        let first = MeetingNavigation.ordered(record.segments).first { $0.speakerID == speaker }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Circle().fill(MeetingSpeakerStyle.color(record.speakerColor(speaker))).frame(width: 7, height: 7).accessibilityHidden(true)
                Text("Speaker \(index + 1)").font(Theme.body(12, weight: .semibold)).frame(width: 80, alignment: .leading).help(speaker)
                if let first {
                    Button(MeetingTaskImport.timestamp(first.start)) { meetings.navigate(record, segmentID: first.id) }.buttonStyle(.plain).font(Theme.body(11)).monospacedDigit().foregroundStyle(Theme.gold).help("Listen to identify this speaker")
                }
                Spacer()
                Picker("Alias", selection: Binding(get: { record.speakerAlias(for: speaker)?.id ?? "" }, set: { alias in
                    meetings.edit(record.id) { $0.assignSpeaker(speaker, aliasID: alias.isEmpty ? nil : alias) }
                })) {
                    Text("No alias").tag("")
                    ForEach(record.availableSpeakerAliases) { Text($0.displayName).tag($0.id) }
                }.labelsHidden().frame(width: 200).accessibilityLabel("Alias for speaker \(index + 1)").disabled(meetings.busy)
            }
            if let first { Text(first.text).font(Theme.body(11)).foregroundStyle(Theme.secondary).lineLimit(2).textSelection(.enabled) }
        }.padding(.vertical, 3)
    }
}

private struct MeetingAliasChip: View {
    @ObservedObject var meetings: MeetingStore
    let record: MeetingRecording
    let alias: MeetingSpeakerAlias
    @State private var editing = false
    @State private var draft = ""
    @State private var error: String?
    var body: some View {
        Button { draft = alias.name; error = nil; editing = true } label: {
            HStack(spacing: 5) {
                if alias.isMe { Circle().fill(MeetingSpeakerStyle.myself).frame(width: 6, height: 6) }
                Text(alias.displayName).lineLimit(1)
                Image(systemName: "pencil").font(.system(size: 9))
            }.font(Theme.body(11)).padding(.horizontal, 9).padding(.vertical, 6)
                .background(Theme.line.opacity(0.4), in: Capsule()).foregroundStyle(alias.isMe ? MeetingSpeakerStyle.myself : Theme.text)
        }.buttonStyle(.plain).help("Rename alias").accessibilityLabel("Rename alias \(alias.displayName)").disabled(meetings.busy)
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename alias").font(Theme.body(13, weight: .semibold))
                TextField("Name", text: $draft).onSubmit { save() }.accessibilityLabel("Alias name")
                if let error { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert) }
                HStack { Button("Cancel") { editing = false }; Spacer(); Button("Save") { save() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(18).frame(width: 270)
        }
    }
    private func save() {
        var updated = record
        do { try updated.renameSpeakerAlias(alias.id, name: draft); meetings.edit(record.id) { $0 = updated }; editing = false }
        catch { self.error = error.localizedDescription }
    }
}
