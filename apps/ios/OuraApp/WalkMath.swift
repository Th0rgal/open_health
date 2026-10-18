import Foundation

/// One location fix of a recorded route.
struct RoutePoint: Codable, Equatable {
    var t: Double        // unix seconds
    var lat: Double
    var lon: Double
    var acc: Double      // horizontal accuracy, meters
}

/// Distance and window selection for the 6-minute walk estimate of VO2 max. Pure functions,
/// no location or motion framework, so the rules are testable.
enum WalkMath {
    /// Fixes less accurate than this are dropped.
    static let maxAccuracyM = 25.0
    /// A step between two fixes faster than this is a GPS jump, not walking or running.
    static let maxStepSpeedMS = 12.0
    /// Walking window rules. A pause longer than `maxGapS` inside the window, or a window longer
    /// than `maxWalkDistanceM` (a run), is not a walking test.
    static let windowS = 360.0
    static let maxGapS = 30.0
    static let maxWalkDistanceM = 900.0

    static func meters(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = p2 - p1, dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Points in time order with poor fixes and impossible jumps removed.
    static func clean(_ points: [RoutePoint]) -> [RoutePoint] {
        var out: [RoutePoint] = []
        for p in points.sorted(by: { $0.t < $1.t }) where p.acc >= 0 && p.acc <= maxAccuracyM {
            if let last = out.last {
                let dt = p.t - last.t
                guard dt > 0 else { continue }
                if meters(last, p) / dt > maxStepSpeedMS { continue }
            }
            out.append(p)
        }
        return out
    }

    /// Length of the cleaned route, meters.
    static func totalDistance(_ points: [RoutePoint]) -> Double {
        let p = clean(points)
        return zip(p, p.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }

    /// The 6-minute stretch of a route with the greatest distance among those that qualify as a
    /// walking window. Returns its start time and distance.
    static func bestWindow(_ points: [RoutePoint]) -> (startUnix: Double, distanceM: Double)? {
        let p = clean(points)
        guard p.count > 1 else { return nil }
        var cumulative = [0.0]
        for i in 1..<p.count { cumulative.append(cumulative[i - 1] + meters(p[i - 1], p[i])) }
        /// Cumulative distance at time `t`, interpolated between the two fixes around it.
        func at(_ t: Double, from i: Int) -> (Double, Int)? {
            var j = i
            while j < p.count && p[j].t < t { j += 1 }
            guard j < p.count else { return nil }
            if j == 0 { return (cumulative[0], 0) }
            let span = p[j].t - p[j - 1].t
            let f = span > 0 ? (t - p[j - 1].t) / span : 1
            return (cumulative[j - 1] + (cumulative[j] - cumulative[j - 1]) * f, j)
        }
        var best: (Double, Double)?
        for i in 0..<p.count {
            guard let (end, j) = at(p[i].t + windowS, from: i) else { break }
            var gap = 0.0
            for k in i..<j { gap = max(gap, p[k + 1].t - p[k].t) }
            guard gap <= maxGapS else { continue }
            let distance = end - cumulative[i]
            guard distance <= maxWalkDistanceM else { continue }
            if best == nil || distance > best!.1 { best = (p[i].t, distance) }
        }
        return best.map { (startUnix: $0.0, distanceM: $0.1) }
    }

    /// The best run of `minutes` consecutive entries of per-minute distances, for sources that
    /// report distance in fixed slices (the phone's step counter). Returns the first slice's
    /// index and the summed distance; windows containing a slice without data (nil) do not count.
    static func bestMinuteWindow(_ perMinute: [Double?], minutes: Int = 6) -> (start: Int, distanceM: Double)? {
        guard perMinute.count >= minutes else { return nil }
        var best: (Int, Double)?
        for i in 0...(perMinute.count - minutes) {
            let slice = perMinute[i..<(i + minutes)]
            guard !slice.contains(where: { $0 == nil }) else { continue }
            let d = slice.reduce(0) { $0 + ($1 ?? 0) }
            guard d <= maxWalkDistanceM else { continue }
            if best == nil || d > best!.1 { best = (i, d) }
        }
        return best.map { (start: $0.0, distanceM: $0.1) }
    }

    /// Median of a list, nil when empty.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}
