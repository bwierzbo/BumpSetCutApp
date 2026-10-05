//
//  FlywheelConsentSheet.swift
//  BumpSetCut
//
//  Consent sheet for the opt-in data contribution (detector training).
//

import SwiftUI

// MARK: - Flywheel Consent Sheet

struct FlywheelConsentSheet: View {
    let onAccept: () -> Void
    let onCancel: () -> Void

    private let bullets: [(icon: String, text: LocalizedStringResource)] = [
        ("scissors", "We upload short clips of rallies the model struggled with — not your whole library."),
        ("chart.bar.doc.horizontal", "Each clip includes the detector's per-frame data so the frames can be relabeled."),
        ("person.crop.circle.badge.checkmark", "Clips are tied to your account and used only to improve detection."),
        ("hand.raised", "You can turn this off any time; pending clips are deleted when you do.")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: BSCSpacing.lg) {
                        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                            Text("Help Improve Detection")
                                .bscFont(size: 22, weight: .bold)
                                .foregroundColor(.bscTextPrimary)
                            Text("Contribute training clips so the volleyball model gets better over time.")
                                .bscFont(size: 15)
                                .foregroundColor(.bscTextSecondary)
                        }

                        VStack(alignment: .leading, spacing: BSCSpacing.md) {
                            ForEach(bullets, id: \.icon) { bullet in
                                HStack(alignment: .top, spacing: BSCSpacing.md) {
                                    Image(systemName: bullet.icon)
                                        .bscFont(size: 16)
                                        .foregroundColor(.bscPrimary)
                                        .frame(width: BSCIconSize.lg)
                                    Text(bullet.text)
                                        .bscFont(size: 14)
                                        .foregroundColor(.bscTextPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        Link("Privacy Policy", destination: URL(string: "https://bumpsetcut.com/privacy")!)
                            .bscFont(size: 14, weight: .medium)
                            .foregroundColor(.bscPrimaryText)

                        Button {
                            onAccept()
                        } label: {
                            Text("Turn On Contributions")
                                .bscFont(size: 16, weight: .semibold)
                                .foregroundColor(.bscOnPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, BSCSpacing.md)
                                .background(Color.bscPrimaryFill)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        }
                        .padding(.top, BSCSpacing.sm)
                    }
                    .padding(BSCSpacing.lg)
                }
            }
            .navigationTitle("Data Flywheel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .foregroundColor(.bscTextSecondary)
                }
            }
        }
    }
}
