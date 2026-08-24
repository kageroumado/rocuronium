import CoreGraphics
import Foundation
import Testing
@testable import Rocuronium

struct ParkLedgerTests {
    private let safari = ParkLedger.WindowRef(pid: 100, title: "Apple — Safari")
    private let finder = ParkLedger.WindowRef(pid: 200, title: "Documents")
    private let notes = ParkLedger.WindowRef(pid: 300, title: "Notes")

    @Test func parkAndUnparkRoundTrip() {
        var ledger = ParkLedger()
        let home = CGRect(x: 80, y: 120, width: 900, height: 600)
        ledger.recordPark(safari, before: home, leaseID: nil)
        #expect(ledger.contains(safari))
        let entry = ledger.recordUnpark(safari)
        #expect(entry?.before == home)
        #expect(ledger.isEmpty)
    }

    @Test func unparkingUnknownWindowReturnsNil() {
        var ledger = ParkLedger()
        #expect(ledger.recordUnpark(safari) == nil)
    }

    /// The first park's frame is the window's real home; a re-park (say, a nudge within the
    /// virtual display) must not overwrite it with a virtual-display position.
    @Test func reparkKeepsTheOriginalBeforeFrame() {
        var ledger = ParkLedger()
        let home = CGRect(x: 80, y: 120, width: 900, height: 600)
        let lease = UUID()
        ledger.recordPark(safari, before: home, leaseID: nil)
        ledger.recordPark(safari, before: CGRect(x: 2600, y: 40, width: 900, height: 600), leaseID: lease)
        #expect(ledger.entries.count == 1)
        #expect(ledger.entries.first?.before == home)
        #expect(ledger.entries.first?.leaseID == lease)
    }

    @Test func autoLeaseDrainsOnlyWhenItsLastWindowLeaves() {
        var ledger = ParkLedger()
        let lease = UUID()
        ledger.recordPark(safari, before: nil, leaseID: lease)
        ledger.recordPark(finder, before: nil, leaseID: lease)

        let first = ledger.recordUnpark(safari)
        #expect(first?.leaseID == lease)
        #expect(!ledger.leaseIsDrained(lease))

        ledger.recordUnpark(finder)
        #expect(ledger.leaseIsDrained(lease))
    }

    /// Explicit-lease parks carry no lease id, and a nil lease is never "drained" — an
    /// explicit lease releases when its holder says so, not when windows move.
    @Test func explicitParksNeverDrainAnything() {
        var ledger = ParkLedger()
        ledger.recordPark(safari, before: nil, leaseID: nil)
        let entry = ledger.recordUnpark(safari)
        #expect(entry?.leaseID == nil)
        #expect(!ledger.leaseIsDrained(nil))
    }

    @Test func removeAllUnderLeaseTakesOnlyThatLeasesWindows() {
        var ledger = ParkLedger()
        let auto = UUID()
        ledger.recordPark(safari, before: nil, leaseID: auto)
        ledger.recordPark(finder, before: nil, leaseID: nil)

        let removed = ledger.removeAll(under: auto)
        #expect(removed.map(\.window) == [safari])
        #expect(ledger.entries.map(\.window) == [finder])

        let rest = ledger.removeAll()
        #expect(rest.map(\.window) == [finder])
        #expect(ledger.isEmpty)
    }

    @Test func straysAreTheUnparkedRemainder() {
        let onDisplay = [safari, finder, notes]
        let strays = ParkLedger.strays(onVirtualDisplay: onDisplay, parked: [safari])
        #expect(strays == [finder, notes])
    }

    /// Same title in two processes: pid is part of the identity, so parking one must not
    /// vouch for the other.
    @Test func strayIdentityIncludesThePid() {
        let twin = ParkLedger.WindowRef(pid: 999, title: safari.title)
        let strays = ParkLedger.strays(onVirtualDisplay: [safari, twin], parked: [safari])
        #expect(strays == [twin])
    }

    @Test func noStraysWhenEverythingIsParked() {
        #expect(ParkLedger.strays(onVirtualDisplay: [safari], parked: [safari, finder]).isEmpty)
        #expect(ParkLedger.strays(onVirtualDisplay: [], parked: []).isEmpty)
    }
}
