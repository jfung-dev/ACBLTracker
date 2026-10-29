import Foundation
import Combine

/// Points per game for many players at once, for the Free Agents tab.
/// ESPN has no one-call league table we rely on, so this reads each player's game log (the same source as the
/// player screen), 24 players at a time, and saves the results for six hours.
@MainActor
final class SeasonAverages: ObservableObject {
    @Published private(set) var averages: [String: PlayerAverage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0

    private struct Stored: Codable {
        var average: PlayerAverage
        var fetchedAt: Date
    }

    private var stored: [String: Stored]
    private let fileURL = Storage.url("season-averages.json")
    private let maxAge: TimeInterval = 6 * 3600
    private let batchSize = 24

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Stored].self, from: data) {
            stored = saved
        } else {
            stored = [:]
        }
        averages = stored.mapValues { $0.average }
    }

    /// Fetches anyone who is missing or older than six hours. `force` refetches everyone.
    /// Players whose request fails are skipped this time and tried again on the next call.
    func load(ids: [String], force: Bool = false) async {
        guard !isLoading else { return }
        let now = Date()
        let todo = ids.filter { id in
            if force { return true }
            guard let entry = stored[id] else { return true }
            return now.timeIntervalSince(entry.fetchedAt) > maxAge
        }
        guard !todo.isEmpty else { return }

        isLoading = true
        total = todo.count
        done = 0
        defer { isLoading = false }

        var start = 0
        while start < todo.count, !Task.isCancelled {
            let batch = Array(todo[start..<min(start + batchSize, todo.count)])
            start += batch.count
            let results = await withTaskGroup(of: (String, PlayerAverage?).self) { group -> [(String, PlayerAverage?)] in
                for id in batch {
                    group.addTask { (id, try? await ESPNClient.shared.seasonAverage(athleteID: id)) }
                }
                var out: [(String, PlayerAverage?)] = []
                for await item in group { out.append(item) }
                return out
            }
            let stamp = Date()
            for (id, avg) in results {
                if let avg { stored[id] = Stored(average: avg, fetchedAt: stamp) }
            }
            averages = stored.mapValues { $0.average }
            done += batch.count
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
