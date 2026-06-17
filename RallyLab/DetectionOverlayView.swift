//
//  DetectionOverlayView.swift
//  RallyLab
//
//  Live detection/trajectory overlay drawn on top of the player, matching the
//  debug video's conventions: yellow boxes for kept detections, a dotted blue
//  ball trail, and a solid red trail when the current frame passes the
//  projectile gate. Detector coordinates are in the RAW frame (Vision
//  normalized, origin bottom-left); we flip Y and rotate to the player's
//  oriented display space before drawing.
//

import SwiftUI

struct DetectionOverlayView: View {
    let model: RallyLabModel

    /// How far back the ball trail extends.
    private let trailWindow: Double = 1.0

    var body: some View {
        // Reading these in the body establishes the observation dependency so
        // the Canvas redraws as playback advances.
        let time = model.currentTime
        let frames = model.overlayFrames(at: time, window: trailWindow)
        let displaySize = model.videoDisplaySize
        let turns = model.videoRotationQuarterTurns

        Canvas { ctx, size in
            let fit = Self.fittedRect(content: displaySize, in: size)
            guard !frames.isEmpty else { return }

            // Ball trail (oldest → newest), each segment colored by the gravity
            // signature at that point: red ≈ no gravity (carried/rolled), green ≈
            // free-flight acceleration. Grey where the gate reported no signature.
            let trail: [(point: CGPoint, color: Color)] = frames.compactMap { frame in
                guard let tp = frame.trackPoint else { return nil }
                let color: Color = frame.gravitySignature.map(Self.scoreColor) ?? .gray
                return (Self.point(tp, turns: turns, in: fit), color)
            }
            if trail.count >= 2 {
                for i in 1..<trail.count {
                    var seg = Path()
                    seg.move(to: trail[i - 1].point)
                    seg.addLine(to: trail[i].point)
                    ctx.stroke(seg, with: .color(trail[i].color),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }

            // Current detections (latest frame only): yellow box + the model's
            // confidence for that box drawn just above it.
            if let latest = frames.last {
                for det in latest.detections {
                    let rect = Self.rect(det.bbox, turns: turns, in: fit)
                    ctx.stroke(Path(rect), with: .color(.yellow), lineWidth: 2)
                    let label = Text(String(format: "%.2f", Double(det.confidence)))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.yellow)
                    ctx.draw(label, at: CGPoint(x: rect.minX, y: max(fit.minY, rect.minY - 2)),
                             anchor: .bottomLeading)
                }
                // Marker on the active track point.
                if let tp = latest.trackPoint {
                    let c = Self.point(tp, turns: turns, in: fit)
                    let dot = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
                    ctx.fill(Path(ellipseIn: dot),
                             with: .color(latest.isProjectile ? .red : .blue))
                }
                Self.drawHUD(ctx, latest: latest, in: fit)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Physics HUD

    /// Top-left readout of the gate's per-frame physics signals. rSquared stays
    /// high for a straight carry, so gravitySignature and the movement class are
    /// what reveal a ball being carried rather than in free flight.
    private static func drawHUD(_ ctx: GraphicsContext, latest: VideoProcessor.FrameEvidence, in fit: CGRect) {
        guard latest.trackPoint != nil else { return }

        var lines: [(String, Color)] = []
        if let r2 = latest.rSquared {
            lines.append((String(format: "R² %.2f", r2), scoreColor(r2)))
        }
        if let grav = latest.gravitySignature {
            // High gravity signature = real free flight; low = carried/rolled.
            lines.append((String(format: "gravity %.2f", grav), scoreColor(grav)))
        }
        if let type = latest.movementType {
            lines.append(("class \(type.displayName)", type == .airborne ? .green : .red))
        }
        if let ballConf = latest.detections.map(\.confidence).max() {
            // YOLO model confidence that the box is a volleyball.
            lines.append((String(format: "ball %.2f", Double(ballConf)), scoreColor(Double(ballConf))))
        }
        lines.append(("projectile \(latest.isProjectile ? "YES" : "no")",
                      latest.isProjectile ? .green : .secondary))
        if let reason = latest.rejectionReason {
            lines.append(("✕ \(reason)", .orange))
        }
        guard !lines.isEmpty else { return }

        let origin = CGPoint(x: fit.minX + 10, y: fit.minY + 10)
        let lineHeight: CGFloat = 16
        let panelWidth: CGFloat = latest.rejectionReason != nil ? 230 : 150
        let panel = CGRect(x: origin.x - 5, y: origin.y - 4,
                           width: panelWidth, height: CGFloat(lines.count) * lineHeight + 8)
        ctx.fill(Path(roundedRect: panel, cornerRadius: 5), with: .color(.black.opacity(0.55)))
        for (i, line) in lines.enumerated() {
            let text = Text(line.0)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(line.1)
            ctx.draw(text, at: CGPoint(x: origin.x, y: origin.y + CGFloat(i) * lineHeight),
                     anchor: .topLeading)
        }
    }

    /// Red → yellow → green for a 0…1 score.
    private static func scoreColor(_ s: Double) -> Color {
        let c = max(0, min(1, s))
        return Color(red: min(1, 2 * (1 - c)), green: min(1, 2 * c), blue: 0)
    }

    // MARK: - Coordinate mapping

    /// Aspect-fit `content` inside `container`, centered (matches AVKit's
    /// default video gravity), returning the letterboxed content rect.
    private static func fittedRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let w = content.width * scale
        let h = content.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// Raw normalized point (origin bottom-left) → oriented top-left normalized,
    /// applying the player's clockwise quarter-turns.
    private static func orientNormalized(_ p: CGPoint, turns: Int) -> CGPoint {
        // Vision origin is bottom-left; flip Y to a top-left raw space first.
        let raw = CGPoint(x: p.x, y: 1 - p.y)
        switch ((turns % 4) + 4) % 4 {
        case 1: return CGPoint(x: 1 - raw.y, y: raw.x)
        case 2: return CGPoint(x: 1 - raw.x, y: 1 - raw.y)
        case 3: return CGPoint(x: raw.y, y: 1 - raw.x)
        default: return raw
        }
    }

    private static func point(_ p: CGPoint, turns: Int, in fit: CGRect) -> CGPoint {
        let o = orientNormalized(p, turns: turns)
        return CGPoint(x: fit.minX + o.x * fit.width, y: fit.minY + o.y * fit.height)
    }

    private static func rect(_ bbox: CGRect, turns: Int, in fit: CGRect) -> CGRect {
        // Transform both corners and take the bounding box, since rotation
        // swaps which corner is top-left.
        let a = point(CGPoint(x: bbox.minX, y: bbox.minY), turns: turns, in: fit)
        let b = point(CGPoint(x: bbox.maxX, y: bbox.maxY), turns: turns, in: fit)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
