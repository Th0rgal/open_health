import SwiftUI

/// A ring capture feature a measurement depends on. Without data from it the tile stays
/// visible, dimmed, and points to Profile > Ring capture.
enum CaptureNeed {
    case stepMotion, exerciseHR, bloodOxygen, restingHR, ppgSampler

    /// The feature id the ring uses (the same ids as `CaptureFeature.id`).
    var featureId: UInt8 {
        switch self {
        case .exerciseHR: return 0x03
        case .bloodOxygen: return 0x04
        case .restingHR: return 0x08
        case .stepMotion: return 0x0b
        case .ppgSampler: return 0x0d
        }
    }

    /// The feature's name as Ring capture lists it.
    var featureName: String {
        switch self {
        case .stepMotion: return "Step motion"
        case .exerciseHR: return "Exercise heart rate"
        case .bloodOxygen: return "Blood oxygen"
        case .restingHR: return "Resting heart rate"
        case .ppgSampler: return "PPG sampler"
        }
    }

    var hint: String {
        "No data. Turn on \(featureName) in Profile, Ring capture, apply it, then sync."
    }
}

/// Opens Profile, where Ring capture lives. Set once at the root.
private struct OpenRingCaptureKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openRingCapture: () -> Void {
        get { self[OpenRingCaptureKey.self] }
        set { self[OpenRingCaptureKey.self] = newValue }
    }
}
