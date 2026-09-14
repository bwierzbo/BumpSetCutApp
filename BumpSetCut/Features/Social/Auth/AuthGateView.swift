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
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel: AuthGateViewModel?
    @State private var showForgotPassword = false
    @State private var isPasswordVisible = false
    @State private var isConfirmPasswordVisible = false

    var onSkip: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.bscBackground
                .ignoresSafeArea()

            GeometryReader { geo in
              ScrollView {
                VStack(spacing: BSCSpacing.xl) {
                Spacer(minLength: BSCSpacing.xl)

                // App icon
                ZStack {
                    Circle()
                        .fill(Color.bscPrimary.opacity(0.15))
                        .frame(width: 88, height: 88)

                    Image(systemName: "figure.volleyball")
                        .bscFont(size: 40, weight: .medium)
                        .foregroundColor(.bscPrimary)
                }

                // Title and subtitle
                VStack(spacing: BSCSpacing.sm) {
                    Text("Join the Community")
                        .bscFont(size: 28, weight: .bold)
                        .foregroundColor(.bscTextPrimary)

                    Text("Share your best rallies, discover plays from other players, and connect with the volleyball community.")
                        .bscFont(size: 16)
                        .foregroundColor(.bscTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .padding(.horizontal, BSCSpacing.lg)

                Spacer(minLength: BSCSpacing.lg)

                // Actions
                VStack(spacing: BSCSpacing.md) {
                    if viewModel?.isAuthenticating == true {
                        ProgressView()
                            .tint(.bscPrimary)
                            .scaleEffect(1.2)
                            .frame(height: 50)
                    } else {
                        // Social sign-in
                        SignInWithAppleButton(.continue) { request in
                            viewModel?.configureAppleRequest(request)
                        } onCompletion: { result in
                            Task { await viewModel?.handleAppleCompletion(result) }
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        .accessibilityIdentifier(AccessibilityID.AuthGate.appleSignIn)

                        Button {
                            Task { await viewModel?.signInWithGoogle() }
                        } label: {
                            HStack(spacing: BSCSpacing.sm) {
                                Image(systemName: "globe")
                                    .bscFont(size: 17, weight: .semibold)
                                Text("Continue with Google")
                                    .bscFont(size: 16, weight: .semibold)
                            }
                            .foregroundColor(.bscTextPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.bscBackgroundElevated)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                                    .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                            )
                        }
                        .accessibilityIdentifier(AccessibilityID.AuthGate.googleSignIn)

                        // Divider between social and email auth
                        HStack(spacing: BSCSpacing.md) {
                            Rectangle().fill(Color.bscSurfaceBorder).frame(height: 1)
                            Text("or")
                                .bscFont(size: 13)
                                .foregroundColor(.bscTextSecondary)
                            Rectangle().fill(Color.bscSurfaceBorder).frame(height: 1)
                        }
                        .padding(.vertical, BSCSpacing.xs)

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
                                .bscFont(size: 16, weight: .semibold)
                                .foregroundColor(.bscOnPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.bscPrimaryFill)
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
                                .bscFont(size: 14)
                                .foregroundColor(.bscPrimaryText)
                                .frame(minHeight: BSCTouchTarget.standard)
                                .contentShape(Rectangle())
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
                            .bscFont(size: 15, weight: .medium)
                            .foregroundColor(.bscTextSecondary)
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.AuthGate.skip)
                    .padding(.top, BSCSpacing.xs)
                }
                .padding(.horizontal, BSCSpacing.xl)
                .padding(.bottom, BSCSpacing.huge)
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
              }
              .scrollBounceBehavior(.basedOnSize)
              .scrollDismissesKeyboard(.interactively)
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
        VStack(spacing: BSCSpacing.md) {
            if viewModel?.isSignUpMode == true {
                fieldContainer {
                    HStack {
                        TextField("Username", text: Binding(
                            get: { viewModel?.username ?? "" },
                            set: { viewModel?.username = $0 }
                        ))
                        .bscFont(size: 17)
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
                                    .foregroundColor(.bscSuccessText)
                                    .bscFont(size: 18)
                            } else if viewModel?.isUsernameAvailable == false {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.bscErrorText)
                                    .bscFont(size: 18)
                            }
                        }
                        .frame(width: 22)
                    }
                }
            }

            fieldContainer {
                TextField("Email", text: Binding(
                    get: { viewModel?.email ?? "" },
                    set: { viewModel?.email = $0 }
                ))
                .bscFont(size: 17)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(AccessibilityID.AuthGate.emailField)
            }

            fieldContainer {
                passwordField(
                    placeholder: "Password",
                    text: Binding(
                        get: { viewModel?.password ?? "" },
                        set: { viewModel?.password = $0 }
                    ),
                    isVisible: $isPasswordVisible,
                    accessibilityID: AccessibilityID.AuthGate.passwordField
                )
            }

            // Password requirements (sign-up only)
            if viewModel?.isSignUpMode == true, let vm = viewModel, !vm.password.isEmpty {
                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    passwordReq("8+ characters", met: vm.hasMinLength)
                    passwordReq("One uppercase letter", met: vm.hasUppercase)
                    passwordReq("One number", met: vm.hasNumber)
                    passwordReq("One symbol", met: vm.hasSymbol)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, BSCSpacing.xxs)
            }

            // Confirm password (sign-up only)
            if viewModel?.isSignUpMode == true {
                fieldContainer {
                    passwordField(
                        placeholder: "Confirm Password",
                        text: Binding(
                            get: { viewModel?.confirmPassword ?? "" },
                            set: { viewModel?.confirmPassword = $0 }
                        ),
                        isVisible: $isConfirmPasswordVisible,
                        accessibilityID: AccessibilityID.AuthGate.confirmPasswordField
                    )
                }

                if let vm = viewModel, !vm.confirmPassword.isEmpty {
                    HStack(spacing: BSCSpacing.xs) {
                        Image(systemName: vm.passwordsMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .bscFont(size: 12)
                            .foregroundColor(vm.passwordsMatch ? .bscSuccessText : .bscErrorText)
                        Text(vm.passwordsMatch ? "Passwords match" : "Passwords do not match")
                            .bscFont(size: 12)
                            .foregroundColor(vm.passwordsMatch ? .bscTextSecondary : .bscErrorText)
                        Spacer()
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
                            .bscFont(size: 14)
                            .foregroundColor(.bscPrimaryText)
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.AuthGate.forgotPassword)
                }
            }
        }
    }

    // MARK: - Field Building Blocks

    /// Larger rounded "bubble" container shared by all auth fields.
    private func fieldContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, BSCSpacing.md)
            .padding(.vertical, 14)
            .background(Color.bscBackgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(Color.bscSurfaceBorder, lineWidth: 1)
            )
    }

    /// Password field with a show/hide eye toggle.
    private func passwordField(
        placeholder: String,
        text: Binding<String>,
        isVisible: Binding<Bool>,
        accessibilityID: String
    ) -> some View {
        HStack(spacing: BSCSpacing.sm) {
            Group {
                if isVisible.wrappedValue {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .bscFont(size: 17)
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(accessibilityID)

            Button {
                isVisible.wrappedValue.toggle()
            } label: {
                Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
                    .bscFont(size: 17)
                    .foregroundColor(.bscTextSecondary)
                    .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible.wrappedValue ? "Hide password" : "Show password")
        }
    }

    private func passwordReq(_ label: String, met: Bool) -> some View {
        HStack(spacing: BSCSpacing.xs) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .bscFont(size: 12)
                .foregroundColor(met ? .bscSuccessText : .bscTextSecondary)
            Text(label)
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
        }
    }
}
