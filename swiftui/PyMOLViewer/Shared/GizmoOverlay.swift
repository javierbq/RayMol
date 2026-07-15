// GizmoOverlay.swift — Unified molecular-frame Move gizmo (types + hit-testing).
//
// One gizmo per active object, anchored on a per-object orthonormal frame
// (center of mass + N/C termini; PCA fallback). The gizmo is RENDERED as a 3D
// CGO object in the Metal scene by metal_move.py (lit tubes that wrap the
// molecule with real depth); this file only holds the shared types and the 2D
// hit-testing (GizmoGeometry.hitTest) that MetalViewport uses to route drags.
//
// NDC convention (matches metal_pick / MetalViewport): bottom-left origin,
// +x right, +y up, in [-1, 1].

import Foundation
import CoreGraphics
import SwiftUI

enum InteractionMode {
    case viewing
    case move
}

/// A draggable gizmo handle: .x/.y/.z axis arrows (translate along a frame axis),
/// .rx/.ry/.rz rings (rotate about a frame axis), .free center (screen-plane drag).
enum GizmoHandle: String, Equatable {
    case x, y, z, free
    case rx, ry, rz

    var pyName: String { rawValue }
}

/// Projected gizmo geometry for one frame (all points in NDC).
struct GizmoGeometry: Equatable {
    var obj: String
    var center: CGPoint
    var axes: [String: CGPoint]      // "x"/"y"/"z" -> arrow tip
    var rings: [String: [CGPoint]]  // "x"/"y"/"z" -> ring polyline

    init?(json: [String: Any]) {
        guard let c = json["center"] as? [Double], c.count == 2 else { return nil }
        obj = json["obj"] as? String ?? ""
        center = CGPoint(x: c[0], y: c[1])
        var ax: [String: CGPoint] = [:]
        if let a = json["axes"] as? [String: [Double]] {
            for (k, v) in a where v.count == 2 { ax[k] = CGPoint(x: v[0], y: v[1]) }
        }
        axes = ax
        var rg: [String: [CGPoint]] = [:]
        if let r = json["rings"] as? [String: [[Double]]] {
            for (k, v) in r { rg[k] = v.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
        }
        rings = rg
    }

    // Height-normalized distance (NDC x is compressed by aspect).
    private func screenDist(_ a: CGPoint, _ b: CGPoint, _ aspect: CGFloat) -> CGFloat {
        hypot((a.x - b.x) * aspect, a.y - b.y)
    }

    private func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ aspect: CGFloat) -> CGFloat {
        let pp = CGPoint(x: p.x * aspect, y: p.y), aa = CGPoint(x: a.x * aspect, y: a.y),
            bb = CGPoint(x: b.x * aspect, y: b.y)
        let dx = bb.x - aa.x, dy = bb.y - aa.y
        let len2 = dx * dx + dy * dy
        if len2 < 1e-12 { return hypot(pp.x - aa.x, pp.y - aa.y) }
        var t = ((pp.x - aa.x) * dx + (pp.y - aa.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(pp.x - (aa.x + t * dx), pp.y - (aa.y + t * dy))
    }

    /// Height-normalized area of a projected ring polyline (shoelace, NDC x
    /// compressed by aspect). A face-on ring has large area; an edge-on ring
    /// collapses to a line (area ≈ 0). Used to break ring-crossing ties toward
    /// the ring the user actually sees.
    private func ringArea(_ poly: [CGPoint], _ aspect: CGFloat) -> CGFloat {
        guard poly.count > 2 else { return 0 }
        var s: CGFloat = 0
        for i in 0..<(poly.count - 1) {
            s += (poly[i].x * aspect) * poly[i + 1].y - (poly[i + 1].x * aspect) * poly[i].y
        }
        return abs(s) * 0.5
    }

    /// Closest handle to an NDC point within hit thresholds, or nil. Arrows,
    /// rings and the center all compete at once (nearest wins) — the center is a
    /// normal candidate, NOT an absolute-priority disc.
    func hitTest(ndc p: CGPoint, aspect: CGFloat) -> GizmoHandle? {
        // Grab bands scale with the gizmo's on-screen size. A fixed NDC band is too
        // tight when zoomed in — there the rendered ring/arrow TUBES are visibly
        // thick (their width grows with the projected radius), so a hover that
        // clearly lands on the tube can still sit outside a small fixed band and
        // read as a miss (the "hover does nothing" symptom). Sizing the bands off
        // the projected gizmo radius keeps grabbing forgiving at every zoom, while
        // the floors keep it usable when the gizmo is small/far.
        var scale: CGFloat = 0
        for (_, poly) in rings { for p in poly { scale = max(scale, screenDist(p, center, aspect)) } }
        if scale <= 1e-6 {
            for (_, tip) in axes { scale = max(scale, screenDist(tip, center, aspect)) }
        }
        if scale <= 1e-6 { scale = 0.4 }
        let knobR: CGFloat = max(0.10, 0.20 * scale)   // arrow tip grab radius
        let lineR: CGFloat = max(0.05, 0.09 * scale)   // along-axis line grab distance
        let centerR: CGFloat = max(0.04, 0.07 * scale) // free center handle
        let ringR: CGFloat = max(0.06, 0.16 * scale)   // ring polyline grab distance

        let cD = screenDist(p, center, aspect)

        var best: (GizmoHandle, CGFloat)?
        func consider(_ h: GizmoHandle, _ d: CGFloat, _ limit: CGFloat) {
            if d <= limit, best == nil || d < best!.1 { best = (h, d) }
        }

        // Center free handle competes on distance instead of owning an absolute
        // disc. Considered FIRST (with strict `<` below), so it still wins ties at
        // dead-center, but a ring or arrow that is genuinely CLOSER under the
        // cursor now wins — which is why the old absolute disc made handles
        // unhittable: a near-camera axis arrow (foreshortened toward the center)
        // and the near-center arc of an edge-on ring both projected inside the
        // disc and were stolen as `.free`, so the element you hovered never
        // highlighted or grabbed.
        consider(.free, cD, centerR)

        // Axis tips (always compete) + along-axis lines. The three lines all
        // converge on the center, so their distToSegment ≈ 0 for any near-center
        // point; only count a line hit OUTSIDE the center disc, else the
        // overlapping lines would steal the free grab (the reason the ball was
        // unclickable except dead-center).
        let axisMap: [String: GizmoHandle] = ["x": .x, "y": .y, "z": .z]
        for (k, h) in axisMap {
            guard let tip = axes[k] else { continue }
            consider(h, screenDist(p, tip, aspect), knobR)
            if cD > centerR {
                consider(h, distToSegment(p, center, tip, aspect), lineR)
            }
        }

        // Rotation rings. The three great circles cross at 6 screen points where
        // their nearest segments tie; picking by iteration order made the grabbed
        // rotation axis feel random. Break near-ties toward the more FACE-ON ring
        // (larger projected area) — the prominent circle the user is aiming at,
        // not whichever edge-on ring's tip happens to cross there.
        let ringMap: [(String, GizmoHandle)] = [("x", .rx), ("y", .ry), ("z", .rz)]
        var bestRing: (GizmoHandle, CGFloat, CGFloat)?   // handle, dist, area
        for (k, h) in ringMap {
            guard let poly = rings[k], poly.count > 1 else { continue }
            var dmin = CGFloat.greatestFiniteMagnitude
            for i in 0..<(poly.count - 1) {
                dmin = min(dmin, distToSegment(p, poly[i], poly[i + 1], aspect))
            }
            let area = ringArea(poly, aspect)
            if bestRing == nil || dmin < bestRing!.1 - 0.01 ||
               (abs(dmin - bestRing!.1) <= 0.01 && area > bestRing!.2) {
                bestRing = (h, dmin, area)
            }
        }
        if let r = bestRing { consider(r.0, r.1, ringR) }

        return best?.0
    }

    /// Diagnostic variant of hitTest: returns the same result PLUS a
    /// human-readable breakdown of the cursor NDC, every handle's cached NDC
    /// position, its height-normalized distance and threshold, and the winner.
    /// Used only under PYMOL_GIZMODEBUG to root-cause element-selection issues
    /// (e.g. a cursor/geometry aspect mismatch that makes the ring un-hoverable).
    func hitTestDebug(ndc p: CGPoint, aspect: CGFloat) -> (GizmoHandle?, String) {
        let knobR: CGFloat = 0.07, lineR: CGFloat = 0.03, centerR: CGFloat = 0.04, ringR: CGFloat = 0.04
        var L: [String] = []
        L.append(String(format: "cursor=(% .4f,% .4f) aspect=%.4f obj=%@", p.x, p.y, aspect, obj))
        L.append(String(format: "center=(% .4f,% .4f) dist=%.4f thr=%.3f%@",
                        center.x, center.y, screenDist(p, center, aspect), centerR,
                        screenDist(p, center, aspect) <= centerR ? " <=HIT" : ""))
        for k in ["x", "y", "z"] {
            if let tip = axes[k] {
                let td = screenDist(p, tip, aspect), ld = distToSegment(p, center, tip, aspect)
                L.append(String(format: "axis %@ tip=(% .4f,% .4f) tipD=%.4f(thr%.2f) lineD=%.4f(thr%.2f)%@",
                                k, tip.x, tip.y, td, knobR, ld, lineR,
                                (td <= knobR || ld <= lineR) ? " <=HIT" : ""))
            } else { L.append("axis \(k) MISSING") }
        }
        for k in ["x", "y", "z"] {
            if let poly = rings[k], poly.count > 1 {
                var dmin = CGFloat.greatestFiniteMagnitude
                for i in 0..<(poly.count - 1) { dmin = min(dmin, distToSegment(p, poly[i], poly[i + 1], aspect)) }
                L.append(String(format: "ring r%@ segs=%d minD=%.4f thr=%.3f%@",
                                k, poly.count, dmin, ringR, dmin <= ringR ? " <=HIT" : ""))
            } else { L.append("ring r\(k) MISSING/empty") }
        }
        let hit = hitTest(ndc: p, aspect: aspect)
        L.append("WINNER=\(hit?.rawValue ?? "nil")")
        return (hit, L.joined(separator: "\n    "))
    }
}

// MARK: - Debug bullseye overlay (PYMOL_BULLSEYE=1)

/// Draws the gizmo's HIT-TEST targets (the projected geometry the hit-test
/// actually uses) plus a bullseye at the live cursor, over the viewport. It's the
/// visual twin of the PYMOL_GIZMODEBUG log: if the cursor bullseye sits on a
/// rendered ring/arrow but the nearest target markers are elsewhere — or the
/// "hover → …" label reads none while you're on an element — the mismatch is
/// visible immediately. Purely diagnostic, no hit-testing, never intercepts input.
struct GizmoBullseyeOverlay: View {
    let gizmo: GizmoGeometry?
    let cursorNDC: CGPoint?
    let hovered: GizmoHandle?

    // NDC (bottom-left origin, +y up) -> overlay points (top-left origin, +y down).
    private func toPx(_ n: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: (n.x + 1) / 2 * s.width, y: (1 - n.y) / 2 * s.height)
    }
    private func color(_ h: GizmoHandle) -> Color {
        switch h {
        case .x, .rx: return .red
        case .y, .ry: return .green
        case .z, .rz: return .blue
        case .free:   return .white
        }
    }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            Canvas { ctx, _ in
                if let g = gizmo {
                    let ringMap: [(String, GizmoHandle)] = [("x", .rx), ("y", .ry), ("z", .rz)]
                    for (k, h) in ringMap {
                        guard let poly = g.rings[k] else { continue }
                        let c = color(h); let on = hovered == h
                        for (i, p) in poly.enumerated() where i % 2 == 0 {
                            let q = toPx(p, s); let r: CGFloat = on ? 3 : 1.5
                            ctx.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)),
                                     with: .color(c.opacity(on ? 1 : 0.85)))
                        }
                    }
                    let axisMap: [(String, GizmoHandle)] = [("x", .x), ("y", .y), ("z", .z)]
                    for (k, h) in axisMap {
                        guard let tip = g.axes[k] else { continue }
                        let q = toPx(tip, s); let r: CGFloat = hovered == h ? 7 : 4.5
                        ctx.stroke(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)),
                                   with: .color(color(h)), lineWidth: 2)
                    }
                    let cc = toPx(g.center, s); let cr: CGFloat = hovered == .free ? 8 : 5
                    ctx.stroke(Path(ellipseIn: CGRect(x: cc.x - cr, y: cc.y - cr, width: 2 * cr, height: 2 * cr)),
                               with: .color(.white), lineWidth: 2)
                }
                if let n = cursorNDC {
                    let p = toPx(n, s)
                    for rr in [4.0, 9.0, 14.0] as [CGFloat] {
                        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr)),
                                   with: .color(.yellow), lineWidth: 1)
                    }
                    var cross = Path()
                    cross.move(to: CGPoint(x: p.x - 20, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 20, y: p.y))
                    cross.move(to: CGPoint(x: p.x, y: p.y - 20)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 20))
                    ctx.stroke(cross, with: .color(.yellow), lineWidth: 1)
                    ctx.draw(Text("hover → \(hovered?.rawValue ?? "none")")
                                .font(.system(size: 11, weight: .bold)).foregroundColor(.yellow),
                             at: CGPoint(x: p.x + 30, y: p.y - 14), anchor: .leading)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

