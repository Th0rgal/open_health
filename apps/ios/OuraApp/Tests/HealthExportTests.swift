import HealthKit
import XCTest
@testable import OuraApp

/// Constructs samples only: no HealthKit permissions, queries, saves or deletes.
final class HealthExportTests: XCTestCase {
    func testRingRmssdIsNeverExportedAsSdnn() {
        var night = NightRow(ymd: "2026-10-10", start_ds: 100, start: "23:00", end: "07:00")
        night.hrv_ms = 72
        night.rhr = 50
        let samples = HealthExport.heartSamples(night, canShare: { _ in true })
            .compactMap { $0 as? HKQuantitySample }
        XCTAssertFalse(samples.contains { $0.quantityType.identifier == HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue })
        XCTAssertTrue(samples.contains { $0.quantityType.identifier == HKQuantityTypeIdentifier.restingHeartRate.rawValue })
        let hrv = samples.first { ($0.metadata?[HKMetadataKeySyncIdentifier] as? String)?.hasPrefix("openoura.hrv.") == true }
        if let expectedType = HealthExport.ringHRVType {
            XCTAssertEqual(hrv?.quantityType, expectedType)
            XCTAssertEqual(hrv?.quantity.doubleValue(for: .secondUnit(with: .milli)), 72)
            XCTAssertEqual(hrv?.metadata?[HKMetadataKeySyncIdentifier] as? String, "openoura.hrv.rmssd.100")
        } else {
            XCTAssertNil(hrv)
        }
        XCTAssertTrue(HealthExport.heartSamples(night, canShare: { _ in false }).isEmpty)
    }

    func testAuthorizationNeverRequestsSdnn() throws {
        let sdnn = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN))
        XCTAssertFalse(HealthExport.shareTypes.contains(sdnn))
        XCTAssertFalse(HealthExport.reconciliationTypes(canShare: { _ in false }).contains(sdnn))
        XCTAssertTrue(HealthExport.reconciliationTypes(canShare: { $0 == sdnn }).contains(sdnn))
        if let rmssd = HealthExport.ringHRVType { XCTAssertTrue(HealthExport.shareTypes.contains(rmssd)) }
    }

    func testLegacyCleanupSelectsOnlyOurTaggedSdnnRecords() throws {
        let sdnn = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN))
        let rhr = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .restingHeartRate))
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func sample(_ type: HKQuantityType, _ id: String?) -> HKQuantitySample {
            HKQuantitySample(type: type, quantity: HKQuantity(unit: type == sdnn ? .secondUnit(with: .milli) : .count().unitDivided(by: .minute()),
                                                           doubleValue: 60), start: at, end: at,
                             metadata: id.map { [HKMetadataKeySyncIdentifier: $0, HKMetadataKeySyncVersion: 1] })
        }
        let legacy = sample(sdnn, "openoura.hrv.100")
        let legitimate = sample(sdnn, "another-export.sdnn.100")
        let untagged = sample(sdnn, nil)
        let otherMetric = sample(rhr, "openoura.hrv.100")
        XCTAssertEqual(HealthExport.legacyHRVSamples([legacy, legitimate, untagged, otherMetric]).map(\.uuid), [legacy.uuid])
    }

    func testHrvMigrationInvalidatesOldExportFingerprint() {
        // Before this fix an empty summary had an empty fingerprint, so an
        // unchanged dataset could skip the cleanup forever after an app upgrade.
        XCTAssertNotEqual(HealthExport.fingerprint(Summary()), "")
        XCTAssertEqual(HealthExport.fingerprint(Summary()), HealthExport.fingerprint(Summary()))
    }
}
