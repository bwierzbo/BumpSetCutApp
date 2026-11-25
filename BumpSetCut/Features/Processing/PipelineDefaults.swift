//
//  PipelineDefaults.swift
//  BumpSetCut
//
//  What the apps that ship give the pipeline: no single-frame ball detector, and no net
//  unless the caller names a source (the app names the video's confirmed calibration).
//  Compiled into the BumpSetCut app and RallyLab on the iPhone. RallyLab on the Mac has
//  its own file of this name, with its research detectors.
//

import Foundation

enum PipelineDefaults {
    /// None: the multi-frame model is the only ball finder in a build that ships. A configuration that asks for a
    /// single-frame detector is refused, not answered by another model.
    static func singleFrameBallDetector(for config: ProcessorConfig, reusing existing: (any SingleFrameBallDetector)?) -> (any SingleFrameBallDetector)? {
        nil
    }

    static func netSource() -> any NetGeometrySource { NoNetGeometrySource() }
}
