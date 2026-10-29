import XCTest
@testable import ACBLTracker

final class LeagueSheetTests: XCTestCase {
    private func player(_ name: String, _ team: String) -> DirectoryPlayer {
        DirectoryPlayer(id: name, name: name, teamID: team, teamAbbr: team, position: "PG", headshot: nil)
    }

    private let players = [
        "Shai Gilgeous-Alexander|OKC", "Jayson Tatum|BOS", "Nikola Jokić|DEN", "Cooper Flagg|DAL",
        "Sandro Mamukelashvili|LAL", "Derrick White|BOS", "Colin White|CHA", "Kevin Durant|HOU",
        "Kyle Kuzma|MIL", "CJ McCollum|NO", "Paolo Banchero|ORL", "Jaren Jackson Jr.|UTAH",
    ].map { s -> DirectoryPlayer in
        let p = s.split(separator: "|").map(String.init)
        return DirectoryPlayer(id: p[0], name: p[0], teamID: p[1], teamAbbr: p[1], position: "PG", headshot: nil)
    }

    private func who(_ raw: String) -> String? {
        LeagueSheet.parseCell(raw).flatMap { LeagueSheet.resolve($0, in: players) }?.name
    }

    func testCellFormatsResolve() {
        XCTAssertEqual(who("G - SGA (OKC)"), "Shai Gilgeous-Alexander")
        XCTAssertEqual(who("F -- Tatum Bos"), "Jayson Tatum")
        XCTAssertEqual(who("C-- Jackson Uta"), "Jaren Jackson Jr.")
        XCTAssertEqual(who("N. Jokić - DEN - C"), "Nikola Jokić")
        XCTAssertEqual(who("F #32 Cooper Flagg (dal)"), "Cooper Flagg")
        XCTAssertEqual(who("C - Mamu (Mamukelashvili) (Lal)"), "Sandro Mamukelashvili")
        XCTAssertEqual(who("F - Banchero (INJ)"), "Paolo Banchero")
    }

    func testTeamAndInitialPickTheRightSameLastName() {
        XCTAssertEqual(who("G C.White (Chlt)"), "Colin White")
        XCTAssertEqual(who("G D. White"), "Derrick White")
        XCTAssertEqual(who("G C.J. McCollum"), "CJ McCollum")
    }

    func testNonPlayerCellsAreIgnored() {
        for junk in ["Brun and Gun", "Highlights", "dnp", "40+5", "Fri", "C", "G", "23", "Final", "Commish: Scott"] {
            XCTAssertNil(LeagueSheet.parseCell(junk), junk)
        }
    }

    func testCSVHandlesQuotesAndNewlines() {
        let rows = LeagueSheet.parseCSV("\"G - SGA (OKC)\",\"say \"\"hi\"\"\"\r\n\"two\nlines\",,x\n")
        XCTAssertEqual(rows, [["G - SGA (OKC)", "say \"hi\""], ["two\nlines", "", "x"]])
    }

    func testSheetIDFromLink() {
        let id = "1A-e0RZJ-ccr9vSWwpQzHuR4tlcPMHlxONrbnQJR1oso"
        XCTAssertEqual(LeagueSheetClient.sheetID(from: "https://docs.google.com/spreadsheets/d/\(id)/edit?usp=sharing"), id)
        XCTAssertEqual(LeagueSheetClient.sheetID(from: id), id)
        XCTAssertNil(LeagueSheetClient.sheetID(from: "https://example.com"))
        XCTAssertEqual(LeagueSheetClient.csvURL(id: id, tab: "W3")?.query, "tqx=out:csv&sheet=W3&headers=0")
    }

    // MARK: Tab rollover (Tuesday 5 pm Pacific)

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testWeekTwoUntilTuesdayFivePM() {
        // Wed Oct 28 2026
        XCTAssertEqual(LeagueSheet.activeWeek(now: date("2026-10-28T18:00:00Z")).tab, "W2")
        // Tue Nov 3, 4:59 pm PST = 00:59Z Nov 4
        XCTAssertEqual(LeagueSheet.activeWeek(now: date("2026-11-04T00:59:00Z")).tab, "W2")
    }

    func testWeekThreeStartsTuesdayFivePM() {
        // Tue Nov 3, 5:00 pm PST = 01:00Z Nov 4
        let w = LeagueSheet.activeWeek(now: date("2026-11-04T01:00:00Z"))
        XCTAssertEqual(w.tab, "W3")
        XCTAssertEqual(w.key, "2026-11-03")
        XCTAssertEqual(LeagueSheet.activeWeek(now: date("2026-11-10T00:59:00Z")).tab, "W3")
        XCTAssertEqual(LeagueSheet.activeWeek(now: date("2026-11-10T01:00:00Z")).tab, "W4")
    }

    func testRolloverBeforeSeasonIsWeekOne() {
        XCTAssertEqual(LeagueSheet.activeWeek(now: date("2026-10-10T18:00:00Z")).tab, "W1")
    }
}
