import Foundation

// Which proprietary model files this build ships. The models (activity detection, illness
// detection, the step counter and cardiovascular age weights) are not part of the public
// repository; a build without them runs with those computations switched off.
enum ModelFiles {
    static func bundled(_ name: String, _ ext: String) -> String? {
        Bundle.main.path(forResource: name, ofType: ext)
    }

    /// The official sleep stager's classifier (extracted from the vendor library, see
    /// tools/extract_nssa_classifier.py). The check runs once and is reported to the shared brain,
    /// which decides the stager in use. The classifier runs in Rust, so no model runtime is involved.
    static let officialSleepStager: Bool = {
        setOfficialSleepStagerClassifier(classifierPath: bundled("sleepstaging_2_6_0_classifier", "bin"))
    }()

    #if TORCH
    static var activityDetection: Bool { bundled("automatic_activity_detection_3_1_15", "ptl") != nil }
    static var illness: Bool { bundled("illness_detection_0_5_1", "ptl") != nil }
    static var cardiovascularAge: Bool { bundled("cva_2_1_5", "ptl") != nil }
    #else
    static var activityDetection: Bool { false }
    static var illness: Bool { false }
    static var cardiovascularAge: Bool { false }
    #endif

    /// The step counter's weights, loaded once. Without them the profile offers only the ring's
    /// own step counter.
    static let stepCounter: Bool = {
        guard let path = bundled("step_counter_1_3_0", "bin") else { return false }
        return stepCounterLoad(path: path)
    }()
}

/// The summary's `sleep_stager` object from the shared brain: the stored choice, the stager in
/// use, and both options with availability and a notice for one that cannot be used.
struct SleepStagerStatus: Codable {
    struct Option: Codable, Identifiable {
        let id: String
        let label: String
        let detail: String
        let available: Bool
        let notice: String?
    }
    let choice: String      // "auto", "official" or "xgb"
    let effective: String
    let options: [Option]
    let notice: String?

    /// Reads the status for the current database; registers the bundled files first.
    static func load() -> SleepStagerStatus? {
        _ = ModelFiles.officialSleepStager
        guard let data = sleepStagerStatusJson(dbPath: DB.readPath()).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SleepStagerStatus.self, from: data)
    }
}
