//
//  ForgotPasswordView.swift
//  BumpSetCut
//
//  3-step password reset: email → OTP code → new password.
//

import SwiftUI

struct ForgotPasswordView: View {
    let authService: AuthenticationService

    @Environment(\.dismiss) private var dismiss

    enum Step { case email, code, newPassword }

    @State private var step: Step = .email

    // Step 1: Email
    @State private var email = ""
    @State private var isSending = false

    // Step 2: Code
    @State private var otpCode = ""
    @State private var isVerifying = false

    // Step 3: New password
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var saved = false

    @State private var errorMessage: String?
    @FocusState private var isCodeFieldFocused: Bool
    @FocusState private var focusedPasswordField: PasswordField?

    private enum PasswordField: Hashable { case new, confirm }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: BSCSpacing.xl) {
                    Spacer()

                    headerIcon
                    headerText

                    Group {
                        switch step {
                        case .email: emailStep
                        case .code: codeStep
                        case .newPassword: newPasswordStep
                        }
                    }
                    .padding(.horizontal, BSCSpacing.xl)

                    Spacer()
                    Spacer()
                }
            }
            .navigationTitle("Reset Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(step != .email && !saved)
    }

    // MARK: - Header

    private var headerIcon: some View {
        Group {
            switch step {
            case .email:
                Image(systemName: "envelope.badge")
            case .code:
                Image(systemName: "number.square")
            case .newPassword:
                if saved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.bscSuccess)
                } else {
                    Image(systemName: "lock.rotation")
                }
            }
        }
        .bscFont(size: 48, weight: .light)
        .foregroundColor(saved ? .bscSuccess : .bscPrimary)
    }

    private var headerText: some View {
        VStack(spacing: BSCSpacing.sm) {
            Text(headerTitle)
                .bscFont(size: 24, weight: .bold)
                .foregroundColor(.bscTextPrimary)

            Text(headerSubtitle)
                .bscFont(size: 15)
                .foregroundColor(.bscTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .padding(.horizontal, BSCSpacing.lg)
    }

    private var headerTitle: LocalizedStringResource {
        switch step {
        case .email: return "Reset Password"
        case .code: return "Enter Code"
        case .newPassword: return saved ? "Password Updated" : "New Password"
        }
    }

    private var headerSubtitle: LocalizedStringResource {
        switch step {
        case .email: return "Enter your email and we'll send you a reset code."
        case .code: return "Check your email for a reset code."
        case .newPassword: return saved ? "You can now sign in with your new password." : "Choose a strong password for your account."
        }
    }

    // MARK: - Step 1: Email

    private var emailStep: some View {
        VStack(spacing: BSCSpacing.md) {
            TextField("Email", text: $email)
                // The account identifier, so AutoFill files the new password
                // under the right account.
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit {
                    guard isEmailValid, !isSending else { return }
                    Task { await sendCode() }
                }

            errorText

            actionButton(
                title: "Send Code",
                isLoading: isSending,
                disabled: !isEmailValid || isSending
            ) {
                await sendCode()
            }
        }
    }

    // MARK: - Step 2: Code

    private let codeLength = 8

    private var codeStep: some View {
        VStack(spacing: BSCSpacing.md) {
            // Hidden text field that captures keyboard input
            ZStack {
                TextField(text: $otpCode) { EmptyView() }
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($isCodeFieldFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: otpCode) { _, newValue in
                        let filtered = newValue.filter(\.isNumber)
                        if filtered.count > codeLength { otpCode = String(filtered.prefix(codeLength)) }
                        else if filtered != newValue { otpCode = filtered }
                    }

                // Individual digit boxes
                HStack(spacing: BSCSpacing.sm) {
                    ForEach(0..<codeLength, id: \.self) { index in
                        let char = index < otpCode.count
                            ? String(otpCode[otpCode.index(otpCode.startIndex, offsetBy: index)])
                            : ""

                        // Flexible width + min height so the digits grow with
                        // Dynamic Type instead of clipping in a fixed box.
                        Text(verbatim: char)
                            .bscFont(size: 24, weight: .semibold, design: .monospaced)
                            .foregroundColor(.bscTextPrimary)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                                    .fill(Color.bscSurfaceGlass)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                                    .stroke(
                                        index == otpCode.count ? Color.bscPrimary : Color.bscSurfaceBorder,
                                        lineWidth: index == otpCode.count ? 2 : 1
                                    )
                            )
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isCodeFieldFocused = true
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Reset code")
                .accessibilityValue("\(otpCode.count) of \(codeLength) digits entered")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { isCodeFieldFocused = true }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + BSCDuration.normal) {
                    isCodeFieldFocused = true
                }
            }

            errorText

            actionButton(
                title: "Verify Code",
                isLoading: isVerifying,
                disabled: otpCode.count != codeLength || isVerifying
            ) {
                await verifyCode()
            }

            Button {
                errorMessage = nil
                Task { await sendCode() }
            } label: {
                Text("Resend code")
                    .bscFont(size: 13)
                    .foregroundColor(.bscPrimaryText)
                    .frame(minHeight: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Step 3: New Password

    private var newPasswordStep: some View {
        VStack(spacing: BSCSpacing.md) {
            if saved {
                actionButton(title: "Back to Sign In", isLoading: false, disabled: false) {
                    dismiss()
                }
            } else {
                SecureField("New Password", text: $newPassword)
                    .textContentType(.newPassword)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedPasswordField, equals: .new)
                    .submitLabel(.next)
                    .onSubmit { focusedPasswordField = .confirm }

                if !newPassword.isEmpty {
                    PasswordRequirementsList(password: newPassword)
                }

                SecureField("Confirm Password", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedPasswordField, equals: .confirm)
                    .submitLabel(.done)
                    .onSubmit {
                        guard isPasswordFormValid, !isSaving else { return }
                        Task { await updatePassword() }
                    }

                if !confirmPassword.isEmpty {
                    HStack(spacing: BSCSpacing.xs) {
                        Image(systemName: passwordsMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .bscFont(size: 12)
                            .foregroundColor(passwordsMatch ? .bscSuccessText : .bscErrorText)
                        Text(passwordsMatch ? "Passwords match" : "Passwords do not match")
                            .bscFont(size: 12)
                            .foregroundColor(passwordsMatch ? .bscTextSecondary : .bscErrorText)
                    }
                }

                errorText

                actionButton(
                    title: "Update Password",
                    isLoading: isSaving,
                    disabled: !isPasswordFormValid || isSaving
                ) {
                    await updatePassword()
                }
            }
        }
    }

    // MARK: - Shared Components

    @ViewBuilder
    private var errorText: some View {
        if let errorMessage {
            Text(errorMessage)
                .bscFont(size: 13)
                .foregroundColor(.bscErrorText)
        }
    }

    private func actionButton(title: LocalizedStringResource, isLoading: Bool, disabled: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Group {
                if isLoading {
                    ProgressView().tint(.bscOnPrimary)
                } else {
                    Text(title).bscFont(size: 16, weight: .semibold)
                }
            }
            .foregroundColor(.bscOnPrimary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.bscPrimaryFill)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
    }

    // MARK: - Validation

    private var isEmailValid: Bool {
        email.contains("@") && email.contains(".")
    }

    private var passwordsMatch: Bool {
        newPassword == confirmPassword && !confirmPassword.isEmpty
    }

    private var isPasswordFormValid: Bool {
        PasswordRule.allMet(by: newPassword) && passwordsMatch
    }

    // MARK: - Actions

    private func sendCode() async {
        isSending = true
        errorMessage = nil
        do {
            try await authService.resetPassword(email: email.trimmingCharacters(in: .whitespaces))
            step = .code
        } catch {
            errorMessage = error.localizedDescription
        }
        isSending = false
    }

    private func verifyCode() async {
        isVerifying = true
        errorMessage = nil
        do {
            try await authService.verifyOTP(
                email: email.trimmingCharacters(in: .whitespaces),
                token: otpCode
            )
            step = .newPassword
        } catch {
            errorMessage = String(localized: "Invalid or expired code. Please try again.")
        }
        isVerifying = false
    }

    private func updatePassword() async {
        isSaving = true
        errorMessage = nil
        do {
            try await authService.updatePassword(newPassword: newPassword)
            saved = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
