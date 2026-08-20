import CoreGraphics
import Foundation

/// Where the pointer is at every moment of a gesture.
///
/// A plan is decided entirely up front — waypoints become a smooth curve, the curve is
/// arc-length parameterized so speed is uniform along it, and an easing shapes how that
/// speed starts and stops. What executes it (`HardwareInput.trace`) only walks the samples;
/// keeping the geometry pure is what makes it unit-testable without a cursor.
///
/// Two waypoints trace a straight line. Three or more trace a Catmull-Rom spline — the
/// curve that passes *through* every waypoint, which is what "glide from the tab down into
/// the flyout via this corner" means; nobody aims control points by hand.
nonisolated struct PathPlan {
    private enum Constants {
        /// Samples per second. Real trackpads report at 90–120 Hz; below ~60 the motion is
        /// visibly stepped and hover-intent code that watches velocity sees teleports.
        static let sampleRate = 120.0
        /// Flattening resolution per curve segment for the arc-length table.
        static let flatteningSteps = 64
        static let minimumDuration: Duration = .milliseconds(120)
        static let maximumDuration: Duration = .seconds(10)
        /// Distance-based default: a short hop stays snappy, a cross-screen glide takes
        /// about a second — the speed a person moves a mouse with intent, not urgency.
        static func naturalDuration(for length: Double) -> Duration {
            .seconds(min(max(0.15 + length / 1_500, 0.2), 1.2))
        }
    }

    struct Sample {
        let point: CGPoint
        /// When this sample is due, measured from the start of the gesture.
        let offset: Duration
    }

    enum Easing: String, CaseIterable, Sendable {
        case linear
        case easeIn = "ease-in"
        case easeOut = "ease-out"
        case easeInOut = "ease-in-out"

        /// Maps uniform time 0…1 to path progress 0…1.
        func progress(_ t: Double) -> Double {
            switch self {
            case .linear: t
            case .easeIn: t * t
            case .easeOut: 1 - (1 - t) * (1 - t)
            // Smoothstep: zero velocity at both ends, like a hand starting and stopping.
            case .easeInOut: t * t * (3 - 2 * t)
            }
        }
    }

    let samples: [Sample]
    let length: Double
    let duration: Duration

    var start: CGPoint { samples.first?.point ?? .zero }
    var end: CGPoint { samples.last?.point ?? .zero }

    /// Builds the plan. Returns nil for fewer than two waypoints or a zero-length path —
    /// there is no such gesture, and a caller who sent one has a bug to hear about.
    init?(through waypoints: [CGPoint], duration requested: Duration? = nil, easing: Easing = .easeInOut) {
        guard waypoints.count >= 2 else { return nil }

        // The spine: cubic Bézier segments through every waypoint (Catmull-Rom tangents),
        // flattened into a polyline with cumulative arc lengths.
        var points: [CGPoint] = []
        var cumulative: [Double] = []
        var total = 0.0
        for index in 0 ..< waypoints.count - 1 {
            let segment = Self.bezierSegment(waypoints, index)
            let steps = Constants.flatteningSteps
            for step in (index == 0 ? 0 : 1) ... steps {
                let point = Self.cubic(segment, Double(step) / Double(steps))
                if let last = points.last { total += hypot(point.x - last.x, point.y - last.y) }
                points.append(point)
                cumulative.append(total)
            }
        }
        guard total > 0.5 else { return nil }

        let duration = min(
            max(requested ?? Constants.naturalDuration(for: total), Constants.minimumDuration),
            Constants.maximumDuration,
        )
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        let count = max(2, Int((seconds * Constants.sampleRate).rounded()))

        // Walk the arc-length table monotonically: eased progress → distance → point.
        var samples: [Sample] = []
        var cursor = 0
        for index in 0 ... count {
            let t = Double(index) / Double(count)
            let target = easing.progress(t) * total
            while cursor < cumulative.count - 1, cumulative[cursor + 1] < target { cursor += 1 }
            let segmentLength = cumulative[cursor + 1] - cumulative[cursor]
            let within = segmentLength > 0 ? (target - cumulative[cursor]) / segmentLength : 0
            let a = points[cursor], b = points[cursor + 1]
            samples.append(Sample(
                point: CGPoint(x: a.x + (b.x - a.x) * within, y: a.y + (b.y - a.y) * within),
                offset: .seconds(seconds * t),
            ))
        }

        self.samples = samples
        self.length = total
        self.duration = duration
    }

    // MARK: - Geometry

    /// Control points for the cubic between waypoint `index` and `index + 1`, with
    /// Catmull-Rom tangents (endpoints clamp to themselves, so a 2-point path is a line).
    private static func bezierSegment(_ w: [CGPoint], _ index: Int) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let p0 = w[max(index - 1, 0)]
        let p1 = w[index]
        let p2 = w[index + 1]
        let p3 = w[min(index + 2, w.count - 1)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        return (p1, c1, c2, p2)
    }

    private static func cubic(_ s: (CGPoint, CGPoint, CGPoint, CGPoint), _ t: Double) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * s.0.x + 3 * u * u * t * s.1.x + 3 * u * t * t * s.2.x + t * t * t * s.3.x
        let y = u * u * u * s.0.y + 3 * u * u * t * s.1.y + 3 * u * t * t * s.2.y + t * t * t * s.3.y
        return CGPoint(x: x, y: y)
    }
}
