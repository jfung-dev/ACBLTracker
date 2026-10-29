import Foundation

/// One player cell from a weekly tab of the league sheet, e.g. "G - SGA (OKC)" or "N. Jokić - DEN - C".
struct SheetCell: Equatable {
    var name: String
    /// Team as written (may be a nickname like "Chlt"), nil when the cell doesn't say.
    var team: String?
    /// Lowercased first initial when the cell is written "K. Durant".
    var initial: Character?
    /// Other names found in parentheses, e.g. "Mamukelashvili" in "Mamu (Mamukelashvili) (Lal)".
    var alts: [String]
}

private extension String {
    /// Capture groups of the first match of `pattern`, nil when it doesn't match.
    func captures(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (1..<max(m.numberOfRanges, 1)).map { i in
            Range(m.range(at: i), in: self).map { String(self[$0]) } ?? ""
        }
    }

    func allCaptures(_ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { m in
            m.numberOfRanges > 1 ? Range(m.range(at: 1), in: self).map { String(self[$0]) } : nil
        }
    }
}

enum LeagueSheet {
    private static let knownTeams: Set<String> = Set(
        ("ATL BOS BKN CHA CHI CLE DAL DEN DET GS GSW HOU IND LAC LAL MEM MIA MIL MIN NO NOP NY NYK OKC ORL PHI PHX PHO "
         + "POR PDX PORT SAC SA SAS TOR UTA UTH UTAH WAS WSH WDC PHIL CHLT")
            .split(separator: " ").map { TeamAlias.canon(String($0)) }
    )

    private static func isTeam(_ s: String) -> Bool { knownTeams.contains(TeamAlias.canon(s)) }

    /// Nicknames the league uses, as normalized keys.
    private static let nicknames: [String: String] = Dictionary(uniqueKeysWithValues: [
        "SGA": "Shai Gilgeous-Alexander", "KAT": "Karl-Anthony Towns", "Spicy P": "Pascal Siakam",
        "NAW": "Nickeil Alexander-Walker", "Podz": "Brandin Podziemski", "Ant": "Anthony Edwards",
        "Mamu": "Sandro Mamukelashvili", "Giannis": "Giannis Antetokounmpo", "LeBron": "LeBron James",
    ].map { ($0.key.normalizedName, $0.value) })

    // MARK: CSV

    /// RFC 4180 CSV (what Google's gviz endpoint returns): quoted fields, doubled quotes, newlines inside quotes.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = chars.next()
        while let c = pending {
            pending = chars.next()
            if inQuotes {
                if c == "\"" {
                    if pending == "\"" { field.append("\""); pending = chars.next() } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: Cells

    /// Reads a player cell, nil for anything that isn't one (team names, scores, notes).
    static func parseCell(_ raw: String) -> SheetCell? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var team: String?
        var body: String
        if let c = s.captures(#"^(.+?)\s*-\s*([A-Za-z]{2,5})\s*-\s*([GFC])$"#), isTeam(c[1]) {
            body = c[0]; team = c[1]
        } else if let c = s.captures(#"^([GFC])(?:\s*-{1,2}\s*|\s+)(.+)$"#) {
            body = c[1]
        } else {
            return nil
        }
        body = body.replacingOccurrences(of: #"^#\d+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        var alts: [String] = []
        for g in body.allCaptures(#"\(([^)]*)\)"#) {
            let t = g.trimmingCharacters(in: .whitespaces)
            if isTeam(t) { team = t } else if t.count >= 5 { alts.append(t) }
        }
        body = body.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        if team == nil {
            let toks = body.split(separator: " ").map(String.init)
            if toks.count >= 2, let last = toks.last, isTeam(last) {
                team = last
                body = toks.dropLast().joined(separator: " ")
            }
        }

        var initial: Character?
        if let c = body.captures(#"^([A-Za-z])\.\s*(\S.*)$"#), c[1].captures(#"^([A-Za-z])\."#) == nil {
            initial = c[0].lowercased().first
            body = c[1]
        }
        if body.isEmpty { return nil }
        return SheetCell(name: body, team: team, initial: initial, alts: alts)
    }

    /// Matches a parsed cell to an NBA player. Tries the exact name, then the last name (on his team when the
    /// cell names one), then small typos. Returns nil rather than guessing between two players.
    static func resolve(_ cell: SheetCell, in players: [DirectoryPlayer]) -> DirectoryPlayer? {
        let team = cell.team.map(TeamAlias.canon)
        let normed = players.map { (player: $0, name: $0.name.normalizedName) }
        func lastToken(_ s: String) -> String? { s.split(separator: " ").last.map(String.init) }

        for nm in [cell.name] + cell.alts {
            var key = nm.normalizedName
            if let full = nicknames[key] { key = full.normalizedName }
            guard let last = lastToken(key) else { continue }
            let tokenCount = key.split(separator: " ").count

            let exact = normed.filter { $0.name == key }
            if exact.count == 1 { return exact[0].player }
            if exact.count > 1, let team {
                let onTeam = exact.filter { TeamAlias.canon($0.player.teamAbbr) == team }
                if onTeam.count == 1 { return onTeam[0].player }
            }

            let pool = normed.filter { team == nil || TeamAlias.canon($0.player.teamAbbr) == team }
            var sameLast = pool.filter { lastToken($0.name) == last }
            if let initial = cell.initial, sameLast.count > 1 {
                sameLast = sameLast.filter { $0.name.first == initial }
            }
            if sameLast.count == 1 { return sameLast[0].player }

            if tokenCount >= 2 {
                let scored = pool.map { (item: $0, d: levenshtein($0.name, key)) }
                    .filter { $0.d <= 2 }
                    .sorted { $0.d < $1.d }
                if let best = scored.first, scored.count == 1 || scored[1].d > best.d { return best.item.player }
            }

            // One word with a typo ("LaSmelo"), only when the team narrows it down.
            if team != nil, tokenCount == 1 {
                let close = pool.filter { item in
                    item.name.split(separator: " ").contains { $0.count >= 5 && levenshtein(String($0), key) <= 1 }
                }
                if close.count == 1 { return close[0].player }
            }
        }
        return nil
    }

    // MARK: Which tab

    struct ActiveWeek: Equatable {
        /// League week number (at least 1) and the sheet tab that holds its lineups, e.g. "W3".
        let number: Int
        let tab: String
        /// "yyyy-MM-dd" of the week's Tuesday, the key LineupStore and LeagueRosters.json use.
        let key: String
    }

    static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    /// The week whose lineups are the ones to look at. Lineups are due Tuesday 1 pm PT and the sheet is
    /// filled in by 5 pm PT, so each new week's tab takes over then and not at midnight.
    static func activeWeek(now: Date = Date()) -> ActiveWeek {
        var start = ET.weekStart(containing: now)
        if now < rollover(forWeekStarting: start) { start = ET.addDays(-7, to: start) }
        let number = WeekStore.weekNumber(for: start)
        if number < 1 {
            return ActiveWeek(number: 1, tab: "W1", key: LineupStore.key(for: WeekStore.seasonStart))
        }
        return ActiveWeek(number: number, tab: "W\(number)", key: LineupStore.key(for: start))
    }

    /// Tuesday 5 pm Pacific of the week that starts on `weekStart` (a Tuesday in ET).
    static func rollover(forWeekStarting weekStart: Date) -> Date {
        let day = ET.cal.dateComponents([.year, .month, .day], from: weekStart)
        var pt = Calendar(identifier: .gregorian)
        pt.timeZone = pacific
        return pt.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 17)) ?? weekStart
    }

    // MARK: Taken

    /// Everyone on a league lineup in `cells` plus everyone on `own`, as ESPN ids.
    @MainActor
    static func taken(cells: [String], directory: PlayerDirectory, own: Lineup) -> TakenPlayers {
        var out = TakenPlayers()
        for p in own.all where !p.isEmpty {
            if let id = p.espnID {
                out.ids.insert(id)
            } else if let match = directory.resolve(name: p.name, teamHint: p.teamHint) {
                out.ids.insert(match.id)
            }
        }
        for raw in cells {
            guard let cell = parseCell(raw) else { continue }
            if let match = resolve(cell, in: directory.players) {
                out.ids.insert(match.id)
            } else {
                out.unmatched.append(LeagueRosters.Entry(
                    name: raw.trimmingCharacters(in: .whitespacesAndNewlines), team: "", owner: "from the sheet"
                ))
            }
        }
        return out
    }
}

// MARK: - Fetching

enum LeagueSheetClient {
    enum FetchError: LocalizedError {
        case badLink, network, notShared, tabMissing(String), tooFew(Int)

        var errorDescription: String? {
            switch self {
            case .badLink: return "The saved sheet link isn't valid."
            case .network: return "Couldn't reach the league sheet."
            case .notShared: return "The league sheet wouldn't open. Check that link sharing is on."
            case .tabMissing(let tab): return "The \(tab) tab doesn't exist in the sheet yet."
            case .tooFew(let n): return n == 0 ? "The tab has no lineups yet." : "The tab only has \(n) players so far."
            }
        }
    }

    /// A full week lists 12 teams x 14 players. Anything well under that is a tab still being filled in.
    static let minimumPlayers = 120

    /// The sheet id from a pasted link (docs.google.com/spreadsheets/d/<id>/edit...) or a bare id.
    static func sheetID(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = t.captures(#"/spreadsheets/d/([A-Za-z0-9_-]{20,})"#) { return c[0] }
        if t.range(of: #"^[A-Za-z0-9_-]{30,}$"#, options: .regularExpression) != nil { return t }
        return nil
    }

    static func csvURL(id: String, tab: String?) -> URL? {
        var c = URLComponents(string: "https://docs.google.com/spreadsheets/d/\(id)/gviz/tq")
        c?.queryItems = [
            URLQueryItem(name: "tqx", value: "out:csv"),
            URLQueryItem(name: "headers", value: "0"),
        ] + (tab.map { [URLQueryItem(name: "sheet", value: $0)] } ?? [])
        return c?.url
    }

    /// Every cell of the tab that reads as a player, as written.
    static func playerCells(id: String, tab: String) async throws -> [String] {
        guard let url = csvURL(id: id, tab: tab) else { throw FetchError.badLink }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw FetchError.network }
        guard let http = response as? HTTPURLResponse else { throw FetchError.network }
        if http.statusCode == 400 { throw FetchError.tabMissing(tab) }
        guard http.statusCode == 200, let text = String(data: data, encoding: .utf8),
              !text.hasPrefix("<") else { throw FetchError.notShared }
        // Google may answer a tab name it doesn't know with the sheet's first tab. If this reply is identical
        // to the reply with no tab named, the tab isn't there.
        if let plain = csvURL(id: id, tab: nil),
           let (plainData, _) = try? await URLSession.shared.data(from: plain), plainData == data {
            throw FetchError.tabMissing(tab)
        }
        let cells = LeagueSheet.parseCSV(text).flatMap { $0 }.filter { LeagueSheet.parseCell($0) != nil }
        guard cells.count >= minimumPlayers else { throw FetchError.tooFew(cells.count) }
        return cells
    }
}

/// Loads the active week's tab, keeps a copy on disk for each tab, and says where the rosters came from.
@MainActor
final class LeagueSheetStore: ObservableObject {
    static let linkKey = "leagueSheetURL"

    struct Snapshot: Equatable {
        let tab: String
        let cells: [String]
    }

    enum Status: Equatable {
        case idle
        case loading
        case noLink
        case live(tab: String, count: Int)
        case saved(tab: String, date: Date, reason: String)
        /// The active tab wasn't usable, so last week's tab is standing in.
        case older(tab: String, reason: String)
        case unavailable(reason: String)
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var status: Status = .idle
    /// Bumped whenever `snapshot` changes, so views can react without comparing every cell.
    @Published private(set) var revision = 0
    /// When the sheet was last asked, whether or not it had what we wanted.
    @Published private(set) var checkedAt: Date?

    private var lastLive: (tab: String, date: Date)?

    private struct Saved: Codable {
        let fetched: Date
        let cells: [String]
    }

    private static func cacheURL(_ tab: String) -> URL { Storage.url("league-sheet-\(tab).json") }

    private func readSaved(_ tab: String) -> Saved? {
        guard let data = try? Data(contentsOf: Self.cacheURL(tab)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    private func writeSaved(_ tab: String, _ cells: [String]) {
        if let data = try? JSONEncoder().encode(Saved(fetched: Date(), cells: cells)) {
            try? data.write(to: Self.cacheURL(tab), options: .atomic)
        }
    }

    private func set(_ s: Snapshot?, _ st: Status) {
        if snapshot != s { revision += 1 }
        snapshot = s
        status = st
    }

    func load(force: Bool = false) async {
        let week = LeagueSheet.activeWeek()
        guard let id = LeagueSheetClient.sheetID(from: UserDefaults.standard.string(forKey: Self.linkKey) ?? "") else {
            set(nil, .noLink)
            return
        }
        // Don't refetch on every tab switch.
        if !force, let live = lastLive, live.tab == week.tab, Date().timeIntervalSince(live.date) < 300,
           case .live = status { return }

        if snapshot == nil { status = .loading }
        checkedAt = Date()
        do {
            let cells = try await LeagueSheetClient.playerCells(id: id, tab: week.tab)
            writeSaved(week.tab, cells)
            lastLive = (week.tab, Date())
            set(Snapshot(tab: week.tab, cells: cells), .live(tab: week.tab, count: cells.count))
            return
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "Couldn't read the league sheet."
            await fallback(id: id, week: week, reason: reason)
        }
    }

    /// Saved copy of this week's tab, else last week's tab (live, then saved), else nothing.
    private func fallback(id: String, week: LeagueSheet.ActiveWeek, reason: String) async {
        if let saved = readSaved(week.tab) {
            set(Snapshot(tab: week.tab, cells: saved.cells), .saved(tab: week.tab, date: saved.fetched, reason: reason))
            return
        }
        if week.number > 1 {
            let prev = "W\(week.number - 1)"
            if let cells = try? await LeagueSheetClient.playerCells(id: id, tab: prev) {
                set(Snapshot(tab: prev, cells: cells), .older(tab: prev, reason: reason))
                return
            }
            if let saved = readSaved(prev) {
                set(Snapshot(tab: prev, cells: saved.cells), .older(tab: prev, reason: reason))
                return
            }
        }
        set(nil, .unavailable(reason: reason))
    }
}
