//
//  Font+MFontModifier.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import SwiftUI

extension Font {
    init(_ weight: Font.Weight, size: CGFloat) { switch weight {
        case .bold: self = .custom("Inter-Bold", size: size, relativeTo: .body)
        default: self = .custom("Inter-Regular", size: size, relativeTo: .body)
    }}
}
