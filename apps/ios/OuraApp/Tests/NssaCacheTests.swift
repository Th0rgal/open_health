#if TORCH
import XCTest
@testable import OuraApp

final class NssaCacheTests: XCTestCase {
    private let profile = Profile(sex: "M", age: 30, height_m: 1.78, weight_kg: 75, ring_size: 10)

    func testCachedStagesRequireCurrentDemographics() throws {
        let file = "nssa-profile-test-\(UUID().uuidString).json"
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(file)
        defer { try? FileManager.default.removeItem(at: url) }
        let night = NightRow(start_ds: 100, end_ds: 1300, start_unix: 1_790_000_000)
        let entry = StagedNightEntry(fp: "saved-inputs", stages: [1, 2, 3, 4], windowKey: SleepStaging.windowKey(night),
                                     source: "nssa", t0Unix: 1_790_000_000)
        ModelCacheStore.save(file, globalKey: SleepStaging.cacheKey(profile: profile),
                             entries: [night.stagingKey: entry])
        XCTAssertEqual(SleepStaging.cachedStages(nights: [night], profile: profile, cacheFile: file)[night.stagingKey], entry.stages)

        var changed = profile
        changed.weight_kg = 90
        XCTAssertTrue(SleepStaging.cachedStages(nights: [night], profile: changed, cacheFile: file).isEmpty)
        changed = profile; changed.height_m = 1.6
        XCTAssertTrue(SleepStaging.cachedEntries(nights: [night], profile: changed, cacheFile: file).isEmpty)
        changed = profile; changed.age = 45
        XCTAssertTrue(SleepStaging.cachedStages(nights: [night], profile: changed, cacheFile: file).isEmpty)
        changed = profile; changed.sex = "F"
        XCTAssertTrue(SleepStaging.cachedStages(nights: [night], profile: changed, cacheFile: file).isEmpty)

        changed = profile; changed.ring_size = 12
        XCTAssertEqual(SleepStaging.cachedStages(nights: [night], profile: changed, cacheFile: file)[night.stagingKey], entry.stages)

        var extended = night
        extended.end_ds = 1600
        XCTAssertTrue(SleepStaging.cachedStages(nights: [extended], profile: profile, cacheFile: file).isEmpty)
        extended = night; extended.end_unix = 1_790_001_500
        XCTAssertTrue(SleepStaging.cachedEntries(nights: [extended], profile: profile, cacheFile: file).isEmpty)
    }

    func testUnscopedOldCacheCannotClaimCurrentDemographics() {
        let file = "nssa-old-key-test-\(UUID().uuidString).json"
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(file)
        defer { try? FileManager.default.removeItem(at: url) }
        let night = NightRow(start_ds: 100)
        ModelCacheStore.save(file, globalKey: ModelCacheStore.globalKey(profile: nil, timezone: false),
                             entries: [night.stagingKey: StagedNightEntry(fp: "old", stages: [2, 2])])
        XCTAssertTrue(SleepStaging.cachedStages(nights: [night], profile: nil, cacheFile: file).isEmpty)
    }

    func testPreviousSummaryCannotBypassEditedDemographics() {
        let night = NightRow(start_ds: 100, end_ds: 1300)
        var saved = night
        saved.stages = [1, 2, 3, 4]
        saved.staging_source = "nssa"
        var previous = Summary(nights: [saved])
        previous.profile = profile
        let same = Core.automaticSleepPlan(nights: [night], previous: previous, profile: profile)
        XCTAssertEqual(same.saved[night.stagingKey], saved.stages)
        XCTAssertTrue(same.pending.isEmpty)

        var changed = profile; changed.weight_kg = 90
        let edited = Core.automaticSleepPlan(nights: [night], previous: previous, profile: changed)
        XCTAssertTrue(edited.saved.isEmpty)
        XCTAssertEqual(edited.pending.map(\.stagingKey), [night.stagingKey])
    }

    func testOldSleepNetSummaryDoesNotSkipNssa() {
        let night = NightRow(start_ds: 100, end_ds: 1300)
        var saved = night
        saved.stages = [1, 2, 3, 4]
        saved.staging_source = "sleepnet"
        let plan = Core.automaticSleepPlan(nights: [night], previous: Summary(nights: [saved]))
        XCTAssertTrue(plan.saved.isEmpty)
        XCTAssertEqual(plan.pending.map(\.stagingKey), [night.stagingKey])
    }

    func testDefaultAndUnrelatedSettingsKeepTheSameModelKey() {
        var defaults = profile
        defaults.ring_size = nil
        XCTAssertEqual(SleepStaging.cacheKey(profile: nil), SleepStaging.cacheKey(profile: defaults))
        var sameInputs = profile
        sameInputs.age = 30.9
        sameInputs.sex = "Male"
        sameInputs.ring_size = 7
        XCTAssertEqual(SleepStaging.cacheKey(profile: profile), SleepStaging.cacheKey(profile: sameInputs))
    }
}
#endif
