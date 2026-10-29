import SwiftUI

/// Confirmation sheet when you tap a search result: pick the league position, see where he'll land, add.
struct AddPlayerView: View {
    let player: DirectoryPlayer
    var onDone: () -> Void = {}

    @EnvironmentObject var directory: PlayerDirectory
    @EnvironmentObject var lineupStore: LineupStore
    @Environment(\.dismiss) private var dismiss
    @State private var position: Position = .G

    private var destination: String? {
        guard let slot = lineupStore.lineup.firstOpenSlot(for: position) else { return nil }
        switch slot {
        case .starter: return "Starters (\(position.rawValue) spot)"
        case .bench: return "Bench (half points)"
        case .deep: return "Deep bench"
        }
    }

    var body: some View {
        NavigationStack {
            let display = directory.display(for: player)
            Form {
                Section {
                    HStack(spacing: 14) {
                        HeadshotView(url: display.headshot, size: 64, teamColor: display.teamColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.name).font(.headline)
                            TeamTag(display: display)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Picker("Position", selection: $position) {
                        ForEach(Position.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Your league's position for him")
                } footer: {
                    Text("It starts at your league sheet's position for him, or ESPN's if the sheet doesn't list him. Change it if your league has him elsewhere.")
                }

                Section("He'll go to") {
                    if let destination {
                        Text(destination)
                    } else {
                        Text("Your roster is full. Cancel, then swipe a player left and tap Replace.")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button("Add to roster") { add() }
                        .bold()
                        .disabled(destination == nil)
                }
            }
            .navigationTitle("Add player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { position = LeaguePositions.bundled.resolved(for: player) }
        }
        .presentationDetents([.large])
    }

    private func add() {
        let p = RosterPlayer(name: player.name, position: position, teamHint: player.teamAbbr, espnID: player.id)
        lineupStore.add(p)
        onDone()
        dismiss()
    }
}
