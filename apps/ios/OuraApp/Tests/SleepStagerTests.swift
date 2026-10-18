import XCTest
@testable import OuraApp

final class SleepStagerTests: XCTestCase {
    func testStatusOffersTheBuiltInStagerAndReportsMissingOfficialClassifier() throws {
        let status = try XCTUnwrap(SleepStagerStatus.load())
        let builtIn = try XCTUnwrap(status.options.first { $0.id == "xgb" })
        XCTAssertTrue(builtIn.available)
        let official = try XCTUnwrap(status.options.first { $0.id == "official" })
        XCTAssertEqual(official.available, ModelFiles.officialSleepStager)
        if !official.available {
            XCTAssertEqual(status.effective, "xgb")
            XCTAssertNotNil(official.notice)
        } else {
            XCTAssertNil(official.notice)
        }
    }

    func testNightsKeepSeparateStagingCachesPerStager() {
        XCTAssertNotEqual(ModelCacheStore.stagingFile(for: "official"), ModelCacheStore.stagingFile(for: "xgb"))
    }
}
