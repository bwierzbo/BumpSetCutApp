//
//  YOLORawDecode.swift
//  BumpSetCut
//
//  Shared raw-tensor decode for YOLO models that export a single [1,N,6] tensor
//  (each row [x1, y1, x2, y2, confidence, class]) with no built-in NMS pipeline.
//  Used by BOTH the ball detector (YOLODetector) and the net detector (NetDetector)
//  so the coordinate normalization + letterbox de-letterboxing + Vision y-flip live
//  in exactly one place.
//

import CoreGraphics
import CoreML

/// Decode a raw YOLO `[1,N,6]` tensor into Vision-normalized (origin bottom-left,
/// [0,1]) bounding boxes + confidences.
///
/// - `inputSize`: the model's input pixel size (e.g. 960×960 or 640×640).
/// - `srcSize`: the source frame's pixel size, needed to undo letterbox padding.
/// - `letterbox`: true when the model ran on an aspect-preserved padded square
///   (`.scaleFit`); false when stretched (`.scaleFill`).
/// Rows below `minConfidence` or with a non-positive box are dropped.
func decodeYOLORaw(_ array: MLMultiArray,
                   inputSize: CGSize,
                   srcSize: CGSize,
                   letterbox: Bool,
                   minConfidence: Float) -> [(rect: CGRect, confidence: Float)] {
    guard array.dataType == .float32, array.shape.count == 3 else { return [] }
    let n = array.shape[1].intValue
    let cols = array.shape[2].intValue
    guard cols >= 6, n > 0 else { return [] }
    let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)

    // Letterbox geometry (.scaleFit): the model ran on a padded square where the
    // frame occupies a centered (srcW*s × srcH*s) region with padX/padY bars. We undo
    // it to map input-pixel boxes back to original-frame normalized coords. For
    // .scaleFill there is no padding and each axis maps independently.
    let inW = inputSize.width, inH = inputSize.height
    let srcW = srcSize.width, srcH = srcSize.height
    let lb = letterbox && srcW > 0 && srcH > 0
    let s = lb ? min(inW / srcW, inH / srcH) : 0
    let padX = lb ? (inW - srcW * s) / 2 : 0
    let padY = lb ? (inH - srcH * s) / 2 : 0

    var out: [(rect: CGRect, confidence: Float)] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let b = i * cols
        let x1 = ptr[b + 0], y1 = ptr[b + 1], x2 = ptr[b + 2], y2 = ptr[b + 3]
        let conf = ptr[b + 4]
        guard conf >= minConfidence, x2 > x1, y2 > y1 else { continue }
        // Coords may be normalized [0,1] or in input pixels — detect by scale,
        // then express in input-pixel space (0…inW / 0…inH).
        let isNormalized = max(max(x1, y1), max(x2, y2)) <= 1.5
        let px1 = isNormalized ? CGFloat(x1) * inW : CGFloat(x1)
        let px2 = isNormalized ? CGFloat(x2) * inW : CGFloat(x2)
        let py1 = isNormalized ? CGFloat(y1) * inH : CGFloat(y1)
        let py2 = isNormalized ? CGFloat(y2) * inH : CGFloat(y2)
        // Input-pixel → original-frame normalized (top-left, y down).
        let nx1, nx2, ny1, ny2: CGFloat
        if lb {
            nx1 = (px1 - padX) / (srcW * s); nx2 = (px2 - padX) / (srcW * s)
            ny1 = (py1 - padY) / (srcH * s); ny2 = (py2 - padY) / (srcH * s)
        } else {
            nx1 = px1 / inW; nx2 = px2 / inW
            ny1 = py1 / inH; ny2 = py2 / inH
        }
        // YOLO top-left (y down) → Vision bottom-left (y up).
        let rect = CGRect(x: nx1, y: 1 - ny2, width: nx2 - nx1, height: ny2 - ny1)
        out.append((rect: rect, confidence: conf))
    }
    return out
}
