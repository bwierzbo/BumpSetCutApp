//
//  PersistenceMonitor.swift
//  BumpSetCut
//
//  One place where failed saves surface to the user and get retried. Stores
//  report a failure (the root view shows it as a toast) and may register a
//  retry, which runs on the next app background/foreground transition until
//  it succeeds.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class PersistenceMonitor {

    static let shared = PersistenceMonitor()

    /// Latest unacknowledged failure, for the root view's toast.
    private(set) var failureMessage: String?

    /// Pending retries keyed by owner, so repeated failures of the same thing
    /// keep one entry. Each returns true once its save succeeded.
    @ObservationIgnored private var retries: [String: () -> Bool] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "BumpSetCut", category: "Persistence")

    static let defaultFailureMessage = String(localized: "Couldn't save changes. We'll keep trying.")

    /// Surface a failed save. With `retryKey`/`retry`, the save is re-attempted
    /// by `retryPending()` until it reports success.
    func reportFailure(_ error: Error, context: String,
                       retryKey: String? = nil, retry: (() -> Bool)? = nil) {
        logger.error("Save failed (\(context)): \(String(describing: error))")
        failureMessage = Self.defaultFailureMessage
        if let retryKey, let retry {
            retries[retryKey] = retry
        }
    }

    /// Run a save; if it throws, surface it and keep re-running this same
    /// save (the latest one registered per `retryKey` wins) until it lands.
    /// Returns whether this attempt succeeded.
    @discardableResult
    func attempt(_ context: String, retryKey: String, _ save: @escaping () throws -> Void) -> Bool {
        do {
            try save()
            resolve(retryKey: retryKey)
            return true
        } catch {
            reportFailure(error, context: context, retryKey: retryKey) { (try? save()) != nil }
            return false
        }
    }

    /// The owner saved successfully on its own — drop its pending retry.
    func resolve(retryKey: String) {
        retries.removeValue(forKey: retryKey)
    }

    /// Re-attempt every pending save; successful ones are dropped.
    func retryPending() {
        for (key, retry) in retries where retry() {
            retries.removeValue(forKey: key)
        }
    }

    func acknowledgeFailure() {
        failureMessage = nil
    }
}
