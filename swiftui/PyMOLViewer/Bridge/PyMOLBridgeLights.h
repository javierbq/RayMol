// PyMOLBridgeLights.h — C types for the light-rig bridge functions (#611).
//
// Pure C: types and constants only, no functions. Both PyMOLBridge.h (the
// Swift bridging header, which declares PyMOLBridge_Light*) and
// PyMOLBridge.mm (which defines them, and deliberately does not include
// PyMOLBridge.h) include this file, so the two sides share one definition.
//
// The structs mirror pymol::LightRigEye / pymol::LightEye (layer1/LightRig.h)
// as floats in eye space, for the overlays (#619-#622). Keep the values in
// step with layer1/LightRig.h; testing/tests/raymol/lighting_bridge.py checks
// the status codes and the light cap in CI.

#pragma once

// At most this many lights per rig (pymol::kLightRigMaxLights).
#define PYMOL_LIGHTS_MAX 6

// PyMOLBridge_LightSet / PyMOLBridge_LightSetVector results: the values of
// pymol::LightSetStatus. On anything but OK the rig is unchanged.
enum {
    PYMOL_LIGHT_SET_OK = 1,
    PYMOL_LIGHT_SET_UNKNOWN_FIELD = 0, // no such field (or a rig field at a light index, or vice versa)
    PYMOL_LIGHT_SET_BAD_INDEX = -1,    // index outside -1 ..< light count
    PYMOL_LIGHT_SET_REFUSED = -2,      // e.g. a 4th shadowed light; text fields and the frame
    PYMOL_LIGHT_SET_BAD_VALUE = -3,    // NaN, inf, or not a valid choice
    PYMOL_LIGHT_SET_NO_RIG = -4,       // there is no rig (or no instance)
};

// The rig resolved to eye space for the live camera.
typedef struct {
    float centre[3];   // eye space; valid when hasFrame
    float size;        // Å (the rig's 1x); valid when hasFrame
    int enabled;       // 0 | 1
    int hasFrame;      // 0 only for an empty rig that has no frame yet
    int count;         // number of lights in the rig
} PyMOLLightRigEye;

// One light resolved to eye space; lights[i] is light i of the rig.
typedef struct {
    float position[3];  // eye space
    float target[3];    // eye-space aim point: the centre, or the light's point
    float direction[3]; // unit, from position to target
    float aimDistance;  // |target - position|
    float cosOuter;     // cos(beam / 2)
    float cosInner;     // where the soft edge starts (> cosOuter, <= 1)
    float orbit;        // degrees; current (derived from the position when pinned)
    float pitch;        // degrees; current
    float radius;       // scene sizes; current
    int anchor;         // 0 camera, 1 pinned
    int aim;            // 0 centre, 1 point
    int shadow;         // 0 | 1
    int outline;        // 0 | 1
} PyMOLLightEye;
