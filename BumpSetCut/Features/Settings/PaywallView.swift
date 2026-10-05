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
    @State private var failure: PaywallFailure?

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
                                    title: feature.title,
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

                        // Restore — must stay reachable even when StoreKit
                        // fails to load products (App Review checks this).
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

                        // Legal Text — full auto-renew disclosure
                        VStack(spacing: BSCSpacing.xs) {
                            Text(subscriptionTerms)
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

                                Text(verbatim: "•")
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
            .alert(
                failure.map { Text($0.title) } ?? Text(verbatim: ""),
                isPresented: Binding(
                    get: { failure != nil },
                    set: { if !$0 { failure = nil } }
                ),
                presenting: failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
        }
    }

    // MARK: - Subscription Terms

    /// Full auto-renew disclosure Apple expects adjacent to the purchase
    /// button (name, length, price, billing and cancellation mechanics).
    private var subscriptionTerms: LocalizedStringResource {
        // displayPrice is StoreKit's localized price; the literal is only a
        // fallback while products load.
        let price = storeManager.proMonthlyProduct?.displayPrice ?? "$4.99"
        return LocalizedStringResource(
            "BumpSetCut Pro is a monthly auto-renewing subscription (\(price)/month). Payment will be charged to your Apple ID account at confirmation of purchase. The subscription automatically renews unless it is cancelled at least 24 hours before the end of the current period, and your account will be charged for renewal within 24 hours prior to the end of the current period. You can manage and cancel your subscription in your App Store account settings at any time.",
            comment: "Auto-renew disclosure on the paywall; %@ is the localized monthly price"
        )
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
            failure = .purchase
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
                failure = .nothingToRestore
            }
        } catch {
            failure = .restore
        }
    }
}

/// What went wrong buying or restoring, phrased for the person paying.
private enum PaywallFailure {
    case purchase
    case restore
    case nothingToRestore

    var title: LocalizedStringResource {
        switch self {
        case .purchase: return "Purchase Didn't Go Through"
        case .restore: return "Couldn't Restore Purchases"
        case .nothingToRestore: return "No Subscription Found"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .purchase: return "Your purchase couldn't be completed. Check your connection and try again."
        case .restore: return "We couldn't reach the App Store. Check your connection and try again."
        case .nothingToRestore: return "There's no active BumpSetCut Pro subscription on this Apple ID."
        }
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let icon: String
    let title: LocalizedStringResource
    let description: LocalizedStringResource

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
