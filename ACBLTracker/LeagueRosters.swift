import Foundation

/// Every team's lineup for a league week, copied from the league sheet and bundled as LeagueRosters.json.
/// The Free Agents tab treats anyone on these lists, or on your own lineup, as taken.
///
/// Each week is keyed by its Tuesday ("yyyy-MM-dd", the same key LineupStore uses). To add a week, copy the
/// previous entry in the JSON, change the key and update the players. A week with no entry of its own
/// falls back to the latest earlier one, and the tab warns that the data is old.
struct LeagueRosters: Decodable {
    struct Team: Decodable {
        let name: String
        /// "Full Name|NBA" per player. The NBA team is only a hint for matching and can be left empty.
        let players: [String]
    }

    struct Week: Decodable {
        /// Which tab of the league sheet this came from, e.g. "W2".
        let sheet: String
        let teams: [Team]
    }

    struct Entry: Hashable {
        let name: String
        let team: String
        let owner: String
    }

    let weeks: [String: Week]

    static let bundled: LeagueRosters = {
        guard let url = Bundle.main.url(forResource: "LeagueRosters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(LeagueRosters.self, from: data) else {
            return LeagueRosters(weeks: [:])
        }
        return decoded
    }()

    static func entries(in week: Week) -> [Entry] {
        week.teams.flatMap { team in
            team.players.map { raw in
                let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                return Entry(
                    name: (parts.first ?? raw).trimmingCharacters(in: .whitespaces),
                    team: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "",
                    owner: team.name
                )
            }
        }
    }

    /// The snapshot in force for a week: its own entry, else the latest earlier one.
    func snapshot(for weekKey: String) -> (key: String, week: Week)? {
        guard let key = weeks.keys.filter({ $0 <= weekKey }).max(), let week = weeks[key] else { return nil }
        return (key, week)
    }
}

/// Who is spoken for in a week, as ESPN athlete ids.
struct TakenPlayers {
    var ids: Set<String> = []
    /// Sheet entries that couldn't be matched to an ESPN player. They stay out of `ids`.
    var unmatched: [LeagueRosters.Entry] = []
    /// Week key and sheet tab of the snapshot that was used, nil when none is bundled.
    var weekKey: String? = nil
    var sheet: String? = nil
}

extension LeagueRosters {
    /// Everyone on a league roster for `weekKey` plus everyone on `own`, matched to ESPN ids.
    @MainActor
    func taken(weekKey: String, directory: PlayerDirectory, own: Lineup) -> TakenPlayers {
        var out = TakenPlayers()
        for p in own.all where !p.isEmpty {
            if let id = p.espnID {
                out.ids.insert(id)
            } else if let match = directory.resolve(name: p.name, teamHint: p.teamHint) {
                out.ids.insert(match.id)
            }
        }
        guard let snap = snapshot(for: weekKey) else { return out }
        out.weekKey = snap.key
        out.sheet = snap.week.sheet
        for e in Self.entries(in: snap.week) {
            if let match = directory.resolve(name: e.name, teamHint: e.team) {
                out.ids.insert(match.id)
            } else {
                out.unmatched.append(e)
            }
        }
        return out
    }
}
