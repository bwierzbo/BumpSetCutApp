//
//  AuthGateView.swift
//  BumpSetCut
//
//  Sign-in prompt shown when user first tries a social action.
//

import SwiftUI

struct AuthGateView: View {
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: AuthGateViewModel?
    @State private var showForgotPassword = false

    var onSkip: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.bscBackground
                .ignoresSafeArea()

            VStack(spacing: BSCSpacing.xl) {
                Spacer()

                // App icon
                ZStack {
                    Circle()
                        .fill(Color.bscPrimary.opacity(0.15))
                        .frame(width: 88, height: 88)

                    Image(systemName: "figure.volleyball")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundColor(.bscPrimary)
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
                            .tint(.bscPrimary)
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
                                .background(Color.bscPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        }
                        .disabled(viewModel?.isEmailFormValid != true)
                        .opacity(viewModel?.isEmailFormValid == true ? 1.0 : 0.5)
                        .accessibilityIdentifier(AccessibilityID.AuthGate.emailSignIn)

                        // Toggle sign-up / sign-in
                        Button {
                            viewModel?.isSignUpMode.toggle()
                        } label: {
                            Text(viewModel?.isSignUpMode == true
                                 ? "Already have an account? Sign In"
                                 : "Don't have an account? Sign Up")
                                .font(.system(size: 14))
                                .foregroundColor(.bscPrimary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.AuthGate.toggleMode)

                    }

                    // Continue without account
                    Button {
                        if let onSkip = onSkip {
                            onSkip()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Text("Continue without account")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.bscTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.AuthGate.skip)
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
            if newState == .authenticated || newState == .needsUsername {
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
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordView(authService: authService)
        }
    }

    // MARK: - Email Form

    private var emailForm: some View {
        VStack(spacing: BSCSpacing.sm) {
            if viewModel?.isSignUpMode == true {
                HStack {
                    TextField("Username", text: Binding(
                        get: { viewModel?.username ?? "" },
                        set: { viewModel?.username = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier(AccessibilityID.AuthGate.usernameField)
                    .onChange(of: viewModel?.username ?? "") { _, _ in
                        viewModel?.usernameChanged()
                    }

                    // Availability indicator
                    Group {
                        if viewModel?.isCheckingUsername == true {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(.bscPrimary)
                        } else if viewModel?.isUsernameAvailable == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.bscSuccess)
                                .font(.system(size: 16))
                        } else if viewModel?.isUsernameAvailable == false {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.bscError)
                                .font(.system(size: 16))
                        }
                    }
                    .frame(width: 20)
                }
            }

            TextField("Email", text: Binding(
                get: { viewModel?.email ?? "" },
                set: { viewModel?.email = $0 }
            ))
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(AccessibilityID.AuthGate.emailField)

            SecureField("Password", text: Binding(
                get: { viewModel?.password ?? "" },
                set: { viewModel?.password = $0 }
            ))
            .textContentType(.oneTimeCode)
            .accessibilityIdentifier(AccessibilityID.AuthGate.passwordField)

            // Password requirements (sign-up only)
            if viewModel?.isSignUpMode == true, let vm = viewModel, !vm.password.isEmpty {
                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    passwordReq("8+ characters", met: vm.hasMinLength)
                    passwordReq("One uppercase letter", met: vm.hasUppercase)
                    passwordReq("One number", met: vm.hasNumber)
                    passwordReq("One symbol", met: vm.hasSymbol)
                }
                .padding(.top, BSCSpacing.xxs)
            }

            // Confirm password (sign-up only)
            if viewModel?.isSignUpMode == true {
                SecureField("Confirm Password", text: Binding(
                    get: { viewModel?.confirmPassword ?? "" },
                    set: { viewModel?.confirmPassword = $0 }
                ))
                .textContentType(.oneTimeCode)
                .accessibilityIdentifier(AccessibilityID.AuthGate.confirmPasswordField)

                if let vm = viewModel, !vm.confirmPassword.isEmpty {
                    HStack(spacing: BSCSpacing.xs) {
                        Image(systemName: vm.passwordsMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(vm.passwordsMatch ? .bscSuccess : .bscError)
                        Text(vm.passwordsMatch ? "Passwords match" : "Passwords do not match")
                            .font(.system(size: 12))
                            .foregroundColor(vm.passwordsMatch ? .bscTextSecondary : .bscError)
                    }
                }
            }

            // Forgot password (sign-in only)
            if viewModel?.isSignUpMode == false {
                HStack {
                    Spacer()
                    Button {
                        showForgotPassword = true
                    } label: {
                        Text("Forgot password?")
                            .font(.system(size: 13))
                            .foregroundColor(.bscPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.AuthGate.forgotPassword)
                }
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
