//
//  MFontModifier.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import SwiftUI

struct MFontModifier: ViewModifier {
    private let font: Font
    private let lineHeight: CGFloat
    private let fontHeight: CGFloat
    private let kerning: CGFloat


    init(_ weight: Font.Weight, size: CGFloat, lineHeight: CGFloat, kerning: CGFloat) {
        self.font = .init(weight, size: size)
        self.lineHeight = lineHeight
        self.fontHeight = size
        self.kerning = kerning
    }
    func body(content: Content) -> some View {
        content
            .font(font)
            .tracking(kerning)
            .lineSpacing(spacing)
            .padding(.vertical, padding)
    }
}
private extension MFontModifier {
    var calculatedLineHeight: CGFloat { lineHeight - fontHeight - 3 }
    var spacing: CGFloat { calculatedLineHeight < 0 ? 0 : calculatedLineHeight }
    var padding: CGFloat { spacing / 2 }
}


// MARK: - TYPOGRAPHY



// MARK: Header
extension MFontModifier {
    static var h1: MFontModifier { .init(.bold, size: 48, lineHeight: 58, kerning: -0.32) }
    static var h2: MFontModifier { .init(.bold, size: 40, lineHeight: 48, kerning: -0.32) }
    static var h3: MFontModifier { .init(.bold, size: 32, lineHeight: 38, kerning: -0.32) }
    static var h4: MFontModifier { .init(.bold, size: 28, lineHeight: 32, kerning: -0.28) }
    static var h5: MFontModifier { .init(.bold, size: 24, lineHeight: 28, kerning: -0.24) }
    static var h6: MFontModifier { .init(.bold, size: 20, lineHeight: 24, kerning: -0.24) }
}

// MARK: Body
extension MFontModifier {
    static var mediumBold: MFontModifier { .init(.bold, size: 16, lineHeight: 24, kerning: -0.16) }
    static var mediumRegular: MFontModifier { .init(.regular, size: 16, lineHeight: 24, kerning: 0) }
    static var smallRegular: MFontModifier { .init(.regular, size: 12, lineHeight: 20, kerning: 0.16) }
    static var smallBold: MFontModifier { .init(.bold, size: 12, lineHeight: 20, kerning: 0) }
}

// MARK: Display (Hero text)
extension MFontModifier {
    /// 56pt - Large hero headlines
    static var display1: MFontModifier { .init(.bold, size: 56, lineHeight: 64, kerning: -0.5) }
    /// 44pt - Secondary hero text
    static var display2: MFontModifier { .init(.bold, size: 44, lineHeight: 52, kerning: -0.4) }
}

// MARK: Labels (UI elements)
extension MFontModifier {
    /// 14pt bold - Large labels
    static var labelLarge: MFontModifier { .init(.bold, size: 14, lineHeight: 20, kerning: 0.1) }
    /// 12pt bold - Medium labels
    static var labelMedium: MFontModifier { .init(.bold, size: 12, lineHeight: 16, kerning: 0.2) }
    /// 10pt bold - Small labels
    static var labelSmall: MFontModifier { .init(.bold, size: 10, lineHeight: 14, kerning: 0.3) }
}

// MARK: Captions
extension MFontModifier {
    /// 14pt regular - Large captions
    static var captionLarge: MFontModifier { .init(.regular, size: 14, lineHeight: 20, kerning: 0) }
    /// 12pt regular - Standard captions
    static var caption: MFontModifier { .init(.regular, size: 12, lineHeight: 16, kerning: 0.1) }
    /// 10pt regular - Tiny captions
    static var captionSmall: MFontModifier { .init(.regular, size: 10, lineHeight: 14, kerning: 0.1) }
}

// MARK: Semantic Aliases
extension MFontModifier {
    /// Card title - Medium bold for card headers
    static var cardTitle: MFontModifier { .mediumBold }
    /// Card subtitle - Small regular for secondary info
    static var cardSubtitle: MFontModifier { .smallRegular }
    /// Button label - Medium bold for button text
    static var buttonLabel: MFontModifier { .mediumBold }
    /// Navigation title - H6 for nav bars
    static var navTitle: MFontModifier { .h6 }
    /// Section header - H5 for section titles
    static var sectionHeader: MFontModifier { .h5 }
    /// Stat value - Display2 for large numbers
    static var statValue: MFontModifier { .display2 }
    /// Stat label - Label medium for stat descriptions
    static var statLabel: MFontModifier { .labelMedium }
}
