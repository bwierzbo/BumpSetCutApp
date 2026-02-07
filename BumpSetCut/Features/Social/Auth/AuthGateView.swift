//
//  AuthGateView.swift
//  BumpSetCut
//
//  Sign-in prompt shown when user first tries a social action.
//

import SwiftUI
import AuthenticationServices

struct AuthGateView: View {
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: AuthGateViewModel?

    var body: some View {
        ZStack {
            Color.bscBackground
                .ignoresSafeArea()

            VStack(spacing: BSCSpacing.xl) {
                Spacer()

                // App icon
                ZStack {
                    Circle()
                        .fill(Color.bscOrange.opacity(0.15))
                        .frame(width: 88, height: 88)

                    Image(systemName: "figure.volleyball")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundColor(.bscOrange)
                }

                // Title and subtitle
                VStack(spacing: BSCSpacing.sm) {
                    Text("Join the Community")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.bscTextPrimary)

                    Text("Share your best rallies, discover plays from other players, and connect with the volleyball community.")
                        .font(.system(size: 16))
                        .foregroundColor(.bscTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .padding(.horizontal, BSCSpacing.lg)

                Spacer()

                // Actions
                VStack(spacing: BSCSpacing.md) {
                    if viewModel?.isAuthenticating == true {
                        ProgressView()
                            .tint(.bscOrange)
                            .scaleEffect(1.2)
                            .frame(height: 50)
                    } else {
                        // Sign in with Apple
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName, .email]
                        } onCompletion: { result in
                            switch result {
                            case .success:
                                Task { await viewModel?.signInWithApple() }
                            case .failure(let error):
                                if let authError = error as? ASAuthorizationError,
                                   authError.code == .canceled {
                                    // User cancelled — do nothing
                                } else {
                                    viewModel?.errorMessage = error.localizedDescription
                                    viewModel?.showError = true
                                }
                            }
                        }
                        .signInWithAppleButtonStyle(.white)
                        .frame(height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                    }

                    // Continue without account
                    Button {
                        dismiss()
                    } label: {
                        Text("Continue without account")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.bscTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, BSCSpacing.xs)
                }
                .padding(.horizontal, BSCSpacing.xl)
                .padding(.bottom, BSCSpacing.huge)
            }
        }
        .onAppear {
            viewModel = AuthGateViewModel(authService: authService)
        }
        .onChange(of: authService.authState) { _, newState in
            if newState == .authenticated {
                dismiss()
            }
        }
        .alert("Sign In Failed", isPresented: Binding(
            get: { viewModel?.showError ?? false },
            set: { viewModel?.showError = $0 }
        )) {
            Button("OK") { viewModel?.showError = false }
        } message: {
            Text(viewModel?.errorMessage ?? "An unknown error occurred.")
        }
        .preferredColorScheme(.dark)
    }
}
