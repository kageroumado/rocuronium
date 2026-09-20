import Foundation
import Testing
@testable import Rocuronium

/// The approval a human gives for a stretch of work: it stands for its duration, counts down,
/// and ends at once when told to — which is what the stop chord does.
@MainActor
struct StandingApprovalTests {
    @Test func aGrantStandsForItsDurationAndNoLonger() {
        StandingApproval.end()
        #expect(!StandingApproval.isStanding)
        StandingApproval.grant()
        #expect(StandingApproval.isStanding)
        #expect(StandingApproval.secondsLeft > StandingApproval.minutes * 60 - 5)
        StandingApproval.grant(now: Date().addingTimeInterval(-StandingApproval.duration - 1))
        #expect(!StandingApproval.isStanding)
        #expect(StandingApproval.secondsLeft == 0)
    }

    @Test func endingItEndsItAtOnce() {
        StandingApproval.grant()
        StandingApproval.end()
        #expect(!StandingApproval.isStanding)
    }
}
