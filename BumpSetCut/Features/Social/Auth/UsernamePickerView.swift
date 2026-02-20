//
//  UsernamePickerView.swift
//  BumpSetCut
//
//  Non-dismissable full-screen picker shown after social sign-in
//  when the user has an auto-generated username.
//

import SwiftUI

struct UsernamePickerView: View {
    @Environment(AuthenticationService.self) private var authService
    @State private var viewModel: UsernamePickerViewModel?

    var body: some View {
        ZStack {
            Color.bscBackground.ignoresSafeArea()

            VStack(spacing: BSCSpacing.xl) {
                Spacer()

                // Icon
                ZStack {
                    Circle()
                        .fill(Color.bscPrimary.opacity(0.15))
                        .frame(width: 88, height: 88)

                    Image(systemName: "at")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundColor(.bscPrimary)
                }

                // Title
                VStack(spacing: BSCSpacing.sm) {
                    Text("Choose your username")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.bscTextPrimary)

                    Text("This is how others will find and recognize you.")
                        .font(.system(size: 16))
                        .foregroundColor(.bscTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, BSCSpacing.lg)

                // Username field
                VStack(spacing: BSCSpacing.sm) {
                    HStack(spacing: 0) {
                        Text("@")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.bscTextTertiary)
                            .padding(.leading, BSCSpacing.md)

                        TextField("username", text: Binding(
                            get: { viewModel?.username ?? "" },
                            set: { viewModel?.username = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 18))
                        .foregroundColor(.bscTextPrimary)
                        .padding(.vertical, BSCSpacing.md)
                        .padding(.trailing, BSCSpacing.md)
                        .onChange(of: viewModel?.username ?? "") { _, _ in
                            viewModel?.usernameChanged()
                        }

                        // Availability indicator
                        Group {
                            if viewModel?.isChecking == true {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.bscPrimary)
                            } else if viewModel?.isAvailable == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.bscSuccess)
                            } else if viewModel?.isAvailable == false {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.bscError)
                            }
                        }
                        .frame(width: 24)
                        .padding(.trailing, BSCSpacing.md)
                    }
                    .background(Color.bscSurfaceGlass)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                            .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                    )

                    // Rules text
                    Text("3-20 characters. Letters, numbers, and underscores only.")
                        .font(.system(size: 13))
                        .foregroundColor(.bscTextTertiary)

                    if viewModel?.isAvailable == false {
                        Text("This username is already taken.")
                            .font(.system(size: 13))
                            .foregroundColor(.bscError)
                    }

                    if let error = viewModel?.errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.bscError)
                    }
                }
                .padding(.horizontal, BSCSpacing.xl)

                Spacer()

                // Continue button
                Button {
                    Task { await viewModel?.submit() }
                } label: {
                    if viewModel?.isSubmitting == true {
                        ProgressView()
                            .tint(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.bscPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                    } else {
                        Text("Continue")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.bscPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                    }
                }
                .disabled(viewModel?.canSubmit != true)
                .opacity(viewModel?.canSubmit == true ? 1.0 : 0.5)
                .padding(.horizontal, BSCSpacing.xl)
                .padding(.bottom, BSCSpacing.huge)
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            viewModel = UsernamePickerViewModel(authService: authService)
        }
    }
}
