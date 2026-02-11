//
//  PaywallView.swift
//  BumpSetCut
//
//  Paywall and subscription management UI.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var storeManager = StoreManager.shared
    @State private var subscriptionService = SubscriptionService.shared
    @State private var isPurchasing = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BSCSpacing.xl) {
                    // Header
                    VStack(spacing: BSCSpacing.md) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.yellow)
                            .shadow(radius: 10)

                        Text("Unlock BumpSetCut Pro")
                            .font(.title.bold())

                        Text("Process unlimited videos, remove watermarks, and work offline")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, BSCSpacing.xl)

                    // Features List
                    VStack(spacing: BSCSpacing.md) {
                        ForEach(SubscriptionService.ProFeature.allCases, id: \.self) { feature in
                            FeatureRow(
                                icon: feature.icon,
                                title: feature.rawValue,
                                description: feature.description
                            )
                        }
                    }
                    .padding(.horizontal)

                    // Pricing
                    if let product = storeManager.proMonthlyProduct {
                        VStack(spacing: BSCSpacing.md) {
                            VStack(spacing: BSCSpacing.xs) {
                                Text(product.displayPrice)
                                    .font(.system(size: 48, weight: .bold))
                                Text("per month")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Button {
                                Task {
                                    await purchaseSubscription(product)
                                }
                            } label: {
                                if isPurchasing {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Subscribe Now")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isPurchasing)
                            .padding(.horizontal)

                            // Restore Button
                            Button {
                                Task {
                                    await restorePurchases()
                                }
                            } label: {
                                Text("Restore Purchases")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .disabled(isPurchasing)
                        }
                        .padding(.top, BSCSpacing.lg)
                    } else if storeManager.isLoading {
                        ProgressView("Loading products...")
                            .padding()
                    } else {
                        Text("Unable to load subscription options")
                            .foregroundStyle(.secondary)
                            .padding()
                    }

                    // Legal Text
                    VStack(spacing: BSCSpacing.xs) {
                        Text("Subscription automatically renews unless cancelled at least 24 hours before the end of the current period.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        HStack(spacing: BSCSpacing.sm) {
                            Button("Terms of Service") {
                                // TODO: Open terms URL
                            }
                            .font(.caption2)

                            Text("•")
                                .foregroundStyle(.secondary)

                            Button("Privacy Policy") {
                                // TODO: Open privacy URL
                            }
                            .font(.caption2)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, BSCSpacing.xl)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Something went wrong")
            }
        }
    }

    // MARK: - Actions

    private func purchaseSubscription(_ product: Product) async {
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let transaction = try await storeManager.purchase(product)

            if transaction != nil {
                // Purchase successful
                await subscriptionService.refreshSubscriptionStatus()
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func restorePurchases() async {
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await storeManager.restorePurchases()
            await subscriptionService.refreshSubscriptionStatus()

            if subscriptionService.isPro {
                dismiss()
            } else {
                errorMessage = "No active subscriptions found"
                showError = true
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: BSCSpacing.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: BSCCornerRadius.md)
                .fill(Color(.systemGray6))
        )
    }
}

#Preview {
    PaywallView()
}
