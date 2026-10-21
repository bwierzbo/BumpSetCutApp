//
//  ClipID.swift
//  RallyLab
//
//  What a clip ID — and the dataset session named after it — encodes in its
//  prefix: `bch_` beach, `grs_` grass, `ind_` indoor. The one parser for every
//  place that reads a surface from a name, so the mapping can't drift.
//

import Foundation

enum ClipID {
    enum Surface: String, CaseIterable {
        case beach, grass, indoor

        /// "Beach", as the project's clip cards spell it.
        var title: String { rawValue.capitalized }
    }

    static func surface(of name: String) -> Surface? {
        switch name.prefix(3) {
        case "bch": return .beach
        case "grs": return .grass
        case "ind": return .indoor
        default: return nil
        }
    }
}
