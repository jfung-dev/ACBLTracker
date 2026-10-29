import Foundation

/// The league's own G/F/C for every NBA player, from the "Final Revised ACBL Positions" column of the
/// league sheet's Positions tab. Bundled as LeaguePositions.txt, one line per team and position:
/// `TEAM|POSITION|Name;Name;Name`. Players the sheet leaves blank fall back to ESPN's listing.
struct LeaguePositions {
    private let byName: [String: Position]
    /// "TEAM|lastname" -> positions. Used only when exactly one player on that team has that last name.
    private let byTeamAndLast: [String: [Position]]

    static let bundled: LeaguePositions = {
        guard let url = Bundle.main.url(forResource: "LeaguePositions", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return LeaguePositions(text: "")
        }
        return LeaguePositions(text: text)
    }()

    init(text: String) {
        var names: [String: Position] = [:]
        var teamLast: [String: [Position]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let position = Position(rawValue: parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let team = TeamAlias.canon(parts[0].trimmingCharacters(in: .whitespaces))
            for name in parts[2].split(separator: ";") {
                let key = String(name).normalizedName
                if key.isEmpty { continue }
                if names[key] == nil { names[key] = position }
                let last = key.split(separator: " ").last.map(String.init) ?? key
                teamLast["\(team)|\(last)", default: []].append(position)
            }
        }
        byName = names
        byTeamAndLast = teamLast
    }

    /// The league position for an ESPN player, or nil when the sheet doesn't list him.
    /// Tries his full name first, then his last name on his team (for "Nic" vs "Nicolas" style differences).
    func position(for p: DirectoryPlayer) -> Position? {
        let name = p.name.normalizedName
        if let hit = byName[name] { return hit }
        let last = name.split(separator: " ").last.map(String.init) ?? name
        if let list = byTeamAndLast["\(TeamAlias.canon(p.teamAbbr))|\(last)"], list.count == 1 { return list[0] }
        return nil
    }

    /// League position when the sheet has him, ESPN's otherwise.
    func resolved(for p: DirectoryPlayer) -> Position {
        position(for: p) ?? Position.fromESPN(p.position)
    }
}
