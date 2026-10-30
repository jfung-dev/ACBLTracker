import SwiftUI

/// Tap a player on the Lineup tab: the stat line for each of his two counting games,
/// how each one scored, and how he's played lately.
struct PlayerDetailView: View {
    let player: RosterPlayer
    @EnvironmentObject var week: WeekStore
    @EnvironmentObject var directory: PlayerDirectory
    @Environment(\.dismiss) private var dismiss

    /// Full box scores keyed by ESPN event id, one per counting game that has started.
    @State private var boxes: [String: FullBox] = [:]
    @State private var boxFailed: Set<String> = []
    /// Games already fetched after going final, so a finished game isn't fetched again.
    @State private var finalLoaded: Set<String> = []

    /// One of his two counting games, once it has started (live or final).
    private func startedLine(_ g: Int) -> GameLine? {
        guard let line = week.results?.line(for: player.id, game: g), line.state != .scheduled else { return nil }
        return line
    }

    /// Changes when a game starts, or goes from live to final, which restarts the box score task.
    private var boxTaskKey: String {
        (0..<2).map { g in startedLine(g).map { "\($0.eventID)-\($0.state)" } ?? "-" }.joined(separator: "|")
    }

    var body: some View {
        let display = directory.display(for: player)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        HeadshotView(url: display.headshot, size: 64, teamColor: display.teamColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.name).font(.title3.bold())
                            HStack(spacing: 6) {
                                PositionPill(position: player.position)
                                TeamTag(display: display)
                            }
                            if let injury = week.injury(for: player) {
                                Text(injury.summary).font(.caption.weight(.semibold)).foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let injury = week.injury(for: player), injury.hasDrillDown {
                    Section {
                        NavigationLink {
                            InjuryDetailView(playerName: player.name, injury: injury)
                        } label: {
                            HStack {
                                Text("Injury details")
                                Spacer()
                                Text(injury.status).foregroundStyle(.red).font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                }

                // Newest first. Each game is followed by its own box score.
                gameSection(1)
                boxScoreSection(1)
                gameSection(0)
                boxScoreSection(0)

                RecentFormSection(athleteID: player.espnID, fallback: { week.savedGames(for: player.id) })

                if let total = week.results?.playerTotal(player.id) {
                    Section("This week") {
                        HStack {
                            Text("Points counted")
                            Spacer()
                            Text("\(total)").font(.title3.bold()).monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(player.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            // Restarts when a game starts or ends. Polls only while a game is live, and stops when the sheet closes.
            .task(id: boxTaskKey) { await loadBoxes() }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: One game

    @ViewBuilder
    private func gameSection(_ g: Int) -> some View {
        let line = week.results?.line(for: player.id, game: g)
        let result = week.results?.result(for: player.id, game: g)

        Section {
            if let line {
                if line.state == .scheduled {
                    HStack {
                        Text("Tips off")
                        Spacer()
                        Text(line.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                } else if line.points == nil {
                    Text(result?.availability.isDNP == true ? "Did not play" : "Waiting for the box score")
                        .foregroundStyle(result?.availability.isDNP == true ? Color.red : Color.secondary)
                } else {
                    statGrid(line)
                }
                if let result, line.state != .scheduled {
                    HStack {
                        Text(roleText(result)).foregroundStyle(.secondary)
                        Spacer()
                        if result.isCounted {
                            Text(result.bonus > 0 ? "\(result.countedPoints) + \(result.bonus) bonus" : "\(result.countedPoints) counted")
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                    }
                    .font(.subheadline)
                }
            } else {
                Text("No game found for this week yet").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("GAME \(g + 1)" + (line.map { " - \($0.opponent)" } ?? ""))
                Spacer()
                if let line, line.state == .live {
                    Text(line.statusText).foregroundStyle(.green)
                } else if let line, line.state == .final {
                    Text(line.statusText)
                }
            }
        }
    }

    private func statGrid(_ line: GameLine) -> some View {
        let b = line.box
        let cells: [(String, String)] = [
            ("PTS", line.points.map(String.init) ?? "-"),
            ("MIN", b?.minutes ?? "-"),
            ("FG", pair(line.fgm, line.fga)),
            ("FG%", percent(line.fgm, line.fga)),
            ("3PT", pair(b?.tpm, b?.tpa)),
            ("FT", pair(b?.ftm, b?.fta)),
            ("REB", num(b?.reb)),
            ("AST", num(b?.ast)),
            ("STL", num(b?.stl)),
            ("BLK", num(b?.blk)),
            ("TO", num(b?.tov)),
            ("+/-", signed(b?.plusMinus)),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 16) {
            ForEach(cells, id: \.0) { cell in
                VStack(spacing: 2) {
                    Text(cell.1).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(cell.0).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Box score

    /// The whole game's box score, both teams, for one of his counting games once it has started. Live or final.
    @ViewBuilder
    private func boxScoreSection(_ g: Int) -> some View {
        if let line = startedLine(g) {
            Section {
                if let box = boxes[line.eventID] {
                    LiveBoxScoreView(
                        box: box,
                        highlightID: player.espnID,
                        teamID: player.espnID.flatMap { directory.player(id: $0)?.teamID }
                    )
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                } else if boxFailed.contains(line.eventID) {
                    Text("Couldn't load the box score").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading...").foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text("BOX SCORE - \(line.opponent)")
                    Spacer()
                    Text(line.statusText).foregroundStyle(line.state == .live ? Color.green : Color.secondary)
                }
            }
        }
    }

    /// Loads the box score for each started game. A final game is fetched once. A live game refreshes every
    /// 20 seconds (one ESPN call per live game) until it ends. Stops by itself when the sheet closes.
    private func loadBoxes() async {
        while !Task.isCancelled {
            let lines = (0..<2).compactMap { startedLine($0) }
            let anyLive = lines.contains { $0.state == .live }
            let finalIDs = Set(lines.filter { $0.state == .final }.map { $0.eventID })
            let toFetch = Set(lines.filter { $0.state == .live || !finalLoaded.contains($0.eventID) }.map { $0.eventID })

            let fetched = await withTaskGroup(of: (String, FullBox?).self) { group -> [String: FullBox?] in
                for id in toFetch {
                    group.addTask { (id, try? await ESPNClient.shared.fullBoxscore(eventID: id)) }
                }
                var out: [String: FullBox?] = [:]
                for await (id, result) in group { out[id] = result }
                return out
            }
            if Task.isCancelled { return }
            for (id, result) in fetched {
                if let box = result {
                    boxes[id] = box
                    boxFailed.remove(id)
                    if finalIDs.contains(id) { finalLoaded.insert(id) }
                } else if boxes[id] == nil {
                    boxFailed.insert(id)   // a failed refresh keeps the last box score on screen
                }
            }
            guard anyLive else { return }
            try? await Task.sleep(for: .seconds(20))
        }
    }

    // MARK: Helpers

    private func num(_ v: Int?) -> String { v.map(String.init) ?? "-" }

    private func pair(_ made: Int?, _ att: Int?) -> String {
        guard let made, let att else { return "-" }
        return "\(made)-\(att)"
    }

    private func percent(_ made: Int?, _ att: Int?) -> String {
        guard let made, let att, att > 0 else { return "-" }
        return "\(Int((Double(made) / Double(att) * 100).rounded()))%"
    }

    private func signed(_ v: Int?) -> String {
        guard let v else { return "-" }
        return v > 0 ? "+\(v)" : "\(v)"
    }

    private func roleText(_ r: PlayerGameResult) -> String {
        switch r.role {
        case .starter: return "Starter - full points"
        case .promoted: return "Moved up to starters - full points"
        case .playingSub: return "Playing sub - half points"
        case .notCounted: return r.availability.isDNP ? "Did not play" : "Not counting this game"
        }
    }
}
