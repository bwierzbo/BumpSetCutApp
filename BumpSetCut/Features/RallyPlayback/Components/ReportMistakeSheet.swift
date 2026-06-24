//
//  ReportMistakeSheet.swift
//  BumpSetCut
//
//  Lets an opted-in user flag the current rally as a detection mistake, picking
//  a reason. Feeds an explicit (trigger = .reported) data-flywheel contribution.
//

import SwiftUI

struct ReportMistakeSheet: View {
    /// Called with the chosen reason (nil for "other"/unspecified) when the user submits.
    let onSubmit: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Reason codes mirror the labels offline relabelers care about.
    private let reasons: [(code: String, label: String, icon: String)] = [
        ("missed_ball", "Missed the ball", "circle.dashed"),
        ("wrong_bounds", "Wrong start / end", "timeline.selection"),
        ("not_a_rally", "Not a real rally", "xmark.circle"),
        ("other", "Something else", "ellipsis.circle")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: BSCSpacing.lg) {
                    VStack(spacing: BSCSpacing.xs) {
                        Text("What did the model get wrong?")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.bscTextPrimary)
                            .multilineTextAlignment(.center)

                        Text("This clip and its detection data help improve detection.")
                            .font(.system(size: 13))
                            .foregroundColor(.bscTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, BSCSpacing.lg)

                    VStack(spacing: BSCSpacing.sm) {
                        ForEach(reasons, id: \.code) { reason in
                            Button {
                                onSubmit(reason.code == "other" ? nil : reason.code)
                                dismiss()
                            } label: {
                                HStack(spacing: BSCSpacing.md) {
                                    Image(systemName: reason.icon)
                                        .font(.system(size: 18))
                                        .foregroundColor(.bscPrimary)
                                        .frame(width: 28)
                                    Text(reason.label)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.bscTextPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.bscTextSecondary)
                                }
                                .padding(BSCSpacing.md)
                                .background(Color.bscBackgroundElevated)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                            }
                        }
                    }

                    Spacer()
                }
                .padding(BSCSpacing.lg)
            }
            .navigationTitle("Report a Mistake")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.bscTextSecondary)
                }
            }
        }
    }
}
