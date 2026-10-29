import SwiftUI
import RingCore

struct MeetingTranscriptView: View {
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var playback: MeetingPlayback
    let record: MeetingRecording
    @State private var query = ""
    @State private var speaker = ""
    @State private var following = false
    @State private var filtered: [MeetingSegment] = []
    @State private var resultIndex = 0
    private var activeIDs: Set<String> { playback.recordingID == record.id ? MeetingNavigation.activeIDs(at: playback.position, segments: record.segments) : [] }
    private var currentID: String? { activeIDs.sorted().first }
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                    TextField("Find a topic, word or phrase…", text: $query).textFieldStyle(.plain).accessibilityLabel("Search meeting transcript")
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear transcript search") }
                    Picker("Speaker", selection: $speaker) {
                        Text("All speakers").tag("")
                        ForEach(record.speakerGroups) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 180)
                }.font(Theme.body(12)).padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line)).padding(.horizontal, 24)
                HStack(spacing: 10) {
                    Text(query.isEmpty && speaker.isEmpty ? "\(filtered.count) passages · click a timecode to listen" : "\(filtered.count) matching passages").font(Theme.body(10)).foregroundStyle(Theme.secondary)
                    if !query.isEmpty && !filtered.isEmpty {
                        Button { moveMatch(-1, proxy: proxy) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous transcript match")
                        Text("\(resultIndex + 1) / \(filtered.count)").font(Theme.body(10)).monospacedDigit()
                        Button { moveMatch(1, proxy: proxy) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next transcript match")
                    }
                    Spacer()
                    Toggle("Follow audio", isOn: $following).toggleStyle(.checkbox).font(Theme.body(10)).disabled(!query.isEmpty || !speaker.isEmpty)
                }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let notice = record.transcriptionNotice { Text(notice).font(Theme.body(11)).foregroundStyle(Theme.secondary) }
                        if record.segments.isEmpty { Text("Transcribe the recording from Summary to see the conversation here.").font(Theme.body(13)).foregroundStyle(Theme.secondary) }
                        else if filtered.isEmpty { Text("No matching passages. Try another phrase or speaker.").font(Theme.body(13)).foregroundStyle(Theme.secondary) }
                        ForEach(filtered) { segment in
                            MeetingTranscriptRow(record: record, segment: segment, query: query, active: activeIDs.contains(segment.id), matched: !query.isEmpty && filtered.indices.contains(resultIndex) && filtered[resultIndex].id == segment.id) {
                                meetings.navigate(record, segmentID: segment.id)
                            }.id(segment.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 12)
                }
            }
            .onAppear { refresh(); scrollToTarget(proxy) }
            .onChange(of: record.id) { _, _ in query = ""; speaker = ""; refresh(); scrollToTarget(proxy) }
            .onChange(of: record.segments) { _, _ in refresh() }
            .onChange(of: record.speakerAliasAssignments) { _, _ in refresh() }
            .onChange(of: record.speakerAliases) { _, _ in refresh() }
            .onChange(of: query) { _, _ in if !query.isEmpty { following = false }; refresh(); if let first = filtered.first { proxy.scrollTo(first.id, anchor: .top) } }
            .onChange(of: speaker) { _, _ in if !speaker.isEmpty { following = false }; refresh() }
            .onChange(of: meetings.transcriptNavigationID) { _, _ in scrollToTarget(proxy) }
            .onChange(of: currentID) { _, id in if following, let id { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: following) { _, value in if value, let id = currentID { proxy.scrollTo(id, anchor: .center) } }
        }
    }
    private func refresh() {
        if !speaker.isEmpty && !record.speakerGroups.contains(where: { $0.id == speaker }) { speaker = "" }
        filtered = record.matchingTranscript(query: query, groupID: speaker); resultIndex = 0
    }
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        let target = meetings.transcriptTargetID ?? MeetingNavigation.nearest(at: playback.position, segments: record.segments)?.id
        guard let target else { return }
        query = ""; speaker = ""; refresh()
        Task { @MainActor in await Task.yield(); proxy.scrollTo(target, anchor: .center) }
    }
    private func moveMatch(_ delta: Int, proxy: ScrollViewProxy) {
        guard !filtered.isEmpty else { return }
        resultIndex = (resultIndex + delta + filtered.count) % filtered.count
        proxy.scrollTo(filtered[resultIndex].id, anchor: .center)
    }
}

private struct MeetingTranscriptRow: View {
    let record: MeetingRecording
    let segment: MeetingSegment
    let query: String
    let active: Bool
    let matched: Bool
    let play: () -> Void
    private var color: Color { MeetingSpeakerStyle.color(record.speakerColor(segment.speakerID)) }
    private var highlighted: AttributedString {
        var value = AttributedString(segment.text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            var start = segment.text.startIndex
            while start < segment.text.endIndex, let range = segment.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: start..<segment.text.endIndex) {
                if let a = AttributedString.Index(range.lowerBound, within: value), let b = AttributedString.Index(range.upperBound, within: value) { value[a..<b].backgroundColor = Theme.gold.opacity(0.3) }
                start = range.upperBound
            }
        }
        return value
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MeetingTaskImport.timestamp(segment.start)).font(Theme.body(12, weight: .semibold))
                    Text("– " + MeetingTaskImport.timestamp(segment.end)).font(Theme.body(10)).foregroundStyle(Theme.secondary)
                    if active { Label("Here", systemImage: "speaker.wave.2.fill").font(Theme.body(9)) }
                }.monospacedDigit().foregroundStyle(record.isMySpeaker(segment.speakerID) ? color : Theme.gold).frame(width: 70, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Play from \(MeetingTaskImport.timestamp(segment.start))").accessibilityLabel("Play passage from \(MeetingTaskImport.timestamp(segment.start)) to \(MeetingTaskImport.timestamp(segment.end))")
            VStack(alignment: .leading, spacing: 6) {
                Text(record.speakerName(segment.speakerID)).font(Theme.body(11, weight: .semibold)).foregroundStyle(color)
                Text(highlighted).font(Theme.body(14)).textSelection(.enabled).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12).background(active ? (record.isMySpeaker(segment.speakerID) ? color.opacity(0.12) : Theme.goldFill) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(record.isMySpeaker(segment.speakerID) ? color : active ? Theme.gold : matched ? Theme.secondary : Color.clear).frame(width: 2) }
    }
}
