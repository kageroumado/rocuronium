import Testing
@testable import Rocuronium

@MainActor
struct VirtualDisplaySessionTests {
    @Test(arguments: [false, nil] as [Bool?])
    func creationRefusesOffConsoleAndUnknownSessions(onConsole: Bool?) {
        let manager = VirtualDisplayManager(sessionOnConsole: { onConsole })
        let expected: VirtualDisplayManager.CreationError = onConsole == false ? .offConsole : .sessionUnknown
        #expect(throws: expected) { try manager.create() }
        #expect(manager.display == nil)
        #expect(manager.displayID == nil)
    }

    @Test(arguments: [VirtualDisplayBridge.Lease.Kind.explicit, .auto])
    func refusedCreationLeavesNoExplicitOrParkingLease(kind: VirtualDisplayBridge.Lease.Kind) {
        let manager = VirtualDisplayManager(sessionOnConsole: { false })
        let bridge = VirtualDisplayBridge(engine: Engine(), manager: manager)
        #expect(throws: VirtualDisplayManager.CreationError.offConsole) {
            try bridge.acquire(reason: "isolation regression", kind: kind)
        }
        #expect(bridge.leases.isEmpty)
        #expect(bridge.isAttached == false)
        #expect(bridge.virtualScreenBounds == nil)
    }
}
