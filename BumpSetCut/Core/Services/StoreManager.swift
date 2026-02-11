//
//  StoreManager.swift
//  BumpSetCut
//
//  Manages StoreKit 2 subscriptions and purchases.
//

import Foundation
import StoreKit
import Observation
import os

@MainActor
@Observable
final class StoreManager {

    // MARK: - Singleton
    static let shared = StoreManager()

    // MARK: - Published State
    private(set) var products: [Product] = []
    private(set) var purchasedProductIDs: Set<String> = []
    private(set) var isLoading = false

    // MARK: - Product IDs
    enum ProductID {
        static let proMonthly = "com.bumpsetcut.pro.monthly"

        static var allCases: [String] {
            return [proMonthly]
        }
    }

    // MARK: - Private Properties
    private var updateListenerTask: Task<Void, Error>?
    private let logger = Logger(subsystem: "BumpSetCut", category: "StoreManager")

    // MARK: - Initialization

    private init() {
        // Start listening for transaction updates
        updateListenerTask = listenForTransactions()

        Task {
            await loadProducts()
            await updateSubscriptionStatus()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Product Loading

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let products = try await Product.products(for: ProductID.allCases)
            self.products = products.sorted { $0.price < $1.price }
            logger.info("Loaded \(products.count) products")
        } catch {
            logger.error("Failed to load products: \(error.localizedDescription)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async throws -> Transaction? {
        logger.info("Attempting to purchase: \(product.id)")

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)

            // Always finish the transaction
            await transaction.finish()

            // Update subscription status
            await updateSubscriptionStatus()

            logger.info("Purchase successful: \(product.id)")
            return transaction

        case .userCancelled:
            logger.info("User cancelled purchase")
            return nil

        case .pending:
            logger.info("Purchase pending (requires approval)")
            return nil

        @unknown default:
            logger.error("Unknown purchase result")
            return nil
        }
    }

    // MARK: - Subscription Status

    func updateSubscriptionStatus() async {
        var purchasedIDs: Set<String> = []

        // Check all current entitlements
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                // Check if subscription is still active
                if transaction.productID == ProductID.proMonthly {
                    purchasedIDs.insert(transaction.productID)
                }

            } catch {
                logger.error("Failed to verify transaction: \(error.localizedDescription)")
            }
        }

        self.purchasedProductIDs = purchasedIDs
        logger.info("Updated subscription status. Active: \(purchasedIDs.count > 0)")
    }

    // MARK: - Transaction Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)

                    // Update subscription status when new transaction comes in
                    await self.updateSubscriptionStatus()

                    // Always finish the transaction
                    await transaction.finish()

                } catch {
                    self.logger.error("Transaction verification failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async throws {
        logger.info("Restoring purchases...")

        try await AppStore.sync()
        await updateSubscriptionStatus()

        logger.info("Purchases restored")
    }

    // MARK: - Helper Methods

    var hasActiveSubscription: Bool {
        return !purchasedProductIDs.isEmpty
    }

    var proMonthlyProduct: Product? {
        return products.first { $0.id == ProductID.proMonthly }
    }
}

// MARK: - Store Errors

enum StoreError: Error, LocalizedError {
    case failedVerification
    case productNotFound

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "Transaction verification failed"
        case .productNotFound:
            return "Product not found in App Store"
        }
    }
}
