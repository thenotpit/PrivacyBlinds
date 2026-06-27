//
//  SyncGroupCoordinator.swift
//  PrivacyBlinds
//
//  Coordinates "synced" authenticated-gaze unlock. Views that share a non-nil `syncGroup` id unlock and
//  re-lock as a unit, so one Face ID clears the whole group instead of prompting per view. Holds WEAK
//  references to the on-screen models in each group — membership rides the views' appear/disappear, so a
//  group is exactly the matching authenticated-gaze views currently mounted. No-op for `nil` groups.
//

import Foundation

@MainActor
final class SyncGroupCoordinator {
    static let shared = SyncGroupCoordinator()
    /// Not private so tests can drive a fresh, isolated instance per case.
    init() {}

    // Weak per-group membership: a model belongs to a group only while it's on screen.
    private var groups: [String: NSHashTable<PrivacyLensModel>] = [:]
    // Groups whose member is currently presenting the auth sheet (so siblings don't double-prompt).
    private var authenticatingGroups: Set<String> = []

    func register(_ model: PrivacyLensModel, group: String) {
        let table = groups[group] ?? .weakObjects()
        table.add(model)
        groups[group] = table
        // Join an already-unlocked group as unlocked, so a view scrolling into an unlocked group doesn't
        // flash a stray lock screen.
        if table.allObjects.contains(where: { $0 !== model && $0.lockState == .unlocked }) {
            model.unlockViaSync()
        }
    }

    func unregister(_ model: PrivacyLensModel, group: String) {
        groups[group]?.remove(model)
    }

    /// A member authenticated → unlock every still-locked member of the group (no re-prompt).
    func broadcastUnlock(group: String, from: PrivacyLensModel) {
        for member in members(of: group) where member !== from && member.lockState != .unlocked {
            member.unlockViaSync()
        }
    }

    /// A member re-locked → re-lock every still-unlocked member of the group.
    func broadcastRelock(group: String, from: PrivacyLensModel) {
        for member in members(of: group) where member !== from && member.lockState != .locked {
            member.relockViaSync()
        }
    }

    func isAuthenticating(group: String) -> Bool { authenticatingGroups.contains(group) }

    func setAuthenticating(group: String, _ value: Bool) {
        if value { authenticatingGroups.insert(group) } else { authenticatingGroups.remove(group) }
    }

    private func members(of group: String) -> [PrivacyLensModel] {
        groups[group]?.allObjects ?? []
    }
}
