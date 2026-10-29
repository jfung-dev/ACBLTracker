import SwiftUI

private enum PositionFilter: String, CaseIterable, Identifiable {
    case all = "All", g = "G", f = "F", c = "C"

    var id: String { rawValue }

    var position: Position? {
        switch self {
        case .all: return nil
        case .g: return .G
        case .f: return .F
        case .c: return .C
        }
    }
}

/// A scorer who is out injured, shown on his teammates' rows because it usually means more shots for them.
private struct KeyOut: Identifiable {
    let id: String
    let name: String
    let ppg: Double
    let injury: Injury
}

/// Every NBA player who isn't on a league team's lineup in the active week's sheet tab (or on yours), best scorer first.
/// Tap a player to add him with the usual Add player sheet.
struct FreeAgentsView: View {
    @EnvironmentObject var directory: PlayerDirectory
    @EnvironmentObject var lineupStore: LineupStore

    @State private var query = ""
    @State private var filter: PositionFilter = .all
    @State private var hideInjured = false
    @State private var taken = TakenPlayers()
    @State private var pool: [DirectoryPlayer] = []
    @State private var adding: DirectoryPlayer?
    @State private var outByTeam: [String: [KeyOut]] = [:]
    /// League position per ESPN id, worked out once per refresh. The sheet's Positions tab first, ESPN's listing otherwise.
    @State private var positions: [String: Position] = [:]
    @State private var onlyKeyTeammateOut = false
    @StateObject private var averages = SeasonAverages()
    @StateObject private var sheet = LeagueSheetStore()
    @State private var showingLink = false

    /// A teammate counts as a key scorer at this many points per game (this season, or last season until he has played).
    private static let keyScorerPPG = 15.0

    private let rosters = LeagueRosters.bundled

    private func injury(for p: DirectoryPlayer) -> Injury? {
        directory.injury(for: RosterPlayer(name: p.name, position: .G, teamHint: p.teamAbbr, espnID: p.id))
    }

    private func position(of p: DirectoryPlayer) -> Position {
        positions[p.id] ?? Position.fromESPN(p.position)
    }

    private static func isOut(_ injury: Injury) -> Bool { injury.status.lowercased().contains("out") }

    /// Ids of everyone ESPN lists as out, whatever team he is on.
    private var outIDs: [String] {
        directory.injuries.compactMap { id, injury in
            !id.hasPrefix("name:") && Self.isOut(injury) ? id : nil
        }
    }

    /// Key scorers (by team id) who are out, other than the player on the row.
    private func keyOuts(for p: DirectoryPlayer) -> [KeyOut] {
        (outByTeam[p.teamID] ?? []).filter { $0.id != p.id }
    }

    /// Points per game this season, nil until he has played a regular-season game or his average has loaded.
    private func ppg(_ p: DirectoryPlayer) -> Double? {
        guard let a = averages.averages[p.id], a.games > 0 else { return nil }
        return a.ppg
    }

    /// Highest PPG first. Players with no games yet (or no average yet) go last, in name order.
    private var visible: [DirectoryPlayer] {
        let key = query.normalizedName
        let teamQuery = query.trimmingCharacters(in: .whitespaces).uppercased()
        let matches = pool.enumerated().filter { item in
            let p = item.element
            if let want = filter.position, position(of: p) != want { return false }
            if hideInjured, injury(for: p) != nil { return false }
            if onlyKeyTeammateOut, keyOuts(for: p).isEmpty { return false }
            if !key.isEmpty {
                return p.name.normalizedName.contains(key) || TeamAlias.canon(p.teamAbbr) == TeamAlias.canon(teamQuery)
            }
            return true
        }
        return matches.sorted { a, b in
            switch (ppg(a.element), ppg(b.element)) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map { $0.element }
    }

    var body: some View {
        let shown = visible
        NavigationStack {
            List {
                statusSection

                Section {
                    Picker("Position", selection: $filter) {
                        ForEach(PositionFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Hide injured", isOn: $hideInjured)
                    Toggle("Only with a key teammate out", isOn: $onlyKeyTeammateOut)
                    if averages.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading PPG \(averages.done) of \(averages.total)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("PPG is this regular season only. A key teammate is one who scores \(Int(Self.keyScorerPPG))+ PPG (last season's until he has played) and is listed out. 30+ and 40+ count this season's games with that many points, so a 40-point game is in both. Positions come from your league sheet's Positions tab, or ESPN's for anyone it leaves blank.")
                }

                Section {
                    if directory.players.isEmpty {
                        Text("Loading players...").foregroundStyle(.secondary)
                    } else if shown.isEmpty {
                        Text("No free agents match.").foregroundStyle(.secondary)
                    } else {
                        ForEach(shown) { row($0) }
                    }
                } header: {
                    Text("\(shown.count) available, by PPG")
                } footer: {
                    if !lineupStore.isEditable {
                        Text("You're looking at a past week on the Lineup tab. Switch it to the current week to add players.")
                    }
                }

                unmatchedSection
            }
            .listStyle(.insetGrouped)
            .contentMargins(.bottom, 80, for: .scrollContent)
            .searchable(text: $query, prompt: "Search name or team")
            .navigationTitle("Free Agents")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await directory.load(force: true)
                await directory.loadInjuries(force: true)
                await sheet.load(force: true)
                recompute()
                // Don't hold the pull-to-refresh spinner for the whole PPG reload; the tab shows its own progress.
                let ids = pool.map(\.id)
                let injured = outIDs
                Task { await averages.load(ids: ids, injuredIDs: injured, force: true) }
            }
            .task(id: directory.players.count) {
                await sheet.load()
                await directory.loadInjuries()
                recompute()
                await averages.load(ids: pool.map(\.id), injuredIDs: outIDs)
            }
            .onChange(of: averages.averages) { _, _ in recomputeOut() }
            .onChange(of: averages.previous) { _, _ in recomputeOut() }
            .onChange(of: directory.injuries.count) { _, _ in recomputeOut() }
            .onChange(of: lineupStore.snapshots) { _, _ in recompute() }
            .onChange(of: sheet.revision) { _, _ in recompute() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingLink = true } label: { Image(systemName: "link") }
                        .accessibilityLabel("League sheet link")
                }
            }
            .sheet(isPresented: $showingLink, onDismiss: {
                Task {
                    await sheet.load(force: true)
                    recompute()
                }
            }) {
                LeagueSheetLinkView()
            }
            .sheet(item: $adding) { p in
                AddPlayerView(player: p)
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var statusSection: some View {
        let week = LeagueSheet.activeWeek()
        let at = sheet.checkedAt.map { " Checked \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
        switch sheet.status {
        case .live(let tab, let count):
            note("Live from the \(tab) tab of the league sheet (\(count) players).\(at)", systemImage: "checkmark.circle", warn: false)
        case .saved(let tab, let date, let reason):
            note("\(reason) Using the \(tab) copy saved \(date.formatted(.relative(presentation: .named))).\(at)", systemImage: "exclamationmark.triangle.fill", warn: true)
        case .older(let tab, let reason):
            note("\(reason) Using the \(tab) tab instead, so this list may be a week behind.\(at)", systemImage: "exclamationmark.triangle.fill", warn: true)
        case .idle, .loading:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading the \(week.tab) tab...").font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .noLink, .unavailable:
            bundledNote(week: week)
        }
    }

    @ViewBuilder
    private func bundledNote(week: LeagueSheet.ActiveWeek) -> some View {
        let linked: Bool = { if case .unavailable = sheet.status { return true } else { return false } }()
        let why: String = { if case .unavailable(let r) = sheet.status { return r + " " } else { return "" } }()
        let at = sheet.checkedAt.map { " Checked \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
        if let tab = taken.sheet {
            if tab == week.tab && !linked {
                note("Using the bundled \(tab) rosters. Tap the link button and paste your league sheet's link so each new week loads on its own.", systemImage: "info.circle", warn: false)
            } else if tab == week.tab {
                note("\(why)Using the bundled \(tab) rosters.\(at)", systemImage: "exclamationmark.triangle.fill", warn: true)
            } else {
                note("\(why)The bundled rosters are from \(tab), but \(week.tab) is the week to look at. Tap the link button to read it from the sheet.", systemImage: "exclamationmark.triangle.fill", warn: true)
            }
        } else {
            note("\(why)No league rosters are available, so only your own players are left out. Tap the link button to read them from the sheet.", systemImage: "exclamationmark.triangle.fill", warn: true)
        }
    }

    private func note(_ text: String, systemImage: String, warn: Bool) -> some View {
        Section {
            Label(text, systemImage: systemImage)
                .font(.footnote)
                .foregroundStyle(warn ? Color.orange : Color.secondary)
        }
    }

    @ViewBuilder
    private var unmatchedSection: some View {
        if !taken.unmatched.isEmpty {
            Section {
                DisclosureGroup("\(taken.unmatched.count) sheet names didn't match ESPN") {
                    ForEach(taken.unmatched, id: \.self) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.team.isEmpty ? e.name : "\(e.name) (\(e.team))").font(.subheadline)
                            Text(e.owner).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("If ESPN lists any of them, they show above as free agents. Check how they are spelled in the sheet.")
            }
        }
    }

    private func row(_ p: DirectoryPlayer) -> some View {
        let display = directory.display(for: p)
        let hurt = injury(for: p)
        return Button {
            adding = p
        } label: {
            HStack(spacing: 10) {
                HeadshotView(url: display.headshot, size: 40, teamColor: display.teamColor)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        PlayerName(name: p.name)
                        if hurt != nil { InjuryMark() }
                    }
                    HStack(spacing: 6) {
                        PositionPill(position: position(of: p))
                        TeamTag(display: display)
                    }
                    if let hurt {
                        Text(hurt.summary).font(.caption2).foregroundStyle(.red)
                    }
                    keyOutLabel(keyOuts(for: p))
                }
                Spacer()
                ppgLabel(p)
                Image(systemName: "plus.circle")
                    .foregroundStyle(lineupStore.isEditable ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!lineupStore.isEditable)
    }

    /// "Out: P. Banchero (23 PPG), F. Wagner (21 PPG)" in orange, at most two names.
    @ViewBuilder
    private func keyOutLabel(_ outs: [KeyOut]) -> some View {
        if !outs.isEmpty {
            let names = outs.prefix(2).map { "\($0.name.abbreviatedName) (\(Int($0.ppg.rounded())) PPG)" }
            HStack(spacing: 4) {
                Image(systemName: "bandage.fill")
                Text("Out: " + names.joined(separator: ", "))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
        }
    }

    private func ppgLabel(_ p: DirectoryPlayer) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let avg = averages.averages[p.id], avg.games > 0 {
                Text(String(format: "%.1f", avg.ppg))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("\(avg.games) GP")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if avg.games30 > 0 {
                    HStack(spacing: 5) {
                        Text("30+ \u{00D7}\(avg.games30)").foregroundStyle(.orange)
                        if avg.games40 > 0 {
                            Text("40+ \u{00D7}\(avg.games40)").foregroundStyle(.red)
                        }
                    }
                    .font(.system(size: 10, weight: .bold))
                }
            } else if averages.averages[p.id] != nil {
                Text("No games").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("-").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Data

    /// Teams with a key scorer out, biggest scorer first.
    @MainActor
    private func recomputeOut() {
        var map: [String: [KeyOut]] = [:]
        for (id, injury) in directory.injuries where !id.hasPrefix("name:") && Self.isOut(injury) {
            guard let dp = directory.player(id: id),
                  let usage = averages.usagePPG(id), usage >= Self.keyScorerPPG else { continue }
            map[dp.teamID, default: []].append(KeyOut(id: id, name: dp.name, ppg: usage, injury: injury))
        }
        outByTeam = map.mapValues { $0.sorted { $0.ppg > $1.ppg } }
    }

    @MainActor
    private func recompute() {
        recomputeOut()
        let week = LeagueSheet.activeWeek()
        let own = lineupStore.resolvedLineup(for: week.key)
        var result: TakenPlayers
        if let snap = sheet.snapshot {
            result = LeagueSheet.taken(cells: snap.cells, directory: directory, own: own)
            result.sheet = snap.tab
        } else {
            result = rosters.taken(weekKey: week.key, directory: directory, own: own)
        }
        taken = result
        positions = Dictionary(
            directory.players.map { ($0.id, LeaguePositions.bundled.resolved(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )

        func sortKey(_ name: String) -> String {
            name.normalizedName.split(separator: " ").last.map(String.init) ?? name
        }
        pool = directory.players
            .filter { !result.ids.contains($0.id) }
            .map { (player: $0, last: sortKey($0.name)) }
            .sorted { ($0.last, $0.player.name) < ($1.last, $1.player.name) }
            .map { $0.player }
    }
}

/// Where Jon pastes the league sheet link once. It stays on the phone and is not part of the code.
struct LeagueSheetLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LeagueSheetStore.linkKey) private var link = ""

    private var valid: Bool { LeagueSheetClient.sheetID(from: link) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://docs.google.com/spreadsheets/d/...", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !link.isEmpty {
                        Label(valid ? "Looks like a Google Sheets link" : "That doesn't look like a Google Sheets link",
                              systemImage: valid ? "checkmark.circle" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(valid ? Color.secondary : Color.orange)
                    }
                } header: {
                    Text("League sheet link")
                } footer: {
                    let week = LeagueSheet.activeWeek()
                    Text("Paste the link to the ACBL sheet (anyone with the link must be able to open it). The Free Agents tab reads the \(week.tab) tab now and moves to the next week's tab every Tuesday at 5 pm Pacific. The link stays on this phone.")
                }
            }
            .navigationTitle("League sheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
