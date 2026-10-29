import Foundation
import Combine

/// Points per game for many players at once, for the Free Agents tab.
/// ESPN has no one-call league table we rely on, so this reads each player's game log (the same source as the
/// player screen), 24 players at a time, and saves the results: six hours for this season, a week for last season.
@MainActor
final class SeasonAverages: ObservableObject {
    /// This regular season so far.
    @Published private(set) var averages: [String: PlayerAverage] = [:]
    /// Last regular season. Only loaded for injured players, to judge how big a role they have when they haven't played yet.
    @Published private(set) var previous: [String: PlayerAverage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0

    /// Games it takes before this season's average is trusted over last season's.
    static let minGamesForCurrent = 3

    private struct Stored: Codable {
        var average: PlayerAverage
        var fetchedAt: Date
    }

    private var stored: [String: Stored]
    private var storedPrevious: [String: Stored]
    private let fileURL = Storage.url("season-averages.json")
    private let previousURL = Storage.url("season-averages-prev.json")
    private let maxAge: TimeInterval = 6 * 3600
    private let previousMaxAge: TimeInterval = 7 * 24 * 3600
    private let batchSize = 24

    init() {
        func read(_ url: URL) -> [String: Stored] {
            guard let data = try? Data(contentsOf: url),
                  let saved = try? JSONDecoder().decode([String: Stored].self, from: data) else { return [:] }
            return saved
        }
        stored = read(fileURL)
        storedPrevious = read(previousURL)
        averages = stored.mapValues { $0.average }
        previous = storedPrevious.mapValues { $0.average }
    }

    /// How big a scorer he is: this season's PPG once he has a few games, otherwise last season's.
    /// nil when neither is known.
    func usagePPG(_ id: String) -> Double? {
        if let a = averages[id], a.games >= Self.minGamesForCurrent { return a.ppg }
        if let p = previous[id], p.games > 0 { return p.ppg }
        if let a = averages[id], a.games > 0 { return a.ppg }
        return nil
    }

    /// Loads this season's averages for `injuredIDs` first (so the injury flags show up fast) and then for `ids`.
    /// Injured players who haven't played enough this season also get last season's average.
    /// Anything fresh enough is skipped unless `force`. A player whose request fails is skipped and retried next call.
    func load(ids: [String], injuredIDs: [String], force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        total = 0
        done = 0
        defer { isLoading = false }

        func stale(_ id: String, in store: [String: Stored], maxAge: TimeInterval) -> Bool {
            if force { return true }
            guard let entry = store[id] else { return true }
            return Date().timeIntervalSince(entry.fetchedAt) > maxAge
        }

        let injuredNow = injuredIDs.filter { stale($0, in: stored, maxAge: maxAge) }
        let rest = ids.filter { id in !injuredIDs.contains(id) && stale(id, in: stored, maxAge: maxAge) }
        total = injuredNow.count + rest.count

        await run(injuredNow, previousSeason: false)
        guard !Task.isCancelled else { return }

        let needPrevious = injuredIDs.filter { id in
            (stored[id]?.average.games ?? 0) < Self.minGamesForCurrent && stale(id, in: storedPrevious, maxAge: previousMaxAge)
        }
        total += needPrevious.count
        await run(needPrevious, previousSeason: true)
        guard !Task.isCancelled else { return }

        await run(rest, previousSeason: false)
    }

    private func run(_ todo: [String], previousSeason: Bool) async {
        var start = 0
        while start < todo.count, !Task.isCancelled {
            let batch = Array(todo[start..<min(start + batchSize, todo.count)])
            start += batch.count
            let results = await withTaskGroup(of: (String, PlayerAverage?).self) { group -> [(String, PlayerAverage?)] in
                for id in batch {
                    group.addTask {
                        (id, try? await ESPNClient.shared.seasonAverage(athleteID: id, previousSeason: previousSeason))
                    }
                }
                var out: [(String, PlayerAverage?)] = []
                for await item in group { out.append(item) }
                return out
            }
            let stamp = Date()
            for (id, avg) in results {
                guard let avg else { continue }
                if previousSeason {
                    storedPrevious[id] = Stored(average: avg, fetchedAt: stamp)
                } else {
                    stored[id] = Stored(average: avg, fetchedAt: stamp)
                }
            }
            if previousSeason {
                previous = storedPrevious.mapValues { $0.average }
            } else {
                averages = stored.mapValues { $0.average }
            }
            done += batch.count
            save(previousSeason ? storedPrevious : stored, to: previousSeason ? previousURL : fileURL)
        }
    }

    private func save(_ store: [String: Stored], to url: URL) {
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
