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

    var body: some View {
        // Reading these in the body establishes the observation dependency so
        // the Canvas redraws as playback advances.
        let time = model.currentTime
        let frames = model.overlayFrames(at: time, window: model.trailWindowSec)
        let displaySize = model.videoDisplaySize
        let turns = model.videoRotationQuarterTurns
        let showROI = model.showROI

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

            // Multi-court candidate visualization. The selected trajectory (the main
            // court ball) is the gravity-colored trail above; here we show every
            // OTHER candidate the selector saw. A "non-court" ball — physics-valid
            // but dropped by the multi-court size/spatial gate — is drawn RED so it's
            // obvious which balls the gate rejected vs. an in-court ball that merely
            // lost scoring (dim grey). Each track's ROI is the Kalman association gate.
            let selectedId = frames.last?.candidates.first(where: { $0.isSelected })?.id

            // Latest court-excluded status per candidate (chronological, last wins).
            var excludedById: [UUID: Bool] = [:]
            for frame in frames {
                for cand in frame.candidates where cand.id != selectedId {
                    excludedById[cand.id] = cand.isCourtExcluded
                }
            }

            // Trails for each non-selected candidate: red = non-court, grey = in-court.
            var trailsById: [UUID: [CGPoint]] = [:]
            for frame in frames {
                for cand in frame.candidates where cand.id != selectedId {
                    trailsById[cand.id, default: []].append(Self.point(cand.point, turns: turns, in: fit))
                }
            }
            for (id, pts) in trailsById where pts.count >= 2 {
                var path = Path()
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
                let color: Color = excludedById[id] == true ? .red.opacity(0.5) : .white.opacity(0.25)
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            // ROI circles + score labels for the latest frame's candidates. The
            // radius IS the track's real association gate (roiRadius, already
            // ballSize × trajectoryRoiScale at detection time), mapped from
            // normalized units into the fitted video rect — so what you see is the
            // exact gate. Re-run after changing trajectoryRoiScale to update it.
            if showROI, let latest = frames.last {
                let roiPixels = min(fit.width, fit.height)
                for cand in latest.candidates {
                    let c = Self.point(cand.point, turns: turns, in: fit)
                    let r = max(6, cand.roiRadius * roiPixels)
                    let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                    // green = selected main-court ball; red = non-court ball dropped
                    // by the multi-court gate; orange = in-court projectile that lost
                    // scoring; grey = non-projectile.
                    let roiColor: Color = cand.isSelected
                        ? .green.opacity(0.9)
                        : (cand.isCourtExcluded ? .red.opacity(0.7)
                           : (cand.isProjectile ? .orange.opacity(0.6) : .white.opacity(0.3)))
                    ctx.stroke(Path(ellipseIn: circle), with: .color(roiColor),
                               style: StrokeStyle(lineWidth: cand.isSelected ? 2 : 1,
                                                  dash: cand.isSelected ? [] : [4, 3]))
                    if !cand.isSelected {
                        // Non-court balls aren't scored (the gate dropped them), so
                        // tag them instead of printing a misleading 0.00.
                        let text = cand.isCourtExcluded ? "non-court" : String(format: "%.2f", cand.score)
                        let label = Text(text)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(cand.isCourtExcluded ? .red.opacity(0.9) : .white.opacity(0.8))
                        ctx.draw(label, at: CGPoint(x: c.x + 4, y: c.y - 4), anchor: .bottomLeading)
                    }
                }
            }

            // Net band + off-court boundary (latest frame). The magenta lines are the
            // court bounds (net posts ± offCourtMargin): detections outside them are
            // dropped as another court's ball. The yellow line is the net's bottom
            // edge — the under-net rule trashes trajectories that never rise above it.
            if let latest = frames.last, let net = latest.detectedNet {
                let netRect = Self.rect(net.box, turns: turns, in: fit)
                ctx.stroke(Path(netRect), with: .color(.cyan.opacity(0.5)), lineWidth: 1.5)
                var bottom = Path()
                bottom.move(to: CGPoint(x: netRect.minX, y: netRect.maxY))
                bottom.addLine(to: CGPoint(x: netRect.maxX, y: netRect.maxY))
                ctx.stroke(bottom, with: .color(.yellow.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                // Net top edge (above-net threshold): a multi-contact rally must
                // clear this line at least once. netRect.minY is the top on screen.
                if model.enableAboveNetRequirement {
                    let topY = netRect.minY + CGFloat(model.aboveNetMarginY) * fit.height
                    var top = Path()
                    top.move(to: CGPoint(x: netRect.minX, y: topY))
                    top.addLine(to: CGPoint(x: netRect.maxX, y: topY))
                    ctx.stroke(top, with: .color(.green.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                if model.enableOffCourtRejection {
                    let m = CGFloat(model.offCourtMarginX)
                    for x in [net.box.minX - m, net.box.maxX + m] {
                        let top = Self.point(CGPoint(x: x, y: 0), turns: turns, in: fit)
                        let bot = Self.point(CGPoint(x: x, y: 1), turns: turns, in: fit)
                        var line = Path()
                        line.move(to: top); line.addLine(to: bot)
                        ctx.stroke(line, with: .color(.purple.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    }
                }
            }

            // Current detections (latest frame only): yellow box + the model's
            // confidence for that box drawn just above it. Off-court detections
            // (dropped before tracking) draw dimmed red so you can see what the gate
            // rejected and why.
            if let latest = frames.last {
                for det in latest.detections {
                    let rect = Self.rect(det.bbox, turns: turns, in: fit)
                    let color: Color = det.isOffCourt ? .red.opacity(0.5) : .yellow
                    ctx.stroke(Path(rect), with: .color(color),
                               style: StrokeStyle(lineWidth: 2, dash: det.isOffCourt ? [4, 3] : []))
                    let label = Text(det.isOffCourt
                                     ? "off-court"
                                     : String(format: "%.2f", Double(det.confidence)))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
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

    /// Top-left readout of the gate's per-frame physics signals. Persistent: it
    /// shows whenever there's any ball signal this frame (a tracked point, a
    /// candidate trajectory, or even just a raw detection), so a rejected
    /// trajectory always shows WHY it isn't a rally — not only the selected track.
    /// rSquared stays high for a straight carry, so gravitySignature and the
    /// movement class are what reveal a ball being carried rather than in free flight.
    private static func drawHUD(_ ctx: GraphicsContext, latest: VideoProcessor.FrameEvidence, in fit: CGRect) {
        // The trajectory we explain: the selected one, else the best-scoring, else
        // the biggest candidate. nil when only raw detections exist (all off-court).
        let subject = latest.candidates.first(where: { $0.isSelected })
            ?? latest.candidates.max(by: { ($0.score, Double($0.ballSize)) < ($1.score, Double($1.ballSize)) })

        var lines: [(String, Color)] = []

        if let r2 = subject?.rSquared ?? latest.rSquared {
            lines.append((String(format: "R² %.2f", r2), scoreColor(r2)))
        }
        if let grav = subject?.gravitySignature ?? latest.gravitySignature {
            // High gravity signature = real free flight; low = carried/rolled.
            lines.append((String(format: "gravity %.2f", grav), scoreColor(grav)))
        }
        if let type = subject?.movementType ?? latest.movementType {
            lines.append(("class \(type.displayName)", type == .airborne ? .green : .red))
        }
        if let ballConf = latest.detections.map(\.confidence).max() {
            // YOLO model confidence that the box is a volleyball.
            lines.append((String(format: "ball %.2f", Double(ballConf)), scoreColor(Double(ballConf))))
        }
        if let subject {
            // Ball size (√area, normalized) — read this to set minBallSize.
            lines.append((String(format: "size %.3f", Double(subject.ballSize)), .secondary))
        }

        // Verdict line: is this a rally, and if not, exactly why.
        let isRally = (subject?.isSelected ?? false) && latest.isProjectile
        if isRally {
            lines.append(("● RALLY", .green))
        } else if let subject {
            if let reason = subject.rejectionReason {
                lines.append(("✕ \(reason)", subject.isCourtExcluded ? .red : .orange))
            } else if !subject.isProjectile {
                lines.append(("✕ not a projectile", .orange))
            } else {
                // Valid projectile that simply lost selection to another trajectory.
                lines.append(("• valid · not selected", .yellow))
            }
        } else if !latest.detections.isEmpty {
            // Raw detections but no candidate survived — all dropped pre-tracking.
            let allOff = latest.detections.allSatisfy { $0.isOffCourt }
            lines.append((allOff ? "✕ off-court (beyond posts)" : "ball seen · no track", .red))
        } else {
            lines.append(("no ball", .secondary))
        }

        let origin = CGPoint(x: fit.minX + 10, y: fit.minY + 10)
        let lineHeight: CGFloat = 16
        // Width fits the longest line (monospaced ≈ 7.3pt/char at 12pt).
        let maxChars = lines.map(\.0.count).max() ?? 0
        let panelWidth = max(150, CGFloat(maxChars) * 7.3 + 16)
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

    // MARK: - Coordinate mapping (delegates to shared OverlayGeometry)

    private static func fittedRect(content: CGSize, in container: CGSize) -> CGRect {
        OverlayGeometry.fittedRect(content: content, in: container)
    }
    private static func point(_ p: CGPoint, turns: Int, in fit: CGRect) -> CGPoint {
        OverlayGeometry.point(p, turns: turns, in: fit)
    }
    private static func rect(_ bbox: CGRect, turns: Int, in fit: CGRect) -> CGRect {
        OverlayGeometry.rect(bbox, turns: turns, in: fit)
    }
}
