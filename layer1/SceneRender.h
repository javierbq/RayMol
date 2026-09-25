
/* 
A* -------------------------------------------------------------------
B* This file contains source code for the PyMOL computer program
C* Copyright (c) Schrodinger, LLC. 
D* -------------------------------------------------------------------
E* It is unlawful to modify or remove this copyright notice.
F* -------------------------------------------------------------------
G* Please see the accompanying LICENSE file for further information. 
H* -------------------------------------------------------------------
I* Additional authors of this source file include:
-* 
-* 
-*
Z* -------------------------------------------------------------------
*/

#ifndef _H_SceneRender
#define _H_SceneRender

#include "Picking.h"
#include "RenderPass.h"
#include "os_gl.h"

#include <optional>
#include <vector>

enum class SceneRenderWhich {
  NonGadgets = 1 << 0,
  Gadgets = 1 << 1,
  Gizmos = 1 << 2,
  GizmosAndGadgets = Gizmos | Gadgets,
  All = NonGadgets | Gadgets | Gizmos,
};

enum class SceneRenderOrder {
  Arbitrary,
  GadgetsLast,
};

struct SceneRenderInfo
{
  Picking* pick = nullptr;
  Offset2D mousePos{};
  Multipick* sceneMultipick = nullptr;
  std::optional<Rect2D> viewportOverride;
  ClickSide clickSide = ClickSide::None;
  bool forceCopy = false;
  bool excludeSelections = false;
  bool excludeGadgets = false;
  SceneRenderWhich renderWhich = SceneRenderWhich::All;
  bool offscreen = false;
  std::optional<GLFramebufferConfig> offscreenConfig;
};

void SceneRender(PyMOLGlobals* G, const SceneRenderInfo& renderInfo);
void SceneRenderMetal(PyMOLGlobals* G);
void SceneRenderMetalSelections(PyMOLGlobals* G);
/**
 * @param only_object when non-null, render ONLY this object and skip every
 *   other one. Used by the per-object transparent depth peel (#488), which has
 *   to replay one object on its own -- first depth-only into the peel target,
 *   then into the OIT targets -- and must not disturb how the rest of the pass
 *   is assembled.
 */
void SceneRenderAll(PyMOLGlobals * G, SceneUnitContext * context,
                    float *normal, PickColorManager*,
                    RenderPass pass, int fat, float width_scale,
                    GridInfo * grid, int dynamic_pass, SceneRenderWhich which_objects,
                    SceneRenderOrder render_order,
                    pymol::CObject* only_object = nullptr);

void SceneInitializeViewport(PyMOLGlobals* G, bool offscreen);

void GridSetViewport(PyMOLGlobals* G, GridInfo * I, int slot);

/**
 * Sets scene projection matrix
 *
 * @param front - front clipping plane
 * @param back - back clipping plane
 * @param aspRat - aspect ratio
 */
void SceneProjectionMatrix(PyMOLGlobals* G, float front, float back, float aspRat);

#endif

