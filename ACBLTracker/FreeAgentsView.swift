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

/// Every NBA player who isn't on a league team's lineup this week (or on yours).
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

    private let rosters = LeagueRosters.bundled

    private func injury(for p: DirectoryPlayer) -> Injury? {
        directory.injury(for: RosterPlayer(name: p.name, position: .G, teamHint: p.teamAbbr, espnID: p.id))
    }

    private var visible: [DirectoryPlayer] {
        let key = query.normalizedName
        let teamQuery = query.trimmingCharacters(in: .whitespaces).uppercased()
        return pool.filter { p in
            if let want = filter.position, Position.fromESPN(p.position) != want { return false }
            if hideInjured, injury(for: p) != nil { return false }
            if !key.isEmpty {
                return p.name.normalizedName.contains(key) || TeamAlias.canon(p.teamAbbr) == TeamAlias.canon(teamQuery)
            }
            return true
        }
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
                } footer: {
                    Text("Positions here are ESPN's. You pick the league position when you add someone.")
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
                    Text("\(shown.count) available")
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
                recompute()
            }
            .task(id: directory.players.count) {
                await directory.loadInjuries()
                recompute()
            }
            .onChange(of: lineupStore.snapshots) { _, _ in recompute() }
            .sheet(item: $adding) { p in
                AddPlayerView(player: p)
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var statusSection: some View {
        if let key = taken.weekKey, let sheet = taken.sheet {
            if key == LineupStore.currentWeekKey {
                Section {
                    Label("Rosters from the \(sheet) tab of the league sheet", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Label("These rosters are from the \(sheet) tab, not this week. Add this week to LeagueRosters.json so the list is right.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Section {
                Label("No league rosters are bundled, so only your own players are left out.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
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
                Text("If ESPN lists any of them, they show above as free agents. Fix the spelling in LeagueRosters.json.")
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
                        PositionPill(position: Position.fromESPN(p.position))
                        TeamTag(display: display)
                    }
                    if let hurt {
                        Text(hurt.summary).font(.caption2).foregroundStyle(.red)
                    }
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(lineupStore.isEditable ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!lineupStore.isEditable)
    }

    // MARK: Data

    @MainActor
    private func recompute() {
        let weekKey = LineupStore.currentWeekKey
        let result = rosters.taken(
            weekKey: weekKey,
            directory: directory,
            own: lineupStore.resolvedLineup(for: weekKey)
        )
        taken = result

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
