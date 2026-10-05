//
//  PasswordRequirements.swift
//  BumpSetCut
//
//  The password rules (sign-up and reset share them) and the checklist that
//  shows progress against them.
//

import SwiftUI

enum PasswordRule: CaseIterable {
    case minLength
    case uppercase
    case number
    case symbol

    var label: LocalizedStringResource {
        switch self {
        case .minLength: return LocalizedStringResource("8+ characters", comment: "Password rule")
        case .uppercase: return LocalizedStringResource("One uppercase letter", comment: "Password rule")
        case .number: return LocalizedStringResource("One number", comment: "Password rule")
        case .symbol: return LocalizedStringResource("One symbol", comment: "Password rule")
        }
    }

    func isMet(by password: String) -> Bool {
        switch self {
        case .minLength: return password.count >= 8
        case .uppercase: return password.range(of: "[A-Z]", options: .regularExpression) != nil
        case .number: return password.range(of: "[0-9]", options: .regularExpression) != nil
        case .symbol: return password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil
        }
    }

    static func allMet(by password: String) -> Bool {
        allCases.allSatisfy { $0.isMet(by: password) }
    }
}

/// Live checklist under a new-password field.
struct PasswordRequirementsList: View {
    let password: String

    var body: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
            ForEach(PasswordRule.allCases, id: \.self) { rule in
                let met = rule.isMet(by: password)
                HStack(spacing: BSCSpacing.xs) {
                    Image(systemName: met ? "checkmark.circle.fill" : "circle")
                        .bscFont(size: 12)
                        .foregroundColor(met ? .bscSuccessText : .bscTextSecondary)
                    Text(rule.label)
                        .bscFont(size: 12)
                        .foregroundColor(.bscTextSecondary)
                }
                // One element per rule: "8+ characters, met".
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(rule.label))
                .accessibilityValue(met ? "Met" : "Not met")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
