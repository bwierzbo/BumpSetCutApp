//
//  YOLORawDecode.swift
//  BumpSetCut
//
//  Shared raw-tensor decode for YOLO models exported with no built-in NMS
//  pipeline, in either of the two layouts Ultralytics produces:
//
//  - end-to-end `[1, N, 6]`: each row [x1, y1, x2, y2, confidence, class],
//    already one box per object (YOLO26's one-to-one head);
//  - raw grid `[1, 4 + classes, anchors]`: per anchor [cx, cy, w, h, score…]
//    before NMS (what a model trained without the end-to-end head exports,
//    e.g. Ultralytics' single_cls training) — decoded here and de-duplicated
//    with NMS.
//
//  Used by BOTH the ball detector (YOLODetector) and the net detector (NetDetector)
//  so the coordinate normalization + letterbox de-letterboxing + Vision y-flip live
//  in exactly one place.
//

import CoreGraphics
import CoreML

/// Decode a raw YOLO tensor (either layout above) into Vision-normalized
/// (origin bottom-left, [0,1]) bounding boxes + confidences.
///
/// - `inputSize`: the model's input pixel size (e.g. 960×960 or 640×640).
/// - `srcSize`: the source frame's pixel size, needed to undo letterbox padding.
/// - `letterbox`: true when the model ran on an aspect-preserved padded square
///   (`.scaleFit`); false when stretched (`.scaleFill`).
/// Boxes below `minConfidence` or with a non-positive size are dropped.
func decodeYOLORaw(_ array: MLMultiArray,
                   inputSize: CGSize,
                   srcSize: CGSize,
                   letterbox: Bool,
                   minConfidence: Float) -> [(rect: CGRect, confidence: Float)] {
    guard array.dataType == .float32, array.shape.count == 3 else { return [] }
    let dim1 = array.shape[1].intValue, dim2 = array.shape[2].intValue
    guard dim1 > 0, dim2 > 0 else { return [] }
    let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
    let s1 = array.strides[1].intValue, s2 = array.strides[2].intValue

    // Input-pixel boxes (x1, y1, x2, y2, top-left origin) with their scores.
    var boxes: [(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, conf: Float)] = []
    if dim1 >= 5, dim1 < dim2 {
        // Raw grid: channels first, one column per anchor.
        let classes = dim1 - 4
        for a in 0..<dim2 {
            var score: Float = 0
            for c in 0..<classes { score = max(score, ptr[(4 + c) * s1 + a * s2]) }
            guard score >= minConfidence else { continue }
            let cx = CGFloat(ptr[a * s2]), cy = CGFloat(ptr[s1 + a * s2])
            let w = CGFloat(ptr[2 * s1 + a * s2]), h = CGFloat(ptr[3 * s1 + a * s2])
            guard w > 0, h > 0 else { continue }
            boxes.append((cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, score))
        }
        boxes = nonMaxSuppressed(boxes, iou: 0.7)
    } else if dim2 >= 6 {
        // End-to-end: one row per detection.
        for i in 0..<dim1 {
            let row = i * s1
            let x1 = ptr[row], y1 = ptr[row + s2], x2 = ptr[row + 2 * s2], y2 = ptr[row + 3 * s2]
            let conf = ptr[row + 4 * s2]
            guard conf >= minConfidence, x2 > x1, y2 > y1 else { continue }
            // Coords may be normalized [0,1] or in input pixels — detect by scale.
            let isNormalized = max(max(x1, y1), max(x2, y2)) <= 1.5
            let sx = isNormalized ? inputSize.width : 1, sy = isNormalized ? inputSize.height : 1
            boxes.append((CGFloat(x1) * sx, CGFloat(y1) * sy, CGFloat(x2) * sx, CGFloat(y2) * sy, conf))
        }
    } else {
        return []
    }

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

    return boxes.map { b in
        // Input-pixel → original-frame normalized (top-left, y down).
        let nx1, nx2, ny1, ny2: CGFloat
        if lb {
            nx1 = (b.x1 - padX) / (srcW * s); nx2 = (b.x2 - padX) / (srcW * s)
            ny1 = (b.y1 - padY) / (srcH * s); ny2 = (b.y2 - padY) / (srcH * s)
        } else {
            nx1 = b.x1 / inW; nx2 = b.x2 / inW
            ny1 = b.y1 / inH; ny2 = b.y2 / inH
        }
        // YOLO top-left (y down) → Vision bottom-left (y up).
        return (rect: CGRect(x: nx1, y: 1 - ny2, width: nx2 - nx1, height: ny2 - ny1), confidence: b.conf)
    }
}

/// Greedy NMS, most confident first: a box is dropped when it overlaps a kept
/// one by more than `iou`. Candidates are capped to the 300 most confident
/// first, as Ultralytics does.
private func nonMaxSuppressed(_ boxes: [(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, conf: Float)],
                              iou limit: CGFloat) -> [(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, conf: Float)] {
    let sorted = boxes.sorted { $0.conf > $1.conf }.prefix(300)
    var kept: [(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, conf: Float)] = []
    for b in sorted {
        let area = (b.x2 - b.x1) * (b.y2 - b.y1)
        let overlaps = kept.contains { k in
            let w = min(b.x2, k.x2) - max(b.x1, k.x1), h = min(b.y2, k.y2) - max(b.y1, k.y1)
            guard w > 0, h > 0 else { return false }
            let inter = w * h
            return inter / (area + (k.x2 - k.x1) * (k.y2 - k.y1) - inter) > limit
        }
        if !overlaps { kept.append(b) }
    }
    return kept
}
