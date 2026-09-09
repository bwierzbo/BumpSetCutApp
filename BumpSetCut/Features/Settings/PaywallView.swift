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
            ZStack {
                Color.bscBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: BSCSpacing.xl) {
                        // Header
                        VStack(spacing: BSCSpacing.md) {
                            Image(systemName: "crown.fill")
                                .bscFont(size: 60)
                                .foregroundStyle(Color.bscWarningText)
                                .bscShadow(BSCShadow.md)
                                .accessibilityHidden(true)

                            Text("Unlock BumpSetCut Pro")
                                .bscFont(size: 28, weight: .bold)
                                .foregroundColor(.bscTextPrimary)

                            Text("Process unlimited videos, remove watermarks, and work offline")
                                .bscFont(size: 15)
                                .foregroundColor(.bscTextSecondary)
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
                        .padding(.horizontal, BSCSpacing.lg)

                        // Pricing
                        if let product = storeManager.proMonthlyProduct {
                            VStack(spacing: BSCSpacing.md) {
                                VStack(spacing: BSCSpacing.xs) {
                                    Text(product.displayPrice)
                                        .bscFont(size: 48, weight: .bold)
                                        .foregroundColor(.bscTextPrimary)
                                    Text("per month")
                                        .bscFont(size: 15)
                                        .foregroundColor(.bscTextSecondary)
                                }

                                BSCButton(
                                    title: "Subscribe Now",
                                    style: .primary,
                                    isLoading: isPurchasing
                                ) {
                                    Task {
                                        await purchaseSubscription(product)
                                    }
                                }
                                .padding(.horizontal, BSCSpacing.lg)

                                // Restore Button
                                Button {
                                    Task {
                                        await restorePurchases()
                                    }
                                } label: {
                                    Text("Restore Purchases")
                                        .bscFont(size: 15)
                                        .foregroundColor(.bscTextSecondary)
                                        .frame(minHeight: BSCTouchTarget.standard)
                                        .contentShape(Rectangle())
                                }
                                .disabled(isPurchasing)
                            }
                            .padding(.top, BSCSpacing.lg)
                        } else if storeManager.isLoading {
                            ProgressView("Loading products...")
                                .padding(BSCSpacing.lg)
                        } else {
                            Text("Unable to load subscription options")
                                .bscFont(size: 15)
                                .foregroundColor(.bscTextSecondary)
                                .padding(BSCSpacing.lg)
                        }

                        // Legal Text
                        VStack(spacing: BSCSpacing.xs) {
                            Text("Subscription automatically renews unless cancelled at least 24 hours before the end of the current period.")
                                .bscFont(size: 11)
                                .foregroundColor(.bscTextSecondary)
                                .multilineTextAlignment(.center)

                            HStack(spacing: BSCSpacing.sm) {
                                Button {
                                    if let url = URL(string: "https://bumpsetcut.com/terms") {
                                        UIApplication.shared.open(url)
                                    }
                                } label: {
                                    Text("Terms of Service")
                                        .bscFont(size: 13)
                                        .foregroundColor(.bscPrimaryText)
                                        .frame(minHeight: BSCTouchTarget.standard)
                                        .contentShape(Rectangle())
                                }

                                Text("•")
                                    .foregroundColor(.bscTextSecondary)

                                Button {
                                    if let url = URL(string: "https://bumpsetcut.com/privacy") {
                                        UIApplication.shared.open(url)
                                    }
                                } label: {
                                    Text("Privacy Policy")
                                        .bscFont(size: 13)
                                        .foregroundColor(.bscPrimaryText)
                                        .frame(minHeight: BSCTouchTarget.standard)
                                        .contentShape(Rectangle())
                                }
                            }
                        }
                        .padding(.horizontal, BSCSpacing.lg)
                        .padding(.bottom, BSCSpacing.xl)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .bscFont(size: 20)
                            .foregroundStyle(Color.bscTextSecondary)
                    }
                    .accessibilityLabel("Close")
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
                .bscFont(size: 20)
                .foregroundStyle(Color.bscPrimary)
                .frame(width: BSCIconSize.xl)

            VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                Text(title)
                    .bscFont(size: 17, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)

                Text(description)
                    .bscFont(size: 15)
                    .foregroundColor(.bscTextSecondary)
            }

            Spacer()
        }
        .bscCardPadding()
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.md)
                .fill(Color.bscSurfaceGlass)
        )
    }
}

#Preview {
    PaywallView()
}
