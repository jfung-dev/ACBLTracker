import SwiftUI

/// The "Recent form" section: last few games from ESPN's game log, a hot/cold marker and a rolling average.
/// Shared by the lineup player sheet and the Free Agents Add player sheet. Drop it inside a List or Form.
struct RecentFormSection: View {
    /// ESPN athlete id. Nil when the player isn't matched to ESPN yet.
    let athleteID: String?
    /// Games saved in this app, used when ESPN's game log is empty early in the season.
    var fallback: () -> [RecentGame] = { [] }

    @State private var recent: [RecentGame]?
    @State private var failed = false

    var body: some View {
        Section {
            if let recent {
                if recent.isEmpty {
                    Text("No games played yet this season").foregroundStyle(.secondary)
                } else {
                    ForEach(recent) { recentRow($0) }
                }
            } else if failed {
                HStack {
                    Text("Couldn't load recent games").foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { Task { await load() } }.buttonStyle(.borderless)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading...").foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("RECENT FORM")
                Spacer()
                if let avg = averageText { Text((formEmoji.map { $0 + " " } ?? "") + avg) }
            }
        }
        .task(id: athleteID) { await load() }
    }

    private func load() async {
        failed = false
        var games: [RecentGame] = []
        var loadError = false
        if let id = athleteID {
            do {
                games = try await ESPNClient.shared.gameLog(athleteID: id)
            } catch {
                // A cancelled task (sheet closing, view refresh) isn't a failure and shouldn't leave "no games" behind.
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                loadError = true
            }
        }
        // ESPN's game log can lag early in the season; fall back to games already saved in this app.
        if games.isEmpty { games = fallback() }
        if games.isEmpty && loadError {
            failed = true
            recent = nil
        } else {
            recent = games
        }
    }

    private var averageText: String? {
        guard let recent else { return nil }
        let pts = recent.compactMap { $0.points }
        guard !pts.isEmpty else { return nil }
        let avg = Double(pts.reduce(0, +)) / Double(pts.count)
        return "\(pts.count)-game avg \(String(format: "%.1f", avg)) pts"
    }

    /// Needs 2+ games. Hot/cold by scoring average (30+ is where the bonus starts), plus a trend arrow when there are 4+.
    private var formEmoji: String? {
        guard let recent else { return nil }
        let pts = recent.compactMap { $0.points }   // newest first
        guard pts.count >= 2 else { return nil }
        let avg = Double(pts.reduce(0, +)) / Double(pts.count)
        var out = ""
        if avg >= 30 { out = "\u{1F525}\u{1F525}" } else if avg >= 22 { out = "\u{1F525}" } else if avg < 10 { out = "\u{1F9CA}" }
        if pts.count >= 4 {
            let lastTwo = Double(pts.prefix(2).reduce(0, +)) / 2
            let earlier = Double(pts.dropFirst(2).reduce(0, +)) / Double(pts.count - 2)
            if lastTwo - earlier >= 5 { out += "\u{1F4C8}" } else if earlier - lastTwo >= 5 { out += "\u{1F4C9}" }
        }
        return out.isEmpty ? nil : out
    }

    private func gameEmoji(_ pts: Int?) -> String {
        guard let pts else { return "" }
        if pts >= 40 { return "\u{1F680} " }   // rocket: +5 bonus
        if pts >= 30 { return "\u{1F525} " }   // fire: +2 bonus
        if pts == 0 { return "\u{1F634} " }    // sleeping: DNP or goose egg
        if pts <= 8 { return "\u{1F9CA} " }    // ice
        return ""
    }

    private func recentRow(_ game: RecentGame) -> some View {
        var parts: [String] = []
        if let fg = game.fg { parts.append("\(fg) FG") }
        if let reb = game.reb { parts.append("\(reb) reb") }
        if let ast = game.ast { parts.append("\(ast) ast") }
        if let min = game.minutes { parts.append("\(min) min") }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.opponent + (game.result.map { " - \($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold))
                Text(game.date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(gameEmoji(game.points) + (game.points.map(String.init) ?? "-")).font(.title3.bold()).monospacedDigit()
                Text(parts.joined(separator: " - "))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
