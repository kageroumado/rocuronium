import CoreGraphics
import Testing
@testable import Rocuronium

struct PathPlanTests {
    @Test func lineHitsBothEndpoints() throws {
        let plan = try #require(PathPlan(
            through: [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 400)],
            duration: .seconds(0.5),
        ))
        #expect(abs(plan.start.x - 100) < 0.001 && abs(plan.start.y - 100) < 0.001)
        #expect(abs(plan.end.x - 500) < 0.001 && abs(plan.end.y - 400) < 0.001)
        #expect(abs(plan.length - 500) < 1)
        #expect(plan.samples.count >= 2)
    }

    @Test func offsetsAreMonotoneAndSpanTheDuration() throws {
        let plan = try #require(PathPlan(
            through: [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0)],
            duration: .seconds(1),
        ))
        for (a, b) in zip(plan.samples, plan.samples.dropFirst()) {
            #expect(a.offset < b.offset)
        }
        #expect(plan.samples.first?.offset == .zero)
        #expect(plan.samples.last?.offset == plan.duration)
    }

    /// Arc-length parameterization: with linear easing, equal time steps cover equal
    /// distances — even along a curve, where naive t-stepping bunches at tight curvature.
    @Test func linearEasingMovesAtConstantSpeed() throws {
        let plan = try #require(PathPlan(
            through: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 300), CGPoint(x: 400, y: 0)],
            duration: .seconds(1),
            easing: .linear,
        ))
        let steps = zip(plan.samples, plan.samples.dropFirst()).map {
            hypot($1.point.x - $0.point.x, $1.point.y - $0.point.y)
        }
        let mean = steps.reduce(0, +) / Double(steps.count)
        for step in steps {
            #expect(abs(step - mean) < mean * 0.2)
        }
    }

    /// Ease-in-out starts and ends slow: the first tenth of the time covers far less
    /// ground than the middle tenth.
    @Test func easeInOutIsSlowAtTheEndpoints() throws {
        let plan = try #require(PathPlan(
            through: [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0)],
            duration: .seconds(1),
            easing: .easeInOut,
        ))
        let n = plan.samples.count
        func distance(_ range: Range<Int>) -> Double {
            zip(plan.samples[range], plan.samples[range.dropFirst()]).map {
                hypot($1.point.x - $0.point.x, $1.point.y - $0.point.y)
            }.reduce(0, +)
        }
        let tenth = n / 10
        let opening = distance(0 ..< tenth)
        let middle = distance((n / 2 - tenth / 2) ..< (n / 2 + tenth / 2))
        #expect(opening < middle * 0.5)
    }

    /// A Catmull-Rom path passes through its waypoints, not merely near them — that is the
    /// contract that makes "glide via this corner" mean what it says.
    @Test func curvePassesThroughViaWaypoints() throws {
        let via = CGPoint(x: 250, y: 180)
        let plan = try #require(PathPlan(
            through: [CGPoint(x: 0, y: 0), via, CGPoint(x: 500, y: 0)],
            duration: .seconds(1),
        ))
        let closest = plan.samples.map { hypot($0.point.x - via.x, $0.point.y - via.y) }.min() ?? .infinity
        #expect(closest < 2)
    }

    @Test func degeneratePathsAreRefused() {
        #expect(PathPlan(through: []) == nil)
        #expect(PathPlan(through: [CGPoint(x: 5, y: 5)]) == nil)
        #expect(PathPlan(through: [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)]) == nil)
    }

    @Test func durationIsClampedToSaneBounds() throws {
        let short = try #require(PathPlan(
            through: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            duration: .milliseconds(1),
        ))
        #expect(short.duration >= .milliseconds(120))
        let long = try #require(PathPlan(
            through: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            duration: .seconds(600),
        ))
        #expect(long.duration <= .seconds(10))
    }
}
