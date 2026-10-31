import XCTest
@testable import OuraApp

final class ResearchExportTests: XCTestCase {
    /// Parity harness: with `OURA_RESEARCH_REQUEST` naming a JSON file
    /// {"db", "out_dir", "start", "end", "tz", "streams"}, runs the export through the
    /// app's own bridge so the ZIP can be compared byte for byte with
    /// `oura research-export` and the web dashboard's `/api/research-export`.
    func testResearchExportMatchesDesktop() throws {
        guard let path = ProcessInfo.processInfo.environment["OURA_RESEARCH_REQUEST"] else {
            throw XCTSkip("set OURA_RESEARCH_REQUEST to run the parity export")
        }
        struct Request: Decodable { let db, out_dir: String; let start, end, tz: Double; let streams: [String] }
        let r = try JSONDecoder().decode(Request.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let zip = try researchExport(dbPath: r.db, startUnix: r.start, endUnix: r.end,
                                     streams: r.streams, tzOffsetHours: r.tz, outDir: r.out_dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip))
    }

    func testDefaultWindowIsLastNight() {
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.hour, from: ResearchExportView.defaultStart()), 20)
        XCTAssertEqual(cal.component(.hour, from: ResearchExportView.defaultEnd()), 12)
        XCTAssertLessThan(ResearchExportView.defaultStart(), ResearchExportView.defaultEnd())
    }

    @MainActor
    func testMarkerWriteRunsOffTheMainThreadWithTheTypedLabel() async throws {
        final class Seen: @unchecked Sendable { var onMain: Bool?; var label: String? }
        let seen = Seen()
        let result = await ResearchMarker.save(label: "audio started") { label in
            seen.onMain = Thread.isMainThread
            seen.label = label
            return 1_793_000_000
        }
        XCTAssertEqual(try result.get(), 1_793_000_000)
        XCTAssertEqual(seen.onMain, false)
        XCTAssertEqual(seen.label, "audio started")
    }
}
