//
//  ReportContentSheet.swift
//  BumpSetCut
//
//  UI for reporting content.
//

import SwiftUI

struct ReportContentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var moderationService = ModerationService.shared

    let contentType: ReportedContentType
    let contentId: UUID
    let reportedUserId: UUID

    @State private var selectedType: ReportType?
    @State private var description = ""
    @State private var isSubmitting = false
    @State private var showSuccess = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BSCSpacing.xl) {
                    // Header
                    VStack(spacing: BSCSpacing.sm) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .bscFont(size: 48)
                            .foregroundStyle(Color.bscError)

                        Text("Report \(contentType.displayName)")
                            .bscFont(size: 22, weight: .bold)

                        Text("Help us keep the community safe by reporting content that violates our guidelines.")
                            .bscFont(size: 15)
                            .foregroundStyle(Color.bscTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, BSCSpacing.lg)

                    // Report Type Selection
                    VStack(alignment: .leading, spacing: BSCSpacing.md) {
                        Text("What's wrong with this \(contentType.displayName)?")
                            .bscFont(size: 17, weight: .semibold)

                        ForEach(ReportType.allCases, id: \.self) { type in
                            ReportTypeButton(
                                type: type,
                                isSelected: selectedType == type
                            ) {
                                selectedType = type
                            }
                        }
                    }

                    // Additional Details
                    if selectedType != nil {
                        VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                            Text("Additional details (optional)")
                                .bscFont(size: 17, weight: .semibold)

                            TextField("Provide more context...", text: $description, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(3...6)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Submit Button
                    if selectedType != nil {
                        Button {
                            Task {
                                await submitReport()
                            }
                        } label: {
                            if isSubmitting {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.bscOnPrimary)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Submit Report")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.bscOnPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(BSCSpacing.lg)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.bscErrorFill)
                        .disabled(isSubmitting)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(BSCSpacing.lg)
                .animation(.bscSpring, value: selectedType)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Report Submitted", isPresented: $showSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Thank you for helping keep our community safe. We'll review your report shortly.")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Failed to submit report")
            }
        }
    }

    // MARK: - Actions

    private func submitReport() async {
        guard let type = selectedType else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            switch contentType {
            case .highlight:
                try await moderationService.reportHighlight(
                    contentId,
                    reportedUserId: reportedUserId,
                    type: type,
                    description: description.isEmpty ? nil : description
                )
            case .comment:
                try await moderationService.reportComment(
                    contentId,
                    reportedUserId: reportedUserId,
                    type: type,
                    description: description.isEmpty ? nil : description
                )
            case .userProfile:
                try await moderationService.reportUser(
                    contentId,
                    type: type,
                    description: description.isEmpty ? nil : description
                )
            }

            showSuccess = true
            UIImpactFeedbackGenerator.medium()

        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Report Type Button

struct ReportTypeButton: View {
    let type: ReportType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BSCSpacing.md) {
                Image(systemName: type.icon)
                    .bscFont(size: 20)
                    .foregroundStyle(isSelected ? Color.bscOnPrimary : Color.bscErrorText)
                    .frame(width: BSCIconSize.xl)

                VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                    Text(type.displayName)
                        .bscFont(size: 17, weight: .semibold)
                        .foregroundStyle(isSelected ? Color.bscOnPrimary : Color.bscTextPrimary)

                    Text(type.description)
                        .bscFont(size: 12)
                        .foregroundStyle(isSelected ? Color.bscOnPrimary.opacity(0.8) : Color.bscTextSecondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.bscOnPrimary)
                }
            }
            .padding(BSCSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md)
                    .fill(isSelected ? Color.bscErrorFill : Color.bscSurfaceGlass)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Content Type Extension

extension ReportedContentType {
    var displayName: String {
        switch self {
        case .highlight:
            return "Highlight"
        case .comment:
            return "Comment"
        case .userProfile:
            return "Profile"
        }
    }
}

#Preview {
    ReportContentSheet(
        contentType: .highlight,
        contentId: UUID(),
        reportedUserId: UUID()
    )
}
