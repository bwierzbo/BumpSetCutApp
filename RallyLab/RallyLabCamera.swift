//
//  RallyLabCamera.swift
//  RallyLab
//
//  The camera position a clip was filmed from, read from its clip ID — the
//  standard clip plan encodes it (`_ele_`/`_gnd_` end line raised/ground,
//  `_sid_` sideline, `_tri_`/`_hnd_` corner) — so RallyLab runs each clip
//  with the same angle-dependent rules the app uses for that position.
//

import Foundation

extension CameraSetup {
    /// The setup a clip ID names; end line (raised) when it names none.
    init(clipID: String) {
        let parts = Set(clipID.lowercased().split(separator: "_").map(String.init))
        let zone: CameraZone
        if parts.contains("sid") {
            zone = .sideline
        } else if parts.contains("tri") || parts.contains("hnd") {
            zone = .corner
        } else {
            zone = .endline
        }
        self.init(position: zone.presetPosition, height: parts.contains("gnd") ? .ground : .raised)
    }
}
