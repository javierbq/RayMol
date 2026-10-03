/*
 * The scene's light rig (#611): ownership, frame capture and re-centre.
 *
 * One rig per PyMOL instance, held by the scene (CScene::lightRig; decision 1
 * of #610). No rig (std::nullopt) and a rig that is present but disabled are
 * different states: sessions, scenes and the L1 check rely on telling them
 * apart. Nothing in rendering reads the rig yet (#613 will).
 *
 * No Python here (LightRigPy.h has the conversions), so the app bridge can
 * call these directly, one call per drag tick, on the main thread.
 */

#pragma once

#include <optional>

#include "LightRig.h"
#include "Result.h"

struct PyMOLGlobals;

/// The rig, or nullptr when there is none.
const pymol::LightRig* SceneGetLightRig(PyMOLGlobals* G);

/**
 * Store `rig` (std::nullopt removes it) and request a redraw. Setting no rig
 * when there is none does nothing at all, so the no-rig path runs no code.
 * The rig is stored as given: callers validate first.
 */
void SceneSetLightRig(PyMOLGlobals* G, std::optional<pymol::LightRig> rig);

/**
 * Replace the rig with `rig`: capture its frame when it has lights and no
 * centre/size, then validate, then store. On error the current rig is left
 * unchanged.
 */
pymol::Result<> SceneLightsReplace(PyMOLGlobals* G, pymol::LightRig rig);

/**
 * The rig frame for the current scene (spec §4.3): the box of the enabled
 * objects' atoms in the current state, solvent excluded. The centre is the
 * box midpoint and the size half its diagonal (at least 1 Å). Falls back to
 * every enabled atom when only solvent is enabled, and to the rotation origin
 * with 10 Å when no atoms are enabled (an empty scene, or only maps / CGOs).
 */
void SceneLightRigCapture(PyMOLGlobals* G, glm::dvec3& centre, double& size);

/// Capture the frame again (`lights recenter`). Error when there is no rig.
pymol::Result<> SceneLightsRecenter(PyMOLGlobals* G);
