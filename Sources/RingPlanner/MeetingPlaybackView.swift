import SwiftUI
import RingCore

struct MeetingPlaybackView: View {
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var playback: MeetingPlayback
    let record: MeetingRecording
    private var total: Double { playback.recordingID == record.id ? playback.duration : record.duration }
    private var position: Double { playback.recordingID == record.id ? playback.position : 0 }
    @State private var topics: [MeetingTopicRange] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                        .background(Theme.gold, in: Circle()).foregroundStyle(Theme.background)
                }.buttonStyle(.plain).disabled(playback.preparing || total <= 0 || playback.error != nil)
                    .accessibilityLabel(playback.isPlaying ? "Pause recording" : "Play recording").help(playback.isPlaying ? "Pause" : "Play")
                Button { playback.skip(-10) } label: { Image(systemName: "gobackward.10") }.accessibilityLabel("Back 10 seconds").help("Back 10 seconds")
                Button { playback.skip(10) } label: { Image(systemName: "goforward.10") }.accessibilityLabel("Forward 10 seconds").help("Forward 10 seconds")
                Text("\(MeetingTaskImport.timestamp(position)) / \(MeetingTaskImport.timestamp(total))").font(Theme.body(12, weight: .semibold)).monospacedDigit().frame(minWidth: 110, alignment: .leading)
                Spacer(minLength: 8)
                if playback.preparing { ProgressView().controlSize(.mini); Text("Preparing audio…").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
                if !record.segments.isEmpty { Button("Show current passage") { meetings.showCurrentPassage(record) }.font(Theme.body(11)) }
                Picker("Playback speed", selection: $playback.speed) {
                    Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1)); Text("1.25×").tag(Float(1.25)); Text("1.5×").tag(Float(1.5)); Text("2×").tag(Float(2))
                }.labelsHidden().frame(width: 80).help("Playback speed")
            }.buttonStyle(.plain).foregroundStyle(Theme.text)
            Slider(value: Binding(get: { position }, set: { playback.seek(to: $0) }), in: 0...max(0.01, total))
                .tint(Theme.gold).disabled(total <= 0).accessibilityLabel("Recording position").accessibilityValue(MeetingTaskImport.timestamp(position) + " of " + MeetingTaskImport.timestamp(total))
            MeetingTimelineOverview(record: record, topics: topics, duration: total, position: position, seek: { playback.seek(to: $0) }).frame(height: 36).padding(.leading, record.segments.isEmpty ? 0 : 44)
            if !record.segments.isEmpty {
                MeetingSpeakerTimeline(record: record, duration: total, position: position, seek: { playback.seek(to: $0) }).frame(height: 30)
            }
            if !topics.isEmpty {
                HStack(spacing: 10) {
                    let current = topics.last { $0.start <= position && position < $0.end }
                    Image(systemName: "bookmark").foregroundStyle(Theme.gold)
                    Text(current?.topic.title ?? "Between discussion topics").font(Theme.body(11)).lineLimit(1).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 8)
                    Menu("Jump to topic") {
                        ForEach(topics) { topic in
                            Button("\(MeetingTaskImport.timestamp(topic.start)) · \(topic.topic.title)") { meetings.navigate(record, segmentID: topic.firstSegmentID) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize().font(Theme.body(11)).foregroundStyle(Theme.gold)
                }
            }
            if let error = playback.error {
                HStack(alignment: .top) { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert); Spacer(); Button("Retry audio") { playback.reset(); meetings.preparePlayback(record) }.font(Theme.body(11)).foregroundStyle(Theme.gold) }
            }
        }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            .task(id: record.id) { rebuildTopics(); meetings.preparePlayback(record) }
            .onChange(of: record.topics) { _, _ in rebuildTopics() }
            .onChange(of: record.segments) { _, _ in rebuildTopics() }
    }
    private func rebuildTopics() { topics = MeetingNavigation.topics(record.topics ?? [], segments: record.segments) }
}

private struct MeetingSpeakerTimeline: View {
    let record: MeetingRecording
    let duration: Double
    let position: Double
    let seek: (Double) -> Void
    private var mine: Int { record.segments.filter { record.isMySpeaker($0.speakerID) }.count }
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Me").foregroundStyle(MeetingSpeakerStyle.myself)
                Text("Others").foregroundStyle(Theme.secondary)
            }.font(Theme.body(9)).frame(width: 36, alignment: .leading)
            GeometryReader { geometry in
                Canvas { context, size in
                    for y: CGFloat in [1, 18] {
                        context.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: 10), cornerRadius: 2), with: .color(Theme.line.opacity(0.45)))
                    }
                    // Separate lanes keep overlapping participants from obscuring Me.
                    for segment in record.segments where segment.end > segment.start {
                        let a = min(1, max(0, segment.start / max(1, duration))), b = min(1, max(0, segment.end / max(1, duration)))
                        let rect = CGRect(x: a * size.width, y: record.isMySpeaker(segment.speakerID) ? 1 : 18, width: max(1, (b - a) * size.width), height: 10)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(MeetingSpeakerStyle.color(record.speakerColor(segment.speakerID))))
                    }
                    let x = min(max(0, size.width - 1), max(0, position / max(1, duration) * size.width))
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: 30)), with: .color(Theme.gold))
                }.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in seek(min(1, max(0, value.location.x / max(1, geometry.size.width))) * duration) })
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Speaker timeline. Me is pink.")
            .accessibilityValue("\(mine) passages assigned to Me")
            .help(mine == 0 ? "Assign your labels to Me in Speakers. Click or drag to seek." : "Me is always pink. Click or drag to seek.")
    }
}

private struct MeetingTimelineOverview: View {
    let record: MeetingRecording
    let topics: [MeetingTopicRange]
    let duration: Double
    let position: Double
    let seek: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 4) {
                Canvas { context, size in
                    let denominator = max(1, duration)
                    if topics.isEmpty {
                        for segment in record.segments where segment.end > segment.start {
                            let start = max(0, min(1, segment.start / denominator)), end = max(0, min(1, segment.end / denominator))
                            let r = CGRect(x: start * size.width, y: 1, width: max(1, (end - start) * size.width), height: 9)
                            context.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(Theme.gold.opacity(0.38)))
                        }
                    } else {
                        for (index, topic) in topics.enumerated() {
                            let start = max(0, min(1, topic.start / denominator)), end = max(0, min(1, topic.end / denominator))
                            let r = CGRect(x: start * size.width, y: 1, width: max(1, (end - start) * size.width - 2), height: 9)
                            context.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(index.isMultiple(of: 2) ? Theme.gold.opacity(0.7) : Theme.green.opacity(0.6)))
                        }
                    }
                }.frame(height: 11).background(Theme.line.opacity(0.4), in: RoundedRectangle(cornerRadius: 2)).accessibilityHidden(true)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.gold).frame(width: 1, height: 15).offset(x: min(geometry.size.width - 1, max(0, position / max(1, duration) * geometry.size.width))).allowsHitTesting(false) }
                    .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in seek(min(1, max(0, value.location.x / max(1, geometry.size.width))) * duration) })
                    .help(topics.isEmpty ? "Transcript activity · click or drag to seek" : "Topic ranges · click or drag to seek")
                HStack {
                    Text("00:00"); Spacer()
                    Text(topics.isEmpty ? (record.segments.isEmpty ? "Recording timeline" : "Transcript activity") : "\(topics.count) topic ranges")
                    Spacer(); Text(MeetingTaskImport.timestamp(duration))
                }.font(Theme.body(9)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
        }
    }
}

struct MeetingTopicList: View {
    @ObservedObject var meetings: MeetingStore
    let record: MeetingRecording
    private var topics: [MeetingTopicRange] { MeetingNavigation.topics(record.topics ?? [], segments: record.segments) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(title: "Discussion timeline")
                Spacer()
                Button(topics.isEmpty ? "Generate topics…" : "Refresh topics…") { meetings.requestTopicTimeline() }.buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.gold).disabled(meetings.busy || record.segments.isEmpty)
            }
            if topics.isEmpty {
                Text(record.topics == nil ? "Generate topic markers from the transcript, or search Transcript to find a word or phrase in English or Russian." : "No discussion topics were returned. Search the transcript or try generating them again.").font(Theme.body(12)).foregroundStyle(Theme.secondary)
            }
            ForEach(topics) { topic in
                Button { meetings.navigate(record, segmentID: topic.firstSegmentID) } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(MeetingTaskImport.timestamp(topic.start))–\(MeetingTaskImport.timestamp(topic.end))").font(Theme.body(11)).monospacedDigit().foregroundStyle(Theme.gold).frame(width: 105, alignment: .leading)
                        VStack(alignment: .leading, spacing: 5) { Text(topic.topic.title).font(Theme.body(14, weight: .semibold)); if !topic.topic.summary.isEmpty { Text(topic.topic.summary).font(Theme.body(12)).foregroundStyle(Theme.secondary).lineLimit(3) } }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "play.circle").foregroundStyle(Theme.secondary)
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Play this passage and open its transcript")
                DividerLine()
            }
        }
    }
}
