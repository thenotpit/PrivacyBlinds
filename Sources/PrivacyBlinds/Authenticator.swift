//
//  Authenticator.swift
//  PrivacyBlinds
//
//  Face ID / Touch ID / passcode gate for authenticated-gaze mode. Behind a protocol so the
//  lock/unlock state machine can be unit-tested without the biometric hardware.
//

import Foundation
import LocalAuthentication

@MainActor
protocol Authenticating: AnyObject {
    /// Prompt for authentication; calls `completion` on the main actor with success/failure.
    func authenticate(reason: String, completion: @escaping (Bool) -> Void)
}

/// Production authenticator: `.deviceOwnerAuthentication` = Face ID / Touch ID, falling back to the
/// device passcode. Works on any device with a passcode set; no biometric hardware required.
@MainActor
final class BiometricAuthenticator: Authenticating {
    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            let context = LAContext()
            context.localizedFallbackTitle = ""   // straight to passcode fallback, no custom button
            let success = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                             localizedReason: reason)) ?? false
            completion(success)
        }
    }
}
