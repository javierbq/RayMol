// LightGizmoGeometry.swift — the light gizmo's camera, projection and
// front/behind rule (#622, spec §4.3 and §9).
//
// The gizmo is a SwiftUI overlay, never scene geometry: it draws the rig from
// the eye-space read LightsController publishes (`eye.eyeSpace`) through a
// projection built here in Swift from the live camera (`captureView()`'s 25
// floats, the letterbox aspect and, as a fallback, the polled field_of_view).
// The projection mirrors the renderer's (SceneProjectionMatrix in
// layer1/SceneRender.cpp) and the surface pick's (pymol.metal_pick.camera):
// the perspective half-height slope at unit depth is tan(GetFovWidth / 2),
// GetFovWidth being 2 tan(fov / 2), because glm::perspective takes the tan of
// half its argument; the orthoscopic half height is
// max(1e-4, camera distance) GetFovWidth / 2. testing/tests/raymol/
// lighting_gizmo.py checks both formulas against those sources.
//
// Pure value types: no engine, no Python, no bridge call (the engine's
// `lightCameraProjection()` reads the camera; lighting_mode.py checks this
// file names no Python or console entry point).

import CoreGraphics
import Foundation

// MARK: - The camera

/// What the gizmo needs of the live camera to project eye-space points.
struct LightCameraProjection: Equatable {
    /// `orthoscopic` is on.
    var orthoscopic: Bool
    /// The vertical field of view, degrees (above 1 and under 180).
    var fovDegrees: Double
    /// The camera's distance from the rotation origin along the view axis
    /// (-view[18]): the orthoscopic height scales with it.
    var cameraDistance: Double
    /// The live frame's letterbox aspect (width / height of the sub-rect the
    /// scene is drawn into); 0 when the scene fills the view.
    var letterboxAspect: Double

    init(orthoscopic: Bool, fovDegrees: Double, cameraDistance: Double,
         letterboxAspect: Double) {
        self.orthoscopic = orthoscopic
        self.fovDegrees = fovDegrees
        self.cameraDistance = cameraDistance
        self.letterboxAspect = letterboxAspect.isFinite && letterboxAspect > 0 ? letterboxAspect : 0
    }

    /// From `PyMOLBridge_GetView`'s 25 floats (SceneGetView: view[18] is the
    /// camera's z, view[24] +fov when orthoscopic and -fov otherwise), the
    /// letterbox aspect and the polled `field_of_view` setting. When
    /// |view[24]| is 1 or less the setting is used instead, as
    /// metal_pick.camera falls back to it. nil unless there are 25 finite
    /// floats and a field of view above 1 and under 180 degrees.
    init?(view: [Float], letterboxAspect: Float, fieldOfView: Float?) {
        guard view.count == 25, view.allSatisfy({ $0.isFinite }) else { return nil }
        var fov = Double(abs(view[24]))
        if fov <= 1 {
            guard let setting = fieldOfView, setting.isFinite, setting > 1 else { return nil }
            fov = Double(setting)
        }
        guard fov < 180 else { return nil }
        self.init(orthoscopic: view[24] > 0, fovDegrees: fov,
                  cameraDistance: -Double(view[18]),
                  letterboxAspect: Double(letterboxAspect))
        guard slope.isFinite, slope > 0 else { return nil }
    }

    /// The field-of-view width at unit depth: GetFovWidth (layer1/Scene.cpp),
    /// 2 tan(fov / 2).
    var fovWidth: Double { 2 * tan(fovDegrees * .pi / 360) }

    /// The perspective half-height slope at unit depth, as the renderer
    /// applies it: glm::perspective(GetFovWidth) takes tan of half its
    /// argument, so tan(fovWidth / 2) (metal_pick.camera's tan_half).
    var slope: Double { tan(fovWidth / 2) }

    /// The orthoscopic half height of the view volume, in Å
    /// (SceneProjectionMatrix: max(1e-4, -pos.z) GetFovWidth / 2).
    var orthoHalfHeight: Double { max(1e-4, cameraDistance) * fovWidth / 2 }
}

// MARK: - The projection

/// Eye space to view points (top-left origin, y down, as SwiftUI draws) for a
/// view of `viewSize` points, and back: the inverse of what the renderer and
/// the surface pick do. With a letterbox the scene is drawn into the centred
/// sub-rect of that aspect (full height when the view is wider, else full
/// width), as `SurfacePick.sceneNDC` maps it.
struct LightGizmoProjection: Equatable {
    let camera: LightCameraProjection
    let viewSize: CGSize
    /// Where the scene is drawn, in view points.
    let sceneRect: CGRect

    /// A perspective point must be at least this far in front of the eye.
    static let nearDepth = 1e-3

    init?(camera: LightCameraProjection, viewSize: CGSize) {
        let w = Double(viewSize.width), h = Double(viewSize.height)
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
        self.camera = camera
        self.viewSize = viewSize
        let letterbox = camera.letterboxAspect
        if letterbox > 0 {
            if w / h > letterbox {
                let width = h * letterbox   // bars left and right
                sceneRect = CGRect(x: (w - width) / 2, y: 0, width: width, height: h)
            } else {
                let height = w / letterbox  // bars top and bottom
                sceneRect = CGRect(x: 0, y: (h - height) / 2, width: w, height: height)
            }
        } else {
            sceneRect = CGRect(origin: .zero, size: viewSize)
        }
    }

    /// The scene rect's width / height: the projection's aspect.
    var aspect: Double { Double(sceneRect.width / sceneRect.height) }

    /// The scene NDC (x and y in [-1, 1] over the scene rect, +y up) of an
    /// eye-space point; nil behind the near plane (perspective) or for a
    /// non-finite point.
    func sceneNDC(eye e: SIMD3<Double>) -> SIMD2<Double>? {
        guard e.x.isFinite, e.y.isFinite, e.z.isFinite else { return nil }
        if camera.orthoscopic {
            let hh = camera.orthoHalfHeight
            return SIMD2(e.x / (hh * aspect), e.y / hh)
        }
        let depth = -e.z
        guard depth > Self.nearDepth else { return nil }
        let t = camera.slope
        return SIMD2(e.x / (depth * t * aspect), e.y / (depth * t))
    }

    /// The view point of an eye-space point (see `sceneNDC(eye:)`).
    func point(eye: SIMD3<Double>) -> CGPoint? {
        sceneNDC(eye: eye).map(point(sceneNDC:))
    }

    func point(eye: SIMD3<Float>) -> CGPoint? {
        point(eye: SIMD3<Double>(Double(eye.x), Double(eye.y), Double(eye.z)))
    }

    /// The view point of a scene NDC (not clipped to the scene rect).
    func point(sceneNDC s: SIMD2<Double>) -> CGPoint {
        CGPoint(x: Double(sceneRect.minX) + (s.x + 1) / 2 * Double(sceneRect.width),
                y: Double(sceneRect.minY) + (1 - s.y) / 2 * Double(sceneRect.height))
    }

    /// The scene NDC of a view point, not clipped to the scene rect (a point
    /// in a letterbox bar is outside [-1, 1]).
    func unclampedSceneNDC(point p: CGPoint) -> SIMD2<Double> {
        SIMD2(2 * Double(p.x - sceneRect.minX) / Double(sceneRect.width) - 1,
              1 - 2 * Double(p.y - sceneRect.minY) / Double(sceneRect.height))
    }

    /// The scene NDC of a view point for `lights <name>, click=x/y`: nil in
    /// the letterbox bars or for a non-finite point (a point on the scene
    /// rect's edge is clamped onto it, as `SurfacePick.sceneNDC` does).
    func sceneNDC(point p: CGPoint) -> SIMD2<Double>? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let s = unclampedSceneNDC(point: p)
        let slack = 1e-5
        guard abs(s.x) <= 1 + slack, abs(s.y) <= 1 + slack else { return nil }
        return SIMD2(min(max(s.x, -1), 1), min(max(s.y, -1), 1))
    }

    /// The whole view's NDC of a view point (+y up), what `pickSurface`
    /// takes with the view's aspect; it applies the letterbox itself.
    func viewNDC(point p: CGPoint) -> SIMD2<Double> {
        SIMD2(2 * Double(p.x) / Double(viewSize.width) - 1,
              1 - 2 * Double(p.y) / Double(viewSize.height))
    }

    /// The camera ray through a view point, in eye space: from the eye along
    /// unit(ndc.x t a, ndc.y t, -1) in perspective; from (ndc.x h a, ndc.y h,
    /// 0) along -z when orthoscopic. nil for a non-finite point.
    func ray(at p: CGPoint) -> (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let s = unclampedSceneNDC(point: p)
        if camera.orthoscopic {
            let hh = camera.orthoHalfHeight
            return (SIMD3(s.x * hh * aspect, s.y * hh, 0), SIMD3(0, 0, -1))
        }
        let t = camera.slope
        let d = SIMD3(s.x * t * aspect, s.y * t, -1.0)
        let length = (d * d).sum().squareRoot()
        return (.zero, d / length)
    }

    /// View points per Å at eye depth `z` (a negative z is in front of the
    /// eye): what a length in the scene measures on screen there. nil behind
    /// the near plane in perspective.
    func pointsPerAngstrom(atDepth z: Double) -> Double? {
        let half = Double(sceneRect.height) / 2
        if camera.orthoscopic { return half / camera.orthoHalfHeight }
        let depth = -z
        guard z.isFinite, depth > Self.nearDepth else { return nil }
        return half / (depth * camera.slope)
    }
}

// MARK: - Front and behind

/// Whether a light is behind the molecule: behind the rig centre in eye depth
/// (spec §4.3: +z towards the viewer), the one rule for the gizmo's knobs and
/// the bar's chips. The value tested is the z of the light's unit offset from
/// the centre, cos(orbit) cos(pitch).
enum LightDepth {
    /// Below -tolerance counts as behind: float noise in a pinned light's eye
    /// read (about 1e-6) never flips a light sitting on the outline.
    static let tolerance = 1e-4

    /// Orbit and pitch in degrees.
    static func isBehind(orbit: Double, pitch: Double) -> Bool {
        cos(orbit * .pi / 180) * cos(pitch * .pi / 180) < -tolerance
    }

    static func isBehind(_ placement: LightPlacement) -> Bool {
        isBehind(orbit: placement.orbit, pitch: placement.pitch)
    }
}
