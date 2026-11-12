import SwiftUI
import AVFoundation
import RingCore

struct TaskCompletionFeedback: Identifiable {
    let id = UUID()
    let completion: TaskCompletion
}

struct TaskCompletionToast: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let feedback: TaskCompletionFeedback
    @State private var settled = false
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if !reduceMotion {
                    ForEach(0..<8) { index in
                        Circle().fill(Theme.gold).frame(width: index.isMultiple(of: 2) ? 3 : 2, height: 3)
                            .offset(x: cos(Double(index) * .pi / 4) * (settled ? 29 : 12), y: sin(Double(index) * .pi / 4) * (settled ? 29 : 12))
                            .opacity(settled ? 0 : 0.9)
                    }
                }
                Circle().stroke(Theme.gold.opacity(0.25), lineWidth: 1.5)
                Circle().trim(from: 0, to: settled ? 1 : 0).stroke(Theme.gold, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.gold)
                    .scaleEffect(settled || reduceMotion ? 1 : 0.75)
            }.frame(width: 38, height: 38).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Task complete").font(Theme.body(12, weight: .semibold))
                Text(feedback.completion.taskSnapshot.title).font(Theme.body(11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Undo") { _ = store.restoreCompletion(feedback.completion, destination: .backlog) }
                .buttonStyle(.plain).font(Theme.body(12, weight: .semibold)).foregroundStyle(Theme.gold)
                .help("Mark incomplete and return to backlog, keeping its priority")
                .disabled(store.publishingCalendar || store.calendarEditSending)
            Button { store.taskCelebration = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary).accessibilityLabel("Dismiss completion message")
        }
        .padding(16).frame(width: 390).foregroundStyle(Theme.text)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.gold.opacity(0.25)))
        .shadow(color: .black.opacity(0.1), radius: 14, y: 4)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.55)) { settled = true } }
        .task(id: feedback.id) {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if store.taskCelebration?.id == feedback.id { store.taskCelebration = nil }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A quiet original three-note chime. In-memory PCM needs no files or audio-capture permission.
@MainActor final class TaskCompletionSound {
    private var player: AVAudioPlayer?
    func play() {
        if player == nil {
            player = try? AVAudioPlayer(data: Self.chime())
            player?.volume = 0.45
            player?.prepareToPlay()
        }
        player?.stop(); player?.currentTime = 0; player?.play()
    }
    private static func chime() -> Data {
        let rate = 44_100, count = Int(0.8 * 44_100)
        let tones: [(Double, Double)] = [(587.33, 0), (739.99, 0.08), (880, 0.17)]
        var samples = Data(capacity: count * 2)
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        for index in 0..<count {
            let t = Double(index) / Double(rate)
            var value = 0.0
            for (frequency, onset) in tones where t >= onset {
                let age = t - onset
                let envelope = min(1, age / 0.006) * exp(-age * 8) * min(1, (0.8 - t) / 0.05)
                value += 0.15 * envelope * (sin(2 * .pi * frequency * age) + 0.18 * sin(4 * .pi * frequency * age))
            }
            append(Int16(max(-1, min(1, value)) * Double(Int16.max)), to: &samples)
        }
        var wave = Data("RIFF".utf8)
        append(UInt32(36 + samples.count), to: &wave); wave.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &wave); append(UInt16(1), to: &wave); append(UInt16(1), to: &wave)
        append(UInt32(rate), to: &wave); append(UInt32(rate * 2), to: &wave)
        append(UInt16(2), to: &wave); append(UInt16(16), to: &wave)
        wave.append(contentsOf: "data".utf8); append(UInt32(samples.count), to: &wave); wave.append(samples)
        return wave
    }
}
