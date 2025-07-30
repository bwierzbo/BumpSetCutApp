//
//  View+MFontModifier.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//


import SwiftUI

extension View {
    func font(_ fontModifier: MFontModifier) -> some View { modifier(fontModifier) }
}
