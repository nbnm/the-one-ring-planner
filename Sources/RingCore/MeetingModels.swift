import Foundation

public struct MeetingModel: Identifiable, Equatable, Sendable {
    public let id: String
    public var mode: String?
    public var isAudioCandidate: Bool { mode == "audio_transcription" || ["transcri", "whisper", "diariz", "voxtral", "deepgram"].contains { id.lowercased().contains($0) } }
    public var isDiarizationCandidate: Bool { id.lowercased().contains("diariz") }
    public var description: String { mode ?? (isAudioCandidate ? "Audio suggested by alias; capability unverified" : "Capability not advertised") }
    public init(id: String, mode: String? = nil) { self.id = id; self.mode = mode }
}

extension MeetingProcessingClient {
    public func models(connection: LiteLLMConnection, apiKey: String) async throws -> [MeetingModel] {
        let base = try connection.endpoint().deletingLastPathComponent().deletingLastPathComponent()
        func get(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url); request.timeoutInterval = 30
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw MeetingError.invalidResponse }
            guard response.statusCode == 200 else { throw MeetingError.http(response.statusCode) }
            guard data.count < 5_000_000 else { throw MeetingError.invalidResponse }
            return data
        }
        let data = try await get(base.appendingPathComponent("models"))
        var models = try Self.parseModels(data)
        // Metadata is optional and often restricted to gateway administrators.
        let root = base.lastPathComponent == "v1" ? base.deletingLastPathComponent() : base
        if let metadata = try? await get(root.appendingPathComponent("model/info")), let detailed = try? Self.parseModels(metadata) {
            for item in detailed {
                if let index = models.firstIndex(where: { $0.id == item.id }) { models[index].mode = item.mode }
            }
        }
        try Task.checkCancellation()
        return models.sorted { $0.isAudioCandidate != $1.isAudioCandidate ? $0.isAudioCandidate : $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
    public static func parseModels(_ data: Data) throws -> [MeetingModel] {
        // Deliberately decode only public alias/capability fields, never provider credentials.
        struct Payload: Decodable {
            struct Item: Decodable {
                struct Info: Decodable { let mode: String? }
                let id: String?; let model_name: String?; let model_info: Info?
            }
            let data: [Item]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.data.count <= 10000 else { throw MeetingError.invalidResponse }
        var seen = Set<String>()
        return payload.data.compactMap { item in
            guard let id = item.model_name ?? item.id, !id.isEmpty, id.count <= 256, !id.contains(where: \.isNewline), seen.insert(id).inserted else { return nil }
            return MeetingModel(id: id, mode: item.model_info?.mode)
        }
    }
}
