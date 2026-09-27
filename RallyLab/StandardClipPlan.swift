//
//  StandardClipPlan.swift
//  RallyLab
//
//  The clip checklist every training set is built from: 50 five-minute
//  clips spread across environment, camera position, lighting, orientation
//  and ball colour, plus hard negatives and licensed online footage. A new
//  project starts with a fresh copy; each clip's footage and split are then
//  per project. Change the plan here and new projects pick it up.
//

enum StandardClipPlan {

    private struct Row {
        let number: Int, id: String, environment: String, camera: String
        let lighting: String, orientation: String, ball: String, notes: String
        init(_ number: Int, _ id: String, _ environment: String, _ camera: String,
             _ lighting: String, _ orientation: String, _ ball: String, _ notes: String) {
            (self.number, self.id, self.environment, self.camera) = (number, id, environment, camera)
            (self.lighting, self.orientation, self.ball, self.notes) = (lighting, orientation, ball, notes)
        }
    }

    static var clips: [PlannedClip] {
        rows.map {
            PlannedClip(id: $0.id, number: $0.number, environment: $0.environment, camera: $0.camera,
                        lighting: $0.lighting, orientation: $0.orientation, ball: $0.ball, notes: $0.notes)
        }
    }

    /// Labeled frames wanted per clip.
    static let targetFrames = 55

    private static let rows: [Row] = [
        .init(1, "ind_ele_bright_land_self_01", "Indoor", "End line, elevated (stands/tripod 2m+)", "Bright gym", "Landscape", "White/blue indoor", ""),
        .init(2, "ind_ele_dim_land_self_02", "Indoor", "End line, elevated (stands/tripod 2m+)", "Dim gym", "Landscape", "Green/white/red indoor", ""),
        .init(3, "ind_ele_bright_port_self_03", "Indoor", "End line, elevated (stands/tripod 2m+)", "Bright gym", "Portrait", "White/blue indoor", ""),
        .init(4, "ind_ele_dim_land_self_04", "Indoor", "End line, elevated (stands/tripod 2m+)", "Dim gym", "Landscape", "Green/white/red indoor", ""),
        .init(5, "ind_gnd_bright_land_self_01", "Indoor", "End line, ground level", "Bright gym", "Landscape", "White/blue indoor", ""),
        .init(6, "ind_gnd_dim_land_self_02", "Indoor", "End line, ground level", "Dim gym", "Landscape", "Green/white/red indoor", ""),
        .init(7, "ind_gnd_bright_port_self_03", "Indoor", "End line, ground level", "Bright gym", "Portrait", "White/blue indoor", ""),
        .init(8, "ind_sid_dim_land_self_01", "Indoor", "Sideline / near net", "Dim gym", "Landscape", "Green/white/red indoor", ""),
        .init(9, "ind_sid_bright_land_self_02", "Indoor", "Sideline / near net", "Bright gym", "Landscape", "White/blue indoor", ""),
        .init(10, "ind_sid_dim_land_self_03", "Indoor", "Sideline / near net", "Dim gym", "Landscape", "Green/white/red indoor", ""),
        .init(11, "ind_hnd_bright_port_self_01", "Indoor", "Handheld / corner", "Bright gym", "Portrait", "White/blue indoor", ""),
        .init(12, "ind_hnd_dim_land_self_02", "Indoor", "Handheld / corner", "Dim gym", "Landscape", "Green/white/red indoor", ""),
        .init(13, "bch_ele_sun_land_self_01", "Beach", "End line, elevated (stands/tripod 2m+)", "Sunny", "Landscape", "Yellow/blue beach", ""),
        .init(14, "bch_ele_ovc_land_self_02", "Beach", "End line, elevated (stands/tripod 2m+)", "Overcast / golden hour", "Landscape", "White/yellow beach", ""),
        .init(15, "bch_ele_sun_port_self_03", "Beach", "End line, elevated (stands/tripod 2m+)", "Sunny", "Portrait", "Yellow/blue beach", ""),
        .init(16, "bch_gnd_ovc_land_self_01", "Beach", "End line, ground level", "Overcast / golden hour", "Landscape", "White/yellow beach", ""),
        .init(17, "bch_gnd_sun_land_self_02", "Beach", "End line, ground level", "Sunny", "Landscape", "Yellow/blue beach", ""),
        .init(18, "bch_gnd_ovc_land_self_03", "Beach", "End line, ground level", "Overcast / golden hour", "Landscape", "White/yellow beach", ""),
        .init(19, "bch_sid_sun_port_self_01", "Beach", "Sideline / near net", "Sunny", "Portrait", "Yellow/blue beach", ""),
        .init(20, "bch_sid_ovc_land_self_02", "Beach", "Sideline / near net", "Overcast / golden hour", "Landscape", "White/yellow beach", ""),
        .init(21, "bch_sid_sun_land_self_03", "Beach", "Sideline / near net", "Sunny", "Landscape", "Yellow/blue beach", ""),
        .init(22, "bch_hnd_ovc_land_self_01", "Beach", "Handheld / corner", "Overcast / golden hour", "Landscape", "White/yellow beach", ""),
        .init(23, "bch_hnd_sun_port_self_02", "Beach", "Handheld / corner", "Sunny", "Portrait", "Yellow/blue beach", ""),
        .init(24, "grs_ele_sun_land_self_01", "Grass", "End line, elevated (stands/tripod 2m+)", "Sunny", "Landscape", "White/yellow", ""),
        .init(25, "grs_ele_shade_land_self_02", "Grass", "End line, elevated (stands/tripod 2m+)", "Shade", "Landscape", "White/blue", ""),
        .init(26, "grs_ele_dusk_port_self_03", "Grass", "End line, elevated (stands/tripod 2m+)", "Dusk", "Portrait", "White/yellow", ""),
        .init(27, "grs_gnd_sun_land_self_01", "Grass", "End line, ground level", "Sunny", "Landscape", "White/blue", ""),
        .init(28, "grs_gnd_shade_land_self_02", "Grass", "End line, ground level", "Shade", "Landscape", "White/yellow", ""),
        .init(29, "grs_gnd_dusk_land_self_03", "Grass", "End line, ground level", "Dusk", "Landscape", "White/blue", ""),
        .init(30, "grs_sid_sun_port_self_01", "Grass", "Sideline / near net", "Sunny", "Portrait", "White/yellow", ""),
        .init(31, "grs_sid_shade_land_self_02", "Grass", "Sideline / near net", "Shade", "Landscape", "White/blue", ""),
        .init(32, "grs_sid_dusk_land_self_03", "Grass", "Sideline / near net", "Dusk", "Landscape", "White/yellow", ""),
        .init(33, "grs_hnd_sun_land_self_01", "Grass", "Handheld / corner", "Sunny", "Landscape", "White/blue", ""),
        .init(34, "grs_hnd_shade_port_self_02", "Grass", "Handheld / corner", "Shade", "Portrait", "White/yellow", ""),
        .init(35, "ind_neg_bright_land_self_01", "Indoor", "Hard negative (no rally)", "Bright gym", "Landscape", "Any", "Multi-court gym, next court in frame"),
        .init(36, "ind_neg_bright_land_self_02", "Indoor", "Hard negative (no rally)", "Bright gym", "Landscape", "Any", "Warmup, many balls, round ceiling lights"),
        .init(37, "bch_neg_sun_land_self_01", "Beach", "Hard negative (no rally)", "Sunny", "Landscape", "Any", "Spectators near net, second court behind"),
        .init(38, "grs_neg_sun_land_self_01", "Grass", "Hard negative (no rally)", "Sunny", "Landscape", "Any", "Park with frisbee / soccer ball around"),
        .init(39, "ind_onl_bright_land_onl_01", "Indoor", "Online (CC-licensed)", "Bright gym", "Landscape", "Any", "Club practice, phone upload"),
        .init(40, "ind_onl_dim_land_onl_02", "Indoor", "Online (CC-licensed)", "Dim gym", "Landscape", "Any", "Older gym, rec league"),
        .init(41, "ind_onl_bright_land_onl_03", "Indoor", "Online (CC-licensed)", "Bright gym", "Landscape", "Any", "Tournament hall, multi-court"),
        .init(42, "ind_onl_bright_land_onl_04", "Indoor", "Online (CC-licensed)", "Bright gym", "Landscape", "Any", "Broadcast — lighting only"),
        .init(43, "bch_onl_sun_land_onl_01", "Beach", "Online (CC-licensed)", "Sunny", "Landscape", "Any", "Amateur beach tournament"),
        .init(44, "bch_onl_ovc_land_onl_02", "Beach", "Online (CC-licensed)", "Overcast / golden hour", "Landscape", "Any", "Beach, overcast/evening"),
        .init(45, "bch_onl_sun_land_onl_03", "Beach", "Online (CC-licensed)", "Sunny", "Landscape", "Any", "Pro beach, CC only"),
        .init(46, "bch_onl_sun_land_onl_04", "Beach", "Online (CC-licensed)", "Sunny", "Landscape", "Any", "Stock CC0 beach clip"),
        .init(47, "grs_onl_sun_land_onl_01", "Grass", "Online (CC-licensed)", "Sunny", "Landscape", "Any", "Grass doubles / park pickup"),
        .init(48, "grs_onl_shade_land_onl_02", "Grass", "Online (CC-licensed)", "Shade", "Landscape", "Any", "Grass tournament under trees"),
        .init(49, "grs_onl_dusk_land_onl_03", "Grass", "Online (CC-licensed)", "Dusk", "Landscape", "Any", "Backyard grass play"),
        .init(50, "grs_onl_sun_land_onl_04", "Grass", "Online (CC-licensed)", "Sunny", "Landscape", "Any", "Stock CC0 grass clip"),
    ]
}
