import Foundation

public struct MeetingTranscriptionOptions: Equatable, Sendable {
    public let responseFormat: String
    public let speakerSeparation: Bool
    public let automaticChunking: Bool
    public let segmentTimestamps: Bool
    public let note: String?
    public static func resolve(model: String, speakerLabels: Bool) -> Self {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: "/").last.map(String.init) ?? ""
        if name == "whisper-1" {
            return .init(responseFormat: "verbose_json", speakerSeparation: false, automaticChunking: false, segmentTimestamps: true,
                         note: "Whisper provides text and timecodes without speaker separation. Use a diarization model for individual speaker labels.")
        }
        if name.hasPrefix("gpt-4o-transcribe") && !name.contains("diarize") || name.hasPrefix("gpt-4o-mini-transcribe") || name == "gpt-transcribe" {
            return .init(responseFormat: "json", speakerSeparation: false, automaticChunking: false, segmentTimestamps: false,
                         note: "This model provides transcription without individual speaker labels; timecodes depend on the returned segments.")
        }
        if name.contains("diariz") {
            return .init(responseFormat: speakerLabels ? "diarized_json" : "json", speakerSeparation: speakerLabels,
                         automaticChunking: true, segmentTimestamps: false, note: nil)
        }
        return .init(responseFormat: speakerLabels ? "diarized_json" : "verbose_json", speakerSeparation: speakerLabels,
                     automaticChunking: speakerLabels, segmentTimestamps: false, note: nil)
    }
}
