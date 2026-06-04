import Foundation
import Combine

struct TraceMetadata: Codable, Equatable {
    var zoom: Double
}

final class TraceStore: ObservableObject {
    private let identifiersKey = "trace_local_identifiers"
    private let metadataKey = "trace_metadata"

    @Published private(set) var identifiers: [String]
    @Published private(set) var metadata: [String: TraceMetadata]

    init() {
        identifiers = UserDefaults.standard.stringArray(forKey: identifiersKey) ?? []
        if let data = UserDefaults.standard.data(forKey: metadataKey),
           let decoded = try? JSONDecoder().decode([String: TraceMetadata].self, from: data) {
            metadata = decoded
        } else {
            metadata = [:]
        }
    }

    func add(_ id: String, metadata meta: TraceMetadata) {
        if !identifiers.contains(id) {
            identifiers.append(id)
        }
        metadata[id] = meta
        persist()
    }

    func setIdentifiers(_ ids: [String]) {
        let kept = Set(ids)
        identifiers = ids
        metadata = metadata.filter { kept.contains($0.key) }
        persist()
    }

    func clear() {
        identifiers.removeAll()
        metadata.removeAll()
        persist()
    }

    func zoom(for id: String) -> Double {
        metadata[id]?.zoom ?? 1.0
    }

    private func persist() {
        UserDefaults.standard.set(identifiers, forKey: identifiersKey)
        if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: metadataKey)
        }
    }
}
