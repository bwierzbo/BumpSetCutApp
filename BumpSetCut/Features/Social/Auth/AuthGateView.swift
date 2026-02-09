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
                        // Email form
                        emailForm

                        // Primary email action
                        Button {
                            Task {
                                if viewModel?.isSignUpMode == true {
                                    await viewModel?.signUpWithEmail()
                                } else {
                                    await viewModel?.signInWithEmail()
                                }
                            }
                        } label: {
                            Text(viewModel?.isSignUpMode == true ? "Sign Up" : "Sign In")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.bscOrange)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        }
                        .disabled(viewModel?.isEmailFormValid != true)
                        .opacity(viewModel?.isEmailFormValid == true ? 1.0 : 0.5)

                        // Toggle sign-up / sign-in
                        Button {
                            viewModel?.isSignUpMode.toggle()
                        } label: {
                            Text(viewModel?.isSignUpMode == true
                                 ? "Already have an account? Sign In"
                                 : "Don't have an account? Sign Up")
                                .font(.system(size: 14))
                                .foregroundColor(.bscOrange)
                        }
                        .buttonStyle(.plain)

                        // Divider
                        HStack {
                            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                            Text("or")
                                .font(.system(size: 13))
                                .foregroundColor(.bscTextTertiary)
                            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                        }
                        .padding(.vertical, BSCSpacing.xs)

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

                        // Sign in with Google
                        Button {
                            Task { await viewModel?.signInWithGoogle() }
                        } label: {
                            HStack(spacing: BSCSpacing.sm) {
                                Image(systemName: "g.circle.fill")
                                    .font(.system(size: 20))
                                Text("Sign in with Google")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        }
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
    }

    // MARK: - Email Form

    private var emailForm: some View {
        VStack(spacing: BSCSpacing.sm) {
            if viewModel?.isSignUpMode == true {
                TextField("Display Name", text: Binding(
                    get: { viewModel?.displayName ?? "" },
                    set: { viewModel?.displayName = $0 }
                ))
                .textContentType(.name)
                .autocorrectionDisabled()
            }

            TextField("Email", text: Binding(
                get: { viewModel?.email ?? "" },
                set: { viewModel?.email = $0 }
            ))
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            SecureField("Password", text: Binding(
                get: { viewModel?.password ?? "" },
                set: { viewModel?.password = $0 }
            ))
            .textContentType(viewModel?.isSignUpMode == true ? .newPassword : .password)

            // Password requirements (sign-up only)
            if viewModel?.isSignUpMode == true, let vm = viewModel, !vm.password.isEmpty {
                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    passwordReq("12+ characters", met: vm.hasMinLength)
                    passwordReq("One uppercase letter", met: vm.hasUppercase)
                    passwordReq("One number", met: vm.hasNumber)
                    passwordReq("One symbol", met: vm.hasSymbol)
                }
                .padding(.top, BSCSpacing.xxs)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func passwordReq(_ label: String, met: Bool) -> some View {
        HStack(spacing: BSCSpacing.xs) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundColor(met ? .bscSuccess : .bscTextTertiary)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(met ? .bscTextSecondary : .bscTextTertiary)
        }
    }
}
