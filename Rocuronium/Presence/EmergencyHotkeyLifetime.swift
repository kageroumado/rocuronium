import Foundation

/// Shares one emergency shortcut between visible activity and the agent session.
@MainActor
final class EmergencyHotkeyLifetime {
    enum Owner: Hashable { case overlay, agentSession }
    private var owners: Set<Owner> = []
    private let register: () throws -> Void
    private let unregister: () -> Void

    init(register: @escaping () throws -> Void, unregister: @escaping () -> Void) {
        self.register = register
        self.unregister = unregister
    }

    func acquire(_ owner: Owner) throws {
        guard !owners.contains(owner) else { return }
        if owners.isEmpty { try register() }
        owners.insert(owner)
    }

    func release(_ owner: Owner) {
        guard owners.remove(owner) != nil, owners.isEmpty else { return }
        unregister()
    }

    isolated deinit {
        if !owners.isEmpty { unregister() }
    }
}
