import Foundation
import CryptoKit

public struct MeetingAudioChunk: Equatable, Sendable, Identifiable {
    public static let sampleRate: Int64 = 16000
    public let startFrame: Int64
    public let endFrame: Int64
    public var id: String { "stt-\(startFrame)-\(endFrame)" }
    public var offset: Double { Double(startFrame) / Double(Self.sampleRate) }
    public var duration: Double { Double(endFrame - startFrame) / Double(Self.sampleRate) }
    public init(startFrame: Int64, endFrame: Int64) { self.startFrame = startFrame; self.endFrame = endFrame }
    public var split: [Self]? {
        guard endFrame - startFrame >= 90 * Self.sampleRate else { return nil }
        let middle = startFrame + (endFrame - startFrame) / 2
        return [Self(startFrame: startFrame, endFrame: middle), Self(startFrame: middle, endFrame: endFrame)]
    }
}

public enum MeetingChunkPlanner {
    public static let maximumFrames: Int64 = 180 * MeetingAudioChunk.sampleRate
    /// Coverage is encoded in the durable IDs. Partial adaptive splits resume without
    /// uploading their successful siblings again. Old twenty-minute part IDs still work.
    public static func pending(totalFrames: Int64, completed: [String]) -> [MeetingAudioChunk] {
        guard totalFrames > 0, totalFrames <= 4 * 3600 * MeetingAudioChunk.sampleRate + MeetingAudioChunk.sampleRate else { return [] }
        var covered: [MeetingAudioChunk] = []
        for id in Set(completed) {
            let bits = id.split(separator: "-")
            var a: Int64?, b: Int64?
            if bits.count == 3, bits[0] == "stt", let end = Int64(bits[2]), end <= totalFrames { a = Int64(bits[1]); b = end }
            else if bits.count == 2, bits[0] == "part", let index = Int64(bits[1]), index > 0, index <= 13 {
                a = (index - 1) * 1200 * MeetingAudioChunk.sampleRate; b = index * 1200 * MeetingAudioChunk.sampleRate
            }
            if let a, let b, a >= 0, a < totalFrames, b > a { covered.append(.init(startFrame: a, endFrame: min(b, totalFrames))) }
        }
        covered.sort { $0.startFrame < $1.startFrame }
        var result: [MeetingAudioChunk] = [], cursor: Int64 = 0
        func gap(_ end: Int64) {
            while cursor < end {
                let next = min(end, cursor + maximumFrames)
                result.append(.init(startFrame: cursor, endFrame: next)); cursor = next
            }
        }
        for item in covered { if item.startFrame > cursor { gap(item.startFrame) }; cursor = max(cursor, item.endFrame) }
        gap(totalFrames)
        return result
    }
    public static func completedFraction(totalFrames: Int64, completed: [String]) -> Double {
        guard totalFrames > 0, totalFrames <= 4 * 3600 * MeetingAudioChunk.sampleRate + MeetingAudioChunk.sampleRate else { return 0 }
        let remaining = pending(totalFrames: totalFrames, completed: completed).reduce(Int64(0)) { $0 + $1.endFrame - $1.startFrame }
        return min(1, max(0, 1 - Double(remaining) / Double(totalFrames)))
    }
}

public struct MeetingAnalysisProgress: Codable, Equatable, Sendable {
    public let configuration: String
    public var completedBatchIDs: [String] = []
    public var pendingTopics: [MeetingTopic] = []
    public init(configuration: String) { self.configuration = configuration }
}

public enum MeetingAnalysisCheckpoint {
    private static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func batchID(_ segments: [MeetingSegment]) -> String { digest(segments) }
    public static func configuration(meeting: MeetingRecording, knownTags: [String], connection: LiteLLMConnection, topicsOnly: Bool) -> String {
        struct Input: Encodable {
            let base: String; let model: String; let prompt: String; let title: String
            let speakers: [String: String]; let tags: [String]; let transcript: [MeetingSegment]; let topicsOnly: Bool
        }
        return digest(Input(base: connection.baseURL, model: connection.model, prompt: MeetingProcessingClient.instructions,
            title: meeting.title, speakers: meeting.speakerNames, tags: Array(knownTags.prefix(60)), transcript: MeetingNavigation.ordered(meeting.segments), topicsOnly: topicsOnly))
    }
    public static func starting(_ record: MeetingRecording, configuration: String, restart: Bool) -> MeetingRecording {
        var record = record
        if restart || record.analysisProgress?.configuration != configuration { record.analysisProgress = .init(configuration: configuration) }
        return record
    }
    /// Receipt and results are saved in the same atomic meeting.json write.
    public static func applying(_ part: MeetingAnalysisPart, batchID: String, topicsOnly: Bool, to record: MeetingRecording) -> MeetingRecording {
        guard var receipt = record.analysisProgress, !receipt.completedBatchIDs.contains(batchID) else { return record }
        var record = record
        receipt.completedBatchIDs.append(batchID)
        for topic in part.topics where !receipt.pendingTopics.contains(where: { $0.id == topic.id }) { receipt.pendingTopics.append(topic) }
        record.analysisProgress = receipt
        if topicsOnly { return record }
        var topics = record.topics ?? []
        for topic in part.topics where !topics.contains(where: { $0.id == topic.id }) { topics.append(topic) }
        record.topics = topics
        if !part.summary.isEmpty && !record.summaries.contains(part.summary) { record.summaries.append(part.summary) }
        for decision in part.decisions where !record.decisions.contains(decision) { record.decisions.append(decision) }
        for var suggestion in part.tasks {
            let identity = suggestion.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + "|" + (suggestion.speakerID ?? "")
            suggestion.id = SHA256.hash(data: Data("\(record.id)|\(identity)".utf8)).map { String(format: "%02x", $0) }.joined()
            if !record.suggestions.contains(where: { $0.id == suggestion.id }) { record.suggestions.append(suggestion) }
        }
        return record
    }
}

public struct MeetingRequestTimeout: LocalizedError, Sendable {
    public let stage: MeetingGatewayFailure.Stage
    public var errorDescription: String? { "\(stage.rawValue) timed out. Completed chunks are saved; resume processing to continue from the last checkpoint." }
    public init(stage: MeetingGatewayFailure.Stage) { self.stage = stage }
}
public enum MeetingRetryPolicy {
    public static func isTimeout(_ error: Error) -> Bool {
        if error is MeetingRequestTimeout { return true }
        if let failure = error as? MeetingGatewayFailure { return [408, 504].contains(failure.status) }
        return (error as? URLError)?.code == .timedOut
    }
    public static func shouldRetry(_ error: Error) -> Bool {
        if isTimeout(error) { return true }
        if let failure = error as? MeetingGatewayFailure { return [429, 500, 502, 503].contains(failure.status) }
        guard let network = error as? URLError else { return false }
        return [.networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed].contains(network.code)
    }
    public static func delay(after attempt: Int, retryAfter: Double? = nil) -> Double {
        if let retryAfter, retryAfter.isFinite { return min(60, max(1, retryAfter)) }
        return min(30, pow(2, Double(max(0, min(5, attempt - 1)))))
    }
}
