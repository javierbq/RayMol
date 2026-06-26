/*
 * (c) Schrodinger, Inc.
 */

#include <algorithm>

#include "CGO.h"
#include "Control.h"
#include "Editor.h"
#include "Err.h"
#include "Executive.h"
#include "Feedback.h"
#include "Matrix.h"
#include "Ortho.h"
#include "P.h"
#include "Picking.h"
#include "PyMOLOptions.h"
#include "Scene.h"
#include "ScenePicking.h"
#include "SceneRay.h"
#include "ShaderMgr.h"
#include "Util.h"
#include "main.h"
#include "pymol/utility.h"
#include "ImmediateHelper.h"
#include "Renderer.h"

// Bridge function for main_appkit.mm which cannot include GLEW headers.
void ImmBatch_SetActiveRenderer(pymol::Renderer* r) {
  ImmBatch::setActiveRenderer(r);
}

#ifdef _PYMOL_OPENVR
#include "OpenVRMode.h"
#endif

/* EXPERIMENTAL VOLUME RAYTRACING DATA */
extern float* rayDepthPixels;
extern int rayVolume, rayWidth, rayHeight;

static void SetDrawBufferForStereo(
    PyMOLGlobals* G, CScene* I, int stereo_mode, int times, int fog_active);
static void SceneDrawStencilInBuffer(
    PyMOLGlobals* G, CScene* I, int stereo_mode);

static void SceneRenderStereoLoop(PyMOLGlobals* G, int timesArg,
    int must_render_stereo, int stereo_mode, bool render_to_texture,
    const Offset2D& pos, const std::optional<Rect2D>& viewportOverride,
    int stereo_double_pump_mono, int curState, float* normal,
    SceneUnitContext* context, float width_scale, int fog_active,
    bool onlySelections, bool noAA, bool excludeSelections,
    SceneRenderWhich which_objects = SceneRenderWhich::All);

static void SceneRenderAA(PyMOLGlobals* G, const GLFramebufferConfig& config);

static void PrepareViewPortForStereoImpl(PyMOLGlobals* G, CScene* I,
    int stereo_mode, bool offscreen, int times, const Offset2D& pos,
    const std::optional<Rect2D>& viewportOverride, GLenum draw_mode,
    int position /* left=0, right=1 */);

static void PrepareViewPortForMonoInitializeViewPort(PyMOLGlobals* G, CScene* I,
    int stereo_mode, bool offscreen, int times, const Offset2D& pos,
    const std::optional<Rect2D>& viewportOverride);

static void PrepareViewPortForStereo(PyMOLGlobals* G, CScene* I,
    int stereo_mode, bool offscreen, int times, const Offset2D& pos,
    const std::optional<Rect2D>& viewportOverride);

static void PrepareViewPortForStereo2nd(PyMOLGlobals* G, CScene* I,
    int stereo_mode, bool offscreen, int times, const Offset2D& pos,
    const std::optional<Rect2D>& viewportOverride);

static void InitializeViewPortToScreenBlock(PyMOLGlobals* G, CScene* I,
    const Offset2D& pos, const std::optional<Rect2D>& viewportOverride, int* stereo_mode,
    float* width_scale);

static void SceneSetPrepareViewPortForStereo(PyMOLGlobals* G,
    PrepareViewportForStereoFuncT prepareViewportForStereo, int times,
    const Offset2D& pos, const std::optional<Rect2D>& viewportOverride, int stereo_mode,
    float width_scale);

static CGO* GenerateUnitScreenCGO(PyMOLGlobals* G);

static bool NeedsOffscreenTextureForPP(PyMOLGlobals* G);

static void SceneRenderPostProcessStack(PyMOLGlobals* G, const GLFramebufferConfig& parentImage);

static int stereo_via_stencil(int stereo_mode)
{
  switch (stereo_mode) {
  case cStereo_stencil_by_row:
  case cStereo_stencil_by_column:
  case cStereo_stencil_checkerboard:
  case cStereo_stencil_custom:
    return true;
  }
  return false;
}

static int render_stereo_blend_into_full_screen(int stereo_mode)
{
  switch (stereo_mode) {
  case cStereo_stencil_by_row:
  case cStereo_stencil_by_column:
  case cStereo_stencil_checkerboard:
  case cStereo_stencil_custom:
  case cStereo_anaglyph:
  case cStereo_dynamic:
  case cStereo_clone_dynamic:
    return true;
  }
  return false;
}

void GridSetViewport(PyMOLGlobals* G, GridInfo* I, int slot)
{
  if (slot)
    I->slot = slot + I->first_slot - 1;
  else
    I->slot = slot;
  /* if we are in grid mode, then prepare the grid slot viewport */
  if (slot < 0) {
    SceneSetViewport(G, I->cur_view);
  } else if (!slot) { /* slot 0 is the full screen */
    Rect2D view{};
    view.offset = Offset2D{};
    view.extent.width = I->cur_view.extent.width / I->n_col;
    view.extent.height = I->cur_view.extent.height / I->n_row;
    if (I->n_col < I->n_row) {
      view.extent.width *= I->n_col;
      view.extent.height *= I->n_col;
    } else {
      view.extent.width *= I->n_row;
      view.extent.height *= I->n_row;
    }
    view.offset.x += I->cur_view.offset.x +
                     (I->cur_view.extent.width - view.extent.width) / 2;
    view.offset.y += I->cur_view.offset.y;
    SceneSetViewport(G, view);
    I->context = ScenePrepareUnitContext(view.extent);
  } else {
    int abs_grid_slot = slot - I->first_slot;
    int grid_col = abs_grid_slot % I->n_col;
    int grid_row = (abs_grid_slot / I->n_col);
    Rect2D view{};
    view.offset.x = (grid_col * I->cur_view.extent.width) / I->n_col;
    view.extent.width =
        ((grid_col + 1) * I->cur_view.extent.width) / I->n_col - view.offset.x;
    view.offset.y = I->cur_view.extent.height -
                    ((grid_row + 1) * I->cur_view.extent.height) / I->n_row;
    view.extent.height =
        (I->cur_view.extent.height -
            ((grid_row) *I->cur_view.extent.height) / I->n_row) -
        view.offset.y;
    view.offset.x += I->cur_view.offset.x;
    view.offset.y += I->cur_view.offset.y;
    I->cur_viewport_size = view.extent;
    SceneSetViewport(G, view);
    I->context = ScenePrepareUnitContext(view.extent);
  }
}

static void glBlendFunc_default()
{
  if (glBlendFuncSeparate) {
    glBlendFuncSeparate(
        GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
  } else {
    // OpenGL 1.x (e.g. remote desktop on Windows)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  }
}

void SceneProjectionMatrix(PyMOLGlobals* G, float front, float back, float aspRat)
{
  CScene* I = G->Scene;
  int stereo_mode = I->StereoMode;

  if (!SettingGet<bool>(G, cSetting_ortho)) {
    front = stereo_mode == cStereo_openvr ? 0.1f : front;
    I->projectionMatrix = glm::perspective(GetFovWidth(G), aspRat, front, back);
  } else {
    float height =
        std::max(R_SMALL4, -I->m_view.pos().z) * GetFovWidth(G) / 2.f;
    float width = height * aspRat;
    I->projectionMatrix =
        glm::ortho(-width, width, -height, height, front, back);
  }

#ifndef PURE_OPENGL_ES_2
  if (!G->Renderer && ALWAYS_IMMEDIATE_OR(!use_shaders)) {
    glMatrixMode(GL_PROJECTION);
    glLoadMatrixf(SceneGetProjectionMatrixPtr(G));
    glMatrixMode(GL_MODELVIEW);
  }
#endif
}

/*========================================================================*/
/* SceneRender: Responsible for rendering the scene, whether its picking
                (SceneRenderPicking) or rendering (SceneRenderStereoLoop).
                It also takes calls anti-aliasing (SceneRenderAA) if
                necessary after rendering and before selection markers.
 */
void SceneRender(PyMOLGlobals* G, const SceneRenderInfo& renderInfo)
{
  // When Metal is active, skip the GL-heavy render pipeline.
  // Metal rendering is handled by RendererMetal via drawInMTKView.
  if (G->Renderer) {
    return;
  }

  /* think in terms of the camera's world */
  CScene* I = G->Scene;
  float normal[4] = {0.0, 0.0, 1.0, 0.0};
  auto aspRat = SceneGetAspectRatio(G);
  double start_time = 0.0;

  float width_scale = 0.0F;
  auto stereo = SettingGet<bool>(G, cSetting_stereo);
  bool use_shaders = SettingGet<bool>(G, cSetting_use_shaders);
  int last_grid_active = I->grid.active;
  I->n_texture_refreshes = 0;
#if defined(_WEBGL) && defined(PYMOL_EVAL)
  if (!OrthoEvalCheck(G))
    return;
#endif
  PRINTFD(G, FB_Scene)
  " SceneRender: entered. pick %p x %d y %d smp %p\n", (void*) renderInfo.pick,
      renderInfo.mousePos.x, renderInfo.mousePos.y,
      (void*) renderInfo.sceneMultipick ENDFD;

  G->ShaderMgr->Check_Reload();

  auto const last_grid_shape = std::array<int, 2>{I->grid.n_col, I->grid.n_row};

  auto grid_mode = SettingGet<GridMode>(G, cSetting_grid_mode);
  int grid_size = 0;
  if (grid_mode != GridMode::NoGrid) {
    grid_size = SceneGetGridSize(G, grid_mode);
    GridUpdate(&I->grid, aspRat, grid_mode, grid_size);
    if (I->grid.active)
      aspRat *= I->grid.asp_adjust;
  } else {
    I->grid.active = false;
  }

  auto const grid_shape = std::array<int, 2>{I->grid.n_col, I->grid.n_row};

  if (last_grid_shape != grid_shape &&
      SettingGet<BgGradient>(G, cSetting_bg_gradient) == BgGradient::Grid) {
    OrthoBackgroundTextureNeedsUpdate(G);
  }

  if (last_grid_active != I->grid.active || grid_size != I->last_grid_size) {
    G->ShaderMgr->ResetUniformSet();
  }
  I->last_grid_size = grid_size;
  G->ShaderMgr->FreeAllVBOs();
  SceneUpdateAnimation(G);

  auto render_buffer = SceneMustDrawBoth(G)
                           ? GL_BACK_LEFT
                           : G->ShaderMgr->defaultBackbuffer.drawBuffer;
  GLFramebufferConfig targetImage{};
  targetImage.drawBuffer = render_buffer;
  if (renderInfo.offscreenConfig) {
    targetImage = *renderInfo.offscreenConfig;
  }

  int stereo_mode = I->StereoMode;
  bool postprocessOnce{false};
  switch (stereo_mode) {
  case cStereo_walleye:
  case cStereo_crosseye:
    aspRat = aspRat / 2;
  case cStereo_sidebyside:
  case cStereo_anaglyph:
    postprocessOnce = stereo;
    break;
  default:
    postprocessOnce = !stereo;
  }
  if (G->HaveGUI && G->ValidContext) {

    if (Feedback(G, FB_OpenGL, FB_Debugging))
      PyMOLCheckOpenGLErr("SceneRender checkpoint 0");

    int stereo_double_pump_mono = false;
    bool must_render_stereo =
        (stereo && stereo_mode != 0); // are we doing stereo?
    if (!must_render_stereo) {
      if (G->StereoCapable &&
          SettingGet<int>(G, nullptr, nullptr, cSetting_stereo_double_pump_mono)) {
        /* force stereo rendering */
        must_render_stereo = true;
        stereo_double_pump_mono = true;
      }
    }
    /* if we seem to be configured for hardware stereo,
       but can't actually do it, then fallback on mono --
       this would happen for instance if fullscreen is stereo-component
       and windowed is not */
    if (must_render_stereo && (stereo_mode < cStereo_crosseye) &&
        !(G->StereoCapable)) {
      must_render_stereo = false;
    }

    /* If we are rendering a stereo_mode that stencils, define the stencil
     * buffer */
    if (must_render_stereo && stereo_via_stencil(stereo_mode)) {
      if (!I->StencilValid) {
        SceneDrawStencilInBuffer(G, I, stereo_mode);
        I->StencilValid = true;
      }
    }

    render_buffer = G->ShaderMgr->defaultBackbuffer.drawBuffer; // GL_BACK

    // This probably should be decided up the stack...
    if (must_render_stereo) {
      switch (stereo_mode) {
      case cStereo_quadbuffer: /* hardware stereo */
      case cStereo_clone_dynamic:
      case cStereo_openvr:
        render_buffer = GL_BACK_LEFT;
        break;
      }
    }

    GLFramebufferConfig targetImage{};
    targetImage.framebuffer = renderInfo.offscreen
                                  ? G->ShaderMgr->offscreen_ortho_rt
                                  : G->ShaderMgr->topLevelConfig.framebuffer;

    if (renderInfo.pick != nullptr || renderInfo.sceneMultipick != nullptr) {
      targetImage.framebuffer = CShaderMgr::OpenGLDefaultFramebufferID;
    }

    if (targetImage.framebuffer == CShaderMgr::OpenGLDefaultFramebufferID) {
      targetImage.drawBuffer = render_buffer;
    }
    if (renderInfo.offscreenConfig) {
      targetImage = *renderInfo.offscreenConfig;
    }
    G->ShaderMgr->setDrawBuffer(targetImage);

    if (Feedback(G, FB_OpenGL, FB_Debugging))
      PyMOLCheckOpenGLErr("SceneRender checkpoint 1");

    auto view_save = SceneGetViewport(G);
    InitializeViewPortToScreenBlock(G, I, renderInfo.mousePos,
        renderInfo.viewportOverride, &stereo_mode, &width_scale);

    if (!(renderInfo.pick || renderInfo.sceneMultipick))
      bg_grad(G);

    if (G->Renderer) {
      G->Renderer->lineWidth(SettingGet<float>(G, cSetting_line_width));
      G->Renderer->enable(pymol::Capability::DepthTest);
      G->Renderer->pointSize(SettingGet<float>(G, cSetting_dot_width));
    } else {
#ifndef _WEBGL
      glLineWidth(SettingGet<float>(G, cSetting_line_width));
#endif
      glEnable(GL_DEPTH_TEST);

      /* get matrixes for unit objects */
#ifndef PURE_OPENGL_ES_2
      if (SettingGet<bool>(G, cSetting_line_smooth)) {
        if (!(renderInfo.pick || renderInfo.sceneMultipick)) {
          glEnable(GL_LINE_SMOOTH);
          glHint(GL_LINE_SMOOTH_HINT, GL_NICEST);
        }
      } else {
        glDisable(GL_LINE_SMOOTH);
      }
      glPointSize(SettingGet<float>(G, cSetting_dot_width));

      if (ALWAYS_IMMEDIATE_OR(!use_shaders)) {
        glEnable(GL_NORMALIZE); /* get rid of this to boost performance */

        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();
        /* must be done with identity MODELVIEW */
        SceneProgramLighting(G);
      }
#endif
    }
    auto scene_extent = SceneGetExtent(G);
    auto context = ScenePrepareUnitContext(scene_extent);
    /* do standard 3D objects */
    /* Set up the clipping planes */

    int curState = -1;
    if (!SettingGet<bool>(G, cSetting_all_states)) {
      curState = std::max(-1, SettingGet<int>(G, cSetting_state) - 1);
    }

    SceneProjectionMatrix(
        G, I->m_view.m_clipSafe().m_front, I->m_view.m_clipSafe().m_back, aspRat);
    ScenePrepareMatrix(G, 0);

    // Load the computed matrices into the Renderer (Metal) so batch
    // drawing uses the correct projection and modelview transforms.
    if (G->Renderer) {
      G->Renderer->matrixMode(1); // projection
      G->Renderer->loadMatrixf(SceneGetProjectionMatrixPtr(G));
      G->Renderer->matrixMode(0); // modelview
      G->Renderer->loadMatrixf(SceneGetModelViewMatrixPtr(G));
    }

    /* get the Z axis vector for sorting transparent objects */

    if (SettingGet<bool>(G, cSetting_transparency_global_sort) &&
        SettingGet<bool>(G, cSetting_transparency_mode)) {
      if (!I->AlphaCGO)
        I->AlphaCGO = CGONew(G);
    } else {
      CGOFree(I->AlphaCGO);
    }

    /* make note of how large pixels are at the origin  */

    I->VertexScale = SceneGetScreenVertexScale(G, nullptr);

    /* determine the direction in which we are looking relative */

    /* 2. set the normals to reflect light back at the camera */

    float zAxis[4] = {0.0, 0.0, 1.0, 0.0};
    MatrixInvTransformC44fAs33f3f(
        glm::value_ptr(I->m_view.rotMatrix()), zAxis, normal);
    copy3f(normal, I->ViewNormal);

    if (SettingGet<bool>(G, cSetting_normal_workaround)) {
      I->LinesNormal[0] = 0.0;
      I->LinesNormal[1] = 0.0;
      I->LinesNormal[2] = 1.0;
      /* for versions of GL that don't transform GL_LINES normals */
    } else {
      I->LinesNormal[0] = I->ViewNormal[0];
      I->LinesNormal[1] = I->ViewNormal[1];
      I->LinesNormal[2] = I->ViewNormal[2];
    }

    PRINTFD(G, FB_Scene)
    " SceneRender: matrices loaded. rendering objects...\n" ENDFD;

    /* 1. render all objects */
    if (renderInfo.pick || renderInfo.sceneMultipick) {
      SceneRenderPicking(G, stereo_mode, renderInfo.clickSide,
          stereo_double_pump_mono, renderInfo.pick, renderInfo.mousePos.x,
          renderInfo.mousePos.y, renderInfo.sceneMultipick, &context,
          render_buffer);
    } else {
      int times = 1;
      bool render_to_texture_for_pp{false};
      /* STANDARD RENDERING */

      start_time = UtilGetSeconds(G);

      glEnable(GL_BLEND);
      glBlendFunc_default();

      glEnable(GL_DITHER);

#ifndef PURE_OPENGL_ES_2
      if (ALWAYS_IMMEDIATE_OR(!use_shaders)) {
        glColorMaterial(GL_FRONT_AND_BACK, GL_AMBIENT_AND_DIFFUSE);
        glEnable(GL_COLOR_MATERIAL);
        glShadeModel(
            SettingGet<bool>(G, cSetting_pick_shading) ? GL_FLAT : GL_SMOOTH);

        if (use_shaders) {
          glDisable(GL_ALPHA_TEST);
        } else {
          // for immediate mode labels (with shaders, this would cause the OS X
          // R9 bugs!)
          glAlphaFunc(GL_GREATER, 0.05F);
          glEnable(GL_ALPHA_TEST);
        }

        if (G->Option->multisample)
          glEnable(0x809D); /* GL_MULTISAMPLE_ARB */
        glColor4ub(255, 255, 255, 255);
        glNormal3fv(normal);
      }
#endif

      auto fog_active = SceneSetFog(G);

#ifndef _PYMOL_NO_AA_SHADERS
      if (renderInfo.viewportOverride && false) {
        // Does not apply to Open-Source PyMOL
        render_to_texture_for_pp = NeedsOffscreenTextureForPP(G);
      }
      if (render_to_texture_for_pp) {
        if (!must_render_stereo || postprocessOnce) {
          G->ShaderMgr->bindOffscreen(I->Width, I->Height, &I->grid);
          bg_grad(G);
        }
      }
#endif
      /* rendering for visualization */

      /*** THIS IS AN UGLY EXPERIMENTAL
       *** VOLUME + RAYTRACING COMPOSITION CODE
       ***/
      if (rayVolume && rayDepthPixels) {
        SceneRenderRayVolume(G, I);
        rayVolume--;
      }
      /*** END OF EXPERIMENTAL CODE ***/

      switch (stereo_mode) {
      case cStereo_clone_dynamic:
      case cStereo_dynamic:
        times = 2;
        break;
      }
      PRINTFD(G, FB_Scene)
      " SceneRender: I->StereoMode %d must_render_stereo %d\n    StereoCapable "
      "%d\n",
          stereo_mode, must_render_stereo, G->StereoCapable ENDFD;

      bool onlySelections{false};
      SceneRenderStereoLoop(G, times, must_render_stereo, stereo_mode,
          render_to_texture_for_pp, renderInfo.mousePos,
          renderInfo.viewportOverride, stereo_double_pump_mono, curState, normal,
          &context, width_scale, fog_active, onlySelections, postprocessOnce,
          renderInfo.excludeSelections, renderInfo.renderWhich);

      if (render_to_texture_for_pp) {
        /* BEGIN rendering the selection markers, should we put all of this into
           a function, so it can be called above as well? */

#ifndef PURE_OPENGL_ES_2
        if (!must_render_stereo || postprocessOnce) {
          SceneSetPrepareViewPortForStereo(G,
              PrepareViewPortForMonoInitializeViewPort, times,
              renderInfo.mousePos, renderInfo.viewportOverride, stereo_mode,
              width_scale);
          targetImage = G->ShaderMgr->topLevelConfig;
          SceneRenderPostProcessStack(G, targetImage);
        }
#endif
        bool renderToTexture{false};
        onlySelections = true;
        SceneRenderStereoLoop(G, times, must_render_stereo, stereo_mode,
            renderToTexture, renderInfo.mousePos, renderInfo.viewportOverride,
            stereo_double_pump_mono, curState, normal, &context, width_scale,
            fog_active, onlySelections, postprocessOnce, renderInfo.excludeSelections);
      }

#ifndef PURE_OPENGL_ES_2
      if (ALWAYS_IMMEDIATE_OR(!use_shaders)) {
        glDisable(GL_FOG);
        glDisable(GL_LIGHTING);
        glDisable(GL_LIGHT0);
        glDisable(GL_LIGHT1);
        glDisable(GL_COLOR_MATERIAL);
        glDisable(GL_DITHER);
      }
#endif
    }

#ifndef PURE_OPENGL_ES_2
    if (ALWAYS_IMMEDIATE_OR(!use_shaders)) {
      glLineWidth(1.0);
      glDisable(GL_LINE_SMOOTH);
      glDisable(GL_BLEND);
      glDisable(GL_NORMALIZE);
      glDisable(GL_DEPTH_TEST);
      glDisable(GL_ALPHA_TEST);
      if (G->Option->multisample)
        glDisable(0x809D); /* GL_MULTISAMPLE_ARB */
    }
#endif
    SceneSetViewport(G, view_save);

    if (Feedback(G, FB_OpenGL, FB_Debugging))
      PyMOLCheckOpenGLErr("SceneRender final checkpoint");
  }

  PRINTFD(G, FB_Scene)
  " SceneRender: rendering complete.\n" ENDFD;

  if (!(renderInfo.pick ||
          renderInfo.sceneMultipick)) { /* update frames per second field */
    I->LastRender = UtilGetSeconds(G);
    I->ApproxRenderTime = I->LastRender - start_time;

    if (I->CopyNextFlag) {
      start_time = I->LastRender - start_time;
      if ((start_time > 0.10) || (MainSavingUnderWhileIdle()))
        if (!(ControlIdling(G)))
          if (SettingGet<bool>(G, cSetting_cache_display)) {
            if (!I->CopyType) {
              SceneCopy(G, targetImage, false, false);
            }
          }
    } else {
      I->CopyNextFlag = true;
    }
    if (renderInfo.forceCopy && !(I->CopyType)) {
      SceneCopy(G, targetImage, true, false);
      I->CopyType = 2; /* do not display force copies */
    }
  }

#ifdef _PYMOL_OPENVR
  if (stereo_mode == cStereo_openvr &&
      (!SettingGet<bool>(G, cSetting_text) ||
          SettingGet<int>(G, cSetting_openvr_gui_text) == 2)) {
    Block* scene_block = I;
    int scene_width = scene_block->rect.right - scene_block->rect.left;
    int scene_height = scene_block->rect.top - scene_block->rect.bottom;
    OpenVRSceneFinish(G, scene_block->rect.left, scene_block->rect.bottom,
        scene_width, scene_height);
  }
#endif

  PRINTFD(G, FB_Scene)
  " SceneRender: leaving...\n" ENDFD;
}

#ifndef _PYMOL_NO_AA_SHADERS
static void AppendCopyWithChangedShader(
    PyMOLGlobals* G, CGO* destCGO, CGO* srcCGO, int frommode, int tomode)
{
  CGO* cgo = CGONew(G);
  CGOAppendNoStop(cgo, srcCGO);
  CGOChangeShadersTo(cgo, frommode, tomode);
  CGOAppendNoStop(destCGO, cgo);
  CGOFreeWithoutVBOs(cgo);
}
#endif

/**
 * @brief Renders Anti-aliasing from the I->offscreen_texture texture
 * depending on the antialias_shader setting, FXAA (1 stage) or SMAA (3 stages)
 * are rendered using I->offscreen and into the screen block
 * @param fbConfig Framebuffer config (currently represents target and parent image)
 */
void SceneRenderAA(PyMOLGlobals* G, const GLFramebufferConfig& fbConfig)
{
#ifndef _PYMOL_NO_AA_SHADERS
  CScene* I = G->Scene;
  int ok = true;
  G->ShaderMgr->setDrawBuffer(fbConfig);
  if (!I->offscreenCGO) {
    CGO* unitCGO = GenerateUnitScreenCGO(G);
    ok &= unitCGO != nullptr;
    if (ok) {
      auto antialias_mode = SettingGet<int>(G, cSetting_antialias_shader);

      I->offscreenCGO = CGONew(G);

      switch (antialias_mode) {
      case 0:
        break;
      case 1: // fxaa
        AppendCopyWithChangedShader(G, I->offscreenCGO, unitCGO,
            GL_DEFAULT_SHADER_WITH_SETTINGS, GL_FXAA_SHADER);
        break;
      default:
        AppendCopyWithChangedShader(G, I->offscreenCGO, unitCGO,
            GL_DEFAULT_SHADER_WITH_SETTINGS, GL_SMAA1_SHADER);
        if (antialias_mode != 3) { // not 1nd Pass as output
          CGODisable(I->offscreenCGO, GL_SMAA1_SHADER);
          AppendCopyWithChangedShader(G, I->offscreenCGO, unitCGO,
              GL_DEFAULT_SHADER_WITH_SETTINGS, GL_SMAA2_SHADER);
          CGODisable(I->offscreenCGO, GL_SMAA2_SHADER);
          if (antialias_mode != 4) { // not 2nd Pass as output
            AppendCopyWithChangedShader(G, I->offscreenCGO, unitCGO,
                GL_DEFAULT_SHADER_WITH_SETTINGS, GL_SMAA3_SHADER);
            CGODisable(I->offscreenCGO, GL_SMAA3_SHADER);
          }
        }
        break;
      }
      CGOStop(I->offscreenCGO);
      CGOFreeWithoutVBOs(unitCGO);
      I->offscreenCGO->use_shader = true;
    } else {
      I->offscreenCGO = nullptr;
    }
  }
  if (ok && I->offscreenCGO) {
    CGORender(I->offscreenCGO, nullptr, nullptr, nullptr, nullptr, nullptr);
    // TODO: Restoring to previous state should not happen here.
    G->ShaderMgr->Disable_Current_Shader();
    glBindTexture(GL_TEXTURE_2D, 0);
    glEnable(GL_DEPTH_TEST);
    G->ShaderMgr->setDrawBuffer(fbConfig);
  }
#endif
}

static void SceneRenderAllObject(PyMOLGlobals* G, CScene* I,
    SceneUnitContext* context, RenderInfo* info, float* normal, int state,
    pymol::CObject* obj, GridInfo* grid, int* slot_vla, int fat)
{
  if (!SceneGetDrawFlag(grid, slot_vla, obj->grid_slot))
    return;

  auto use_shader = info->use_shaders;

#ifndef _WEBGL
  if (!G->Renderer)
    glLineWidth(fat ? 3.0 : 1.0);
#endif

  switch (obj->getRenderContext()) {
  case pymol::RenderContext::UnitWindow:
    // e.g. Gadgets/Ramps
    {
      auto projSave = I->projectionMatrix;

      if (grid->active) {
        context = &grid->context;
      }

      I->projectionMatrix =
          glm::ortho(context->unit_left, context->unit_right, context->unit_top,
              context->unit_bottom, context->unit_front, context->unit_back);

#ifndef PURE_OPENGL_ES_2
      if (!G->Renderer && ALWAYS_IMMEDIATE_OR(!use_shader)) {
        glPushAttrib(GL_LIGHTING_BIT);

        glMatrixMode(GL_PROJECTION);
        glLoadMatrixf(SceneGetProjectionMatrixPtr(G));

        glMatrixMode(GL_MODELVIEW);
        glPushMatrix();
        glLoadIdentity();

        float vv[4] = {0.f, 0.f, -1.f, 0.f}, dif[4] = {1.f, 1.f, 1.f, 1.f};
        glLightfv(GL_LIGHT0, GL_POSITION, vv);
        glLightfv(GL_LIGHT0, GL_DIFFUSE, dif);

        glNormal3f(0.0F, 0.0F, 1.0F);
      }
#endif

      info->state = ObjectGetCurrentState(obj, false);
      obj->render(info);

      I->projectionMatrix = projSave;

#ifndef PURE_OPENGL_ES_2
      if (!G->Renderer && ALWAYS_IMMEDIATE_OR(!use_shader)) {
        glMatrixMode(GL_PROJECTION);
        glLoadMatrixf(SceneGetProjectionMatrixPtr(G));

        glMatrixMode(GL_MODELVIEW);
        glPopMatrix();

        glPopAttrib();
      }
#endif
    }
    break;
  case pymol::RenderContext::Camera: /* context/grid 0 is all slots */
  default:
    ScenePushModelViewMatrix(G);

#ifndef PURE_OPENGL_ES_2
    if (!G->Renderer && normal && Feedback(G, FB_OpenGL, FB_Debugging))
      glNormal3fv(normal);
#endif

    if (!grid->active ||
        grid->mode == GridMode::NoGrid ||
        grid->mode == GridMode::ByObject) {
      info->state = ObjectGetCurrentState(obj, false);
      obj->render(info);
    } else if (grid->slot) {
      if (grid->mode == GridMode::ByObjectStates) {
        if ((info->state = state + grid->slot - 1) >= 0)
          obj->render(info);
      } else if (grid->mode == GridMode::ByObjectByState) {
        info->state = grid->slot - obj->grid_slot - 1;
        if (info->state >= 0 && info->state < obj->getNFrame())
          obj->render(info);
      }
    }

    ScenePopModelViewMatrix(G, !use_shader);
    break;
  }
}

/*========================================================================
 * SceneRenderAll: Renders all CObjects in the scene
 *
 * context: context info
 * normal: initial normal (for immediate mode)
 * pass: which pass (opaque, antialias, transparent)
 * fat: wide lines (i.e., for picking)
 * width_scale: specifies width_scale and sampling
 * grid: grid information
 * dynamic_pass: for specific stereo modes dynamic and clone_dynamic
 * which_objects: enum specifying which objects (NonGadgets, Gadgets, All
 * render_order: enum specifying object render order (Default, GadgetsLast)
 */
void SceneRenderAll(PyMOLGlobals* G, SceneUnitContext* context, float* normal,
    PickColorManager* pickmgr, RenderPass pass, int fat, float width_scale,
    GridInfo* grid, int dynamic_pass, SceneRenderWhich which_objects, SceneRenderOrder render_order)
{
  CScene* I = G->Scene;
  int state = SceneGetState(G);
  RenderInfo info;
#if defined(_WEBGL) && defined(PYMOL_EVAL)
  if (!OrthoEvalCheck(G))
    return;
#endif
  info.pick = pickmgr;
  info.pass = pass;
  info.vertex_scale = I->VertexScale;
  info.fog_start = I->FogStart;
  info.fog_end = I->FogEnd;
  info.front = I->m_view.m_clipSafe().m_front;
  info.use_shaders = SettingGetGlobal_b(G, cSetting_use_shaders);
  info.sampling = 1;
  info.alpha_cgo = I->AlphaCGO;
  info.ortho = SettingGetGlobal_b(G, cSetting_ortho);
  if (I->StereoMode && dynamic_pass && (!info.pick)) {
    int stereo_mode = SettingGetGlobal_i(G, cSetting_stereo_mode);
    switch (stereo_mode) {
    case cStereo_dynamic:
    case cStereo_clone_dynamic:
      info.line_lighting = true;
      break;
    }
  }

  if (I->StereoMode) {
    float buffer;
    float stAng, stShift;
    stAng = SettingGetGlobal_f(G, cSetting_stereo_angle);
    stShift = SettingGetGlobal_f(G, cSetting_stereo_shift);
    stShift = (float) (stShift * fabs(I->m_view.pos().z) / 100.0);
    stAng =
        (float) (stAng * atan(stShift / fabs(I->m_view.pos().z)) * 90.0 / cPI);
    buffer = fabs(I->Width * I->VertexScale * tan(cPI * stAng / 180.0));
    info.stereo_front = I->m_view.m_clipSafe().m_front + buffer;
  } else {
    info.stereo_front = I->m_view.m_clipSafe().m_front;
  }

  info.back = I->m_view.m_clipSafe().m_back;
  SceneGetViewNormal(G, info.view_normal);

  if (info.alpha_cgo && (pass == RenderPass::Opaque)) {
    CGOReset(info.alpha_cgo);
    auto modMatrix = SceneGetModelViewMatrixPtr(G);
    CGOSetZVector(
        info.alpha_cgo, modMatrix[2], modMatrix[6], modMatrix[10]);
  }

  if (SettingGetGlobal_b(G, cSetting_dynamic_width)) {
    info.dynamic_width = true;
    info.dynamic_width_factor =
        SettingGetGlobal_f(G, cSetting_dynamic_width_factor);
    info.dynamic_width_min = SettingGetGlobal_f(G, cSetting_dynamic_width_min);
    info.dynamic_width_max = SettingGetGlobal_f(G, cSetting_dynamic_width_max);
  }

  if (width_scale != 0.0F) {
    info.width_scale_flag = true;
    info.width_scale = width_scale;
    info.sampling = (int) info.width_scale;
    if (info.sampling < 1)
      info.sampling = 1;
  }
  {
    auto slot_vla = I->m_slots.data();
    auto which_objects_int =
        std::underlying_type_t<SceneRenderWhich>(which_objects);
    auto disregard_gizmo = !static_cast<bool>(
        which_objects_int &
        std::underlying_type_t<SceneRenderWhich>(SceneRenderWhich::Gizmos));
    if (which_objects == SceneRenderWhich::All) {
      switch (render_order) {
      case SceneRenderOrder::Arbitrary:
        for (auto obj : I->Obj) {
          /* EXPERIMENTAL RAY-VOLUME COMPOSITION CODE */
          if (obj->type == cObjectGizmo && disregard_gizmo) {
            continue;
          }
          if (!rayVolume || obj->type == cObjectVolume) {
            SceneRenderAllObject(
                G, I, context, &info, normal, state, obj, grid, slot_vla, fat);
          }
        }
        break;
      case SceneRenderOrder::GadgetsLast:
        for (auto obj : I->NonGadgetObjs) {
          /* EXPERIMENTAL RAY-VOLUME COMPOSITION CODE */
          if (!rayVolume || obj->type == cObjectVolume) {
            SceneRenderAllObject(
                G, I, context, &info, normal, state, obj, grid, slot_vla, fat);
          }
        }
        for (auto obj : I->GadgetObjs) {
          if (obj->type == cObjectGizmo && disregard_gizmo) {
            continue;
          }
          SceneRenderAllObject(
              G, I, context, &info, normal, state, obj, grid, slot_vla, fat);
        }
        break;
      } // end render order for all objects
    } else if (which_objects == SceneRenderWhich::GizmosAndGadgets) {
      for (auto obj : I->GadgetObjs) {
        if (obj->type == cObjectGizmo && disregard_gizmo) {
          continue;
        }
        // Temporarily switch renderpass as opaque in order for Gizmos to not be
        // rendered with t_mode3 shader derivatives
        info.pass = RenderPass::Opaque;
        SceneRenderAllObject(
            G, I, context, &info, normal, state, obj, grid, slot_vla, fat);
        info.pass = RenderPass::Transparent;
      }
    } else if (which_objects_int & std::underlying_type_t<SceneRenderWhich>(
                                       SceneRenderWhich::NonGadgets)) {
      for (auto obj : I->NonGadgetObjs) {
        SceneRenderAllObject(
            G, I, context, &info, normal, state, obj, grid, slot_vla, fat);
      }
    }
  }

  if (info.alpha_cgo) {
    CGOStop(info.alpha_cgo);
    /* this only works when all objects are rendered in the same frame of
     * reference */
    if (pass == RenderPass::Transparent) {
      CGORenderAlpha(info.alpha_cgo, &info, 0);
    }
  }
}

/*==================================================================================*/
/* DoRendering: This is the function that is responsible for looping through
   each rendering pass (opaque, then antialiased, then transparent) for each
   grid slot (only one grid slot if full screen).  It also implements
   transparency_mode 3, (weighted, blended order-independent transparency) which
   renders the opaque/antialiased passes to the offscreen texture with a depth
   texture, renders the transparent pass to the OIT offscreen texture, calls
   OIT_copy to copy the opaque to the screen (if necessary, i.e., not already
   rendering to AA texture), and then calls the OIT rendering pass that computes
   the resulting image. This function also renders only the selections
   (onlySelections) for all grids or the full screen.
 */
static void DoRendering(PyMOLGlobals* G, CScene* I, GridInfo* grid, int times,
    int curState, float* normal, SceneUnitContext* context, float width_scale,
    bool onlySelections, bool excludeSelections, SceneRenderWhich which_objects = SceneRenderWhich::All,
    SceneRenderOrder render_order = SceneRenderOrder::GadgetsLast)
{
  const RenderPass passes[] = {
      RenderPass::Opaque, RenderPass::Antialias, RenderPass::Transparent};
  bool use_shaders = (bool) SettingGetGlobal_b(G, cSetting_use_shaders);
  bool t_mode_3_os =
      use_shaders && SettingGetGlobal_i(G, cSetting_transparency_mode) == 3;
  bool t_mode_3 = !onlySelections && t_mode_3_os;
  GLint currentDrawFramebuffer;
  GLint currentReadFramebuffer;

#if !defined(PURE_OPENGL_ES_2) || defined(_WEBGL)
  if (t_mode_3) {
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &currentDrawFramebuffer);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &currentReadFramebuffer);
    // currentDrawFramebuffer: 0 - rendering to screen, need to render opaque to
    // offscreen buffer
    //                     non-0 - already rendering to AA texture, need to use
    //                     I->offscreen_depth_rb
    //                             transparent (OIT) pass
    // In the case of jymol the currentFramebuffer is not 0 so we are checking
    // against the default framebuffer
    if (currentDrawFramebuffer == G->ShaderMgr->defaultBackbuffer.framebuffer) {
      G->ShaderMgr->bindOffscreen(I->Width, I->Height, &I->grid);
      bg_grad(G);
    }
    glEnable(GL_DEPTH_TEST);
  }
#endif
  if (grid->active) { // && !offscreen)
    grid->cur_view = SceneGetViewport(G);
  }
  {
    int slot;
    bool cont = true;
    bool t_first_pass = true;
    G->ShaderMgr->stereo_draw_buffer_pass = 0;
    for (auto pass :
        passes) { /* render opaque, then antialiased, then transparent... */
      if (!cont) {
        break;
      }
#if !defined(PURE_OPENGL_ES_2) || defined(_WEBGL)
      if (t_mode_3 && pass == RenderPass::Transparent) {
        G->ShaderMgr->Disable_Current_Shader();
        int drawbuf = 1;
        if (TM3_IS_ONEBUF) {
          if (!t_first_pass) {
            G->ShaderMgr->stereo_draw_buffer_pass = 1;
          }
          drawbuf = t_first_pass ? 1 : 2;
        }
        G->ShaderMgr->bindOffscreenOIT(I->Width, I->Height, drawbuf);
        G->ShaderMgr->oit_pp->bindRT(
            drawbuf); // for transparency pass, render to OIT texture
        if (currentDrawFramebuffer == G->ShaderMgr->defaultBackbuffer.framebuffer) {
          SceneInitializeViewport(G, true);
        }
      }
#endif
      for (slot = 0; slot <= grid->last_slot; slot++) {
        if (grid->active) {
          GridSetViewport(G, grid, slot);
        } else if (slot) {
          break; // if grid is off, then just get out of loop after 1st pass
                 // (full screen)
        }
        /* render picked atoms */
        /* render the debugging CGO */
#ifdef PURE_OPENGL_ES_2
        if (!onlySelections) {
          EditorRender(G, curState);
          CGORender(G->DebugCGO, nullptr, nullptr, nullptr, nullptr, nullptr);
        }
#else
        if (!use_shaders)
          glPushMatrix(); /* 2 */
        if (!onlySelections && !t_mode_3)
          EditorRender(G, curState);
        if (!use_shaders) {
          glPopMatrix();  /* 1 */
          glPushMatrix(); /* 2 */
        }
        if (!onlySelections) {
          if (!use_shaders)
            glNormal3fv(normal);
          CGORender(G->DebugCGO, nullptr, nullptr, nullptr, nullptr, nullptr);
        }
        if (!use_shaders) {
          glPopMatrix();  /* 1 */
          glPushMatrix(); /* 2 */
        }
#endif
        /* render all objects */
        if (!onlySelections) {
#if !defined(PURE_OPENGL_ES_2) || defined(_WEBGL)
          if (t_mode_3) {
            if (pass == RenderPass::Opaque) {
              EditorRender(G, curState);
            }
            // transparency-mode == 3 render all objects for this pass
            auto nonGadgetsFilter_i =
                pymol::to_underlying(which_objects) &
                pymol::to_underlying(SceneRenderWhich::NonGadgets);
            auto nonGadgetsFilter =
                static_cast<SceneRenderWhich>(nonGadgetsFilter_i);
            SceneRenderAll(G, context, normal, NULL, pass, false, width_scale,
                grid, times, nonGadgetsFilter, SceneRenderOrder::GadgetsLast); // opaque
          } else {
#else
          {
#endif
            // transparency-mode != 3 render all objects for each pass
            for (const auto pass2 :
                passes) { /* render opaque, then antialiased, then
                             transparent... */
              auto allFilter_i = pymol::to_underlying(which_objects) &
                                 pymol::to_underlying(SceneRenderWhich::All);
              auto allFilter = static_cast<SceneRenderWhich>(allFilter_i);
              SceneRenderAll(G, context, normal, nullptr, pass2, false,
                  width_scale, grid, times, allFilter, SceneRenderOrder::GadgetsLast);
            }
            cont = false;
          }
        } else if (t_mode_3_os && pass == RenderPass::Opaque) {
          // onlySelections and t_mode_3, render only gadgets
          glEnable(GL_BLEND); // need to blend for the text onto the gadget
                              // background
          glBlendFunc_default();

          auto gadgetsFilter_i =
              pymol::to_underlying(which_objects) &
              pymol::to_underlying(SceneRenderWhich::Gadgets);
          auto gadgetsFilter = static_cast<SceneRenderWhich>(gadgetsFilter_i);
          SceneRenderAll(G, context, normal, nullptr,
              RenderPass::Transparent /* gadgets render in transp pass */,
              false, width_scale, grid, times, gadgetsFilter, SceneRenderOrder::GadgetsLast);
          glDisable(GL_BLEND);
        }
#ifdef PURE_OPENGL_ES_2
        if (!excludeSelections) {
          if (!grid->active ||
              slot > 0) { /* slot 0 is the full screen in grid mode, so don't
                             render selections */
            int s = grid->active && grid->mode == GridMode::ByObject ? slot : 0;
            ExecutiveRenderSelections(G, curState, s, grid);
          }
        }
#else
        if (!use_shaders) {
          glPopMatrix(); /* 1 */
          /* render selections */
          glPushMatrix(); /* 2 */
          glNormal3fv(normal);
        }
        if (!t_mode_3 && !excludeSelections) {
          if (!grid->active ||
              slot > 0) { /* slot 0 is the full screen in grid mode, so don't
                             render selections */
            int s = grid->active && grid->mode == GridMode::ByObject ? slot : 0;
            ExecutiveRenderSelections(G, curState, s, grid);
          }
        }
        if (!use_shaders) {
          glPopMatrix(); /* 1 */
        }
#endif
      } // end slot loop
      if (TM3_IS_ONEBUF) {
        if (t_mode_3 && pass == RenderPass::Transparent && t_first_pass) {
          pass = RenderPass::Antialias;
          t_first_pass = false;
          continue;
        }
      }
#if !defined(PURE_OPENGL_ES_2) || defined(_WEBGL)
      if (t_mode_3 && pass == RenderPass::Transparent) {
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, currentDrawFramebuffer);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, currentReadFramebuffer);
        glBindTexture(GL_TEXTURE_2D, 0);
        if (grid->active)
          GridSetViewport(G, grid, -1);
        if (currentDrawFramebuffer ==
            G->ShaderMgr
                ->defaultBackbuffer.framebuffer) { // if rendering to screen, need to
                                            // render offscreen opaque to screen
          SceneInitializeViewport(G, false);
          if (!I->offscreenOIT_CGO_copy) {
            // TODO G->ShaderMgr->Reload_Copy_Shaders();
            I->offscreenOIT_CGO_copy = GenerateUnitScreenCGO(G);
            CGOChangeShadersTo(I->offscreenOIT_CGO_copy,
                GL_DEFAULT_SHADER_WITH_SETTINGS, GL_OIT_COPY_SHADER);
            I->offscreenOIT_CGO_copy->use_shader = true;
          }
          CGORender(I->offscreenOIT_CGO_copy, nullptr, nullptr, nullptr, nullptr, nullptr);
        }
        if (!I->offscreenOIT_CGO) {
          I->offscreenOIT_CGO = GenerateUnitScreenCGO(G);
          CGOChangeShadersTo(I->offscreenOIT_CGO,
              GL_DEFAULT_SHADER_WITH_SETTINGS, GL_OIT_SHADER);
          I->offscreenOIT_CGO->use_shader = true;
        }
        CGORender(I->offscreenOIT_CGO, nullptr, nullptr, nullptr, nullptr, nullptr);

        glBlendFunc_default();

        if ((currentDrawFramebuffer == G->ShaderMgr->defaultBackbuffer.framebuffer) &&
            t_mode_3) {
          auto gadgetsFilter_i =
              pymol::to_underlying(SceneRenderWhich::GizmosAndGadgets);
          auto gadgetsFilter = static_cast<SceneRenderWhich>(gadgetsFilter_i);
          // onlySelections and t_mode_3, render only gadgets
          SceneRenderAll(G, context, normal, nullptr,
              RenderPass::Transparent /* gadgets render in transp pass */,
              false, width_scale, grid, times, gadgetsFilter,
              SceneRenderOrder::GadgetsLast);
        }

        glDisable(GL_BLEND);
        glDepthMask(GL_TRUE);

        if (!excludeSelections) {
          grid->cur_view = SceneGetViewport(G);
          for (slot = 0; slot <= grid->last_slot; slot++) {
            if (grid->active) {
              GridSetViewport(G, grid, slot);
            }
            if (!grid->active ||
                slot > 0) { /* slot 0 is the full screen in grid mode, so don't
                               render selections */
              int s =
                  grid->active && grid->mode == GridMode::ByObject ? slot : 0;
              ExecutiveRenderSelections(G, curState, s, grid);
            }
          }
        }
      } // if transparent w/ t_mode_3
#endif
    } // for grid
  } // for pass
  if (grid->active)
    GridSetViewport(G, grid, -1);
}

/*==================================================================================*/
/* SceneRenderStereoLoop: This is the function that is responsible for rendering
   all objects either in a monoscopic or stereo display.  It prepares the
   viewport, offscreen textures (if necessary), draws the background (if
   necessary) and calls DoRendering either once (for monoscopic) or twice (for
   stereo)
 */
void SceneRenderStereoLoop(PyMOLGlobals* G, int timesArg,
    int must_render_stereo, int stereo_mode, bool render_to_texture,
    const Offset2D& pos, const std::optional<Rect2D>& viewportOverride,
    int stereo_double_pump_mono, int curState, float* normal,
    SceneUnitContext* context, float width_scale, int fog_active,
    bool onlySelections, bool offscreenPrepared, bool excludeSelections,
    SceneRenderWhich which_objects)
{
  CScene* I = G->Scene;
  int times = timesArg;
  bool shouldPrepareOffscreen =
      !onlySelections && render_to_texture && !offscreenPrepared;
  bool use_shaders = (bool) SettingGetGlobal_b(G, cSetting_use_shaders);

  // only cStereo_clone_dynamic and cStereo_dynamic has times=2, otherwise
  // times=1
  while (times--) {
    if (must_render_stereo) {
      bool anaglyph = G->ShaderMgr && stereo_mode == cStereo_anaglyph;
      /* STEREO RENDERING (real or double-pumped) */
      PRINTFD(G, FB_Scene)
      " SceneRender: left hand stereo...\n" ENDFD;

      /* LEFT HAND STEREO */
      if (anaglyph) {
        G->ShaderMgr->stereo_flag = -1; // left eye
        G->ShaderMgr->stereo_blend = 0;
      }

#ifdef _PYMOL_OPENVR
      int savedWidth, savedHeight;
      if (stereo_mode == cStereo_openvr) {
        savedWidth = I->Width;
        savedHeight = I->Height;
        OpenVRGetWidthHeight(G, &I->Width, &I->Height);
      }
#endif

      SceneSetPrepareViewPortForStereo(G, PrepareViewPortForStereo, times, pos,
          viewportOverride, stereo_mode, width_scale);

      if (!shouldPrepareOffscreen) {
        PrepareViewPortForStereo(
            G, I, stereo_mode, render_to_texture, times, pos, viewportOverride);
      }
#ifndef PURE_OPENGL_ES_2
      if (use_shaders)
        glPushMatrix(); // 1
      if (shouldPrepareOffscreen) {
        G->ShaderMgr->bindOffscreen(I->Width, I->Height, &I->grid);
        bg_grad(G);
      }
#endif
      ScenePrepareMatrix(G, stereo_double_pump_mono ? 0 : 1, stereo_mode);
      DoRendering(G, I, &I->grid, times, curState, normal, context, width_scale,
          onlySelections, render_to_texture || excludeSelections, which_objects);

#ifndef PURE_OPENGL_ES_2
      if (use_shaders)
        glPopMatrix(); // 0
#endif

#ifdef _PYMOL_OPENVR
      // TODO Check if this is the correct place for this block. In openvr
      // branch, was last block in DoHandedStereo.
      if (stereo_mode == cStereo_openvr) {
        OpenVRDraw(G);
        OpenVREyeFinish(G);
      }
#endif

      PRINTFD(G, FB_Scene)
      " SceneRender: right hand stereo...\n" ENDFD;
      if (shouldPrepareOffscreen) {
        SceneRenderPostProcessStack(G, {});
      }

      /* RIGHT HAND STEREO */
      if (anaglyph) {
        G->ShaderMgr->stereo_flag = 1; // right eye
        G->ShaderMgr->stereo_blend =
            render_stereo_blend_into_full_screen(stereo_mode);
      }
      SceneSetPrepareViewPortForStereo(G, PrepareViewPortForStereo2nd, times,
          pos, viewportOverride, stereo_mode, width_scale);
      if (!shouldPrepareOffscreen) {
        PrepareViewPortForStereo2nd(
            G, I, stereo_mode, render_to_texture, times, pos, viewportOverride);
      }
#ifndef PURE_OPENGL_ES_2
      if (!use_shaders)
        glPushMatrix(); // 1
      if (shouldPrepareOffscreen) {
        G->ShaderMgr->bindOffscreen(I->Width, I->Height, &I->grid);
      }
      if (shouldPrepareOffscreen ||
          (stereo_mode == cStereo_quadbuffer && !onlySelections) // PYMOL-2342
      ) {
        bg_grad(G);
      }
#endif
      ScenePrepareMatrix(G, stereo_double_pump_mono ? 0 : 2, stereo_mode);
      glClear(GL_DEPTH_BUFFER_BIT);
      DoRendering(G, I, &I->grid, times, curState, normal, context, width_scale,
          onlySelections, render_to_texture || excludeSelections, which_objects);
      if (anaglyph) {
        G->ShaderMgr->stereo_flag = 0;
        G->ShaderMgr->stereo_blend = 0;
      }
#ifndef PURE_OPENGL_ES_2
      if (!use_shaders)
        glPopMatrix(); // 0
#endif

#ifdef _PYMOL_OPENVR
      if (stereo_mode == cStereo_openvr) {
        // TODO Check if this is the correct place for this block. In openvr
        // branch, was last block in DoHandedStereo.
        OpenVRDraw(G);
        OpenVREyeFinish(G);

        I->Width = savedWidth;
        I->Height = savedHeight;
      }
#endif

      /* restore draw buffer */
      if (shouldPrepareOffscreen) {
        SceneRenderPostProcessStack(G, {});
      }
      SetDrawBufferForStereo(G, I, stereo_mode, times, fog_active);
    } else {
      if (G->ShaderMgr) {
        G->ShaderMgr->stereo_flag = 0;
        G->ShaderMgr->stereo_blend = 0;
      }
      /* MONOSCOPING RENDERING (not double-pumped) */
      if (!I->grid.active && render_to_texture) {
        SceneSetViewport(G, 0, 0, I->Width, I->Height);
        if (!onlySelections)
          bg_grad(G);
      }
      if (Feedback(G, FB_OpenGL, FB_Debugging))
        PyMOLCheckOpenGLErr("Before mono rendering");
      SceneSetPrepareViewPortForStereo(G,
          PrepareViewPortForMonoInitializeViewPort, times, pos, viewportOverride,
          stereo_mode, width_scale);
      DoRendering(G, I, &I->grid, times, curState, normal, context, width_scale,
          onlySelections, render_to_texture || excludeSelections, which_objects);
      if (Feedback(G, FB_OpenGL, FB_Debugging))
        PyMOLCheckOpenGLErr("during mono rendering");
    }
  }
}

void PrepareViewPortForMonoInitializeViewPort(PyMOLGlobals* G, CScene* I,
    int stereo_mode, bool offscreen, int times, const Offset2D& pos,
    const std::optional<Rect2D>& viewportOverride)
{
  float width_scale;
  InitializeViewPortToScreenBlock(
      G, I, pos, viewportOverride, &stereo_mode, &width_scale);
}

void PrepareViewPortForStereo(PyMOLGlobals* G, CScene* I, int stereo_mode,
    bool offscreen, int times, const Offset2D& pos,
    const std::optional<Rect2D>& viewportOverride)
{
  PrepareViewPortForStereoImpl(G, I, stereo_mode, offscreen, times, pos,
      viewportOverride, GL_BACK_LEFT, 0);
}

void PrepareViewPortForStereo2nd(PyMOLGlobals* G, CScene* I, int stereo_mode,
    bool offscreen, int times, const Offset2D& pos,
    const std::optional<Rect2D>& viewportOverride)
{
  PrepareViewPortForStereoImpl(G, I, stereo_mode, offscreen, times, pos,
      viewportOverride, GL_BACK_RIGHT, 1);
}

void InitializeViewPortToScreenBlock(PyMOLGlobals* G, CScene* I,
    const Offset2D& pos, const std::optional<Rect2D>& viewportOverride, int* stereo_mode,
    float* width_scale)
{
  if (viewportOverride) {
    Rect2D want_view = *viewportOverride;
    want_view.offset.x += pos.x;
    want_view.offset.y += pos.y;
    SceneSetViewport(G, want_view);
    switch (*stereo_mode) {
    case cStereo_geowall:
      *stereo_mode = 0;
      break;
    }
    *width_scale = ((float) (viewportOverride->extent.width)) / I->Width;
  } else {
    SceneSetViewport(G, SceneGetRect(G));
  }
}

void SceneSetPrepareViewPortForStereo(PyMOLGlobals* G,
    PrepareViewportForStereoFuncT prepareViewportForStereo, int times,
    const Offset2D& pos, const std::optional<Rect2D>& viewportOverride,
    int stereo_mode, float width_scale)
{
  CScene* I = G->Scene;
  I->vp_prepareViewPortForStereo = prepareViewportForStereo;
  I->vp_times = times;
  I->vp_pos = pos;
  I->vp_oversize = viewportOverride;
  I->vp_stereo_mode = stereo_mode;
  I->vp_width_scale = width_scale;
}

/* PrepareViewPortForStereoImpl : sets up viewport and GL state for stereo_modes
 */
void PrepareViewPortForStereoImpl(PyMOLGlobals* G, CScene* I, int stereo_mode,
    bool offscreen, int times, const Offset2D& pos,
    const std::optional<Rect2D>& viewportOverride, GLenum draw_mode,
    int position /* left=0, right=1 */)
{
  int position_inv = 1 - position;
  switch (stereo_mode) {
  case cStereo_quadbuffer: /* hardware */
    OrthoDrawBuffer(G, draw_mode);
    SceneSetViewport(G, I->rect.left, I->rect.bottom, I->Width, I->Height);
    break;
  case cStereo_crosseye: /* side by side, crosseye */
    if (offscreen) {
      SceneSetViewport(
          G, position_inv * I->Width / 2, 0, I->Width / 2, I->Height);
    } else if (viewportOverride) {
      auto viewport = *viewportOverride;
      // Determine the crossX position for cross-eye stereo
      auto crossX = position_inv * viewportOverride->extent.width / 2;
      viewport.offset.x += crossX + pos.x;
      viewport.offset.y += pos.y;
      viewport.extent.width /= 2;
      SceneSetViewport(G, viewport);
    } else {
      SceneSetViewport(G, I->rect.left + (position_inv * I->Width / 2),
          I->rect.bottom, I->Width / 2, I->Height);
    }
    break;
  case cStereo_walleye:
  case cStereo_sidebyside:
    if (offscreen) {
      SceneSetViewport(G, position * I->Width / 2, 0, I->Width / 2, I->Height);
    } else if (viewportOverride) {
      auto viewport = *viewportOverride;
      auto sbsX = position * viewport.extent.width / 2;
      viewport.offset.x += sbsX + pos.x;
      viewport.offset.y += pos.y;
      viewport.extent.width /= 2;
      SceneSetViewport(G, viewport);
    } else {
      SceneSetViewport(G, I->rect.left + (position * I->Width / 2),
          I->rect.bottom, I->Width / 2, I->Height);
    }
    break;
  case cStereo_geowall:
    if (offscreen) {
      SceneSetViewport(G, position * I->Width / 2, 0, I->Width / 2, I->Height);
    } else {
      SceneSetViewport(G, I->rect.left + (position * G->Option->winX / 2),
          I->rect.bottom, I->Width, I->Height);
    }
    break;
  case cStereo_stencil_by_row:
  case cStereo_stencil_by_column:
  case cStereo_stencil_checkerboard:
    if (I->StencilValid) {
      glStencilFunc(GL_EQUAL, position_inv, 1);
      glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
      glEnable(GL_STENCIL_TEST);
    }
    break;
  case cStereo_stencil_custom:
    break;
  case cStereo_anaglyph:
    /* glClear(GL_ACCUM_BUFFER_BIT); */

    if (TM3_IS_ONEBUF) {
      glColorMask(position_inv, position, position, true);
    } else {
      if (GLEW_VERSION_3_0 &&
          SettingGetGlobal_i(G, cSetting_transparency_mode) == 3) {
        // if GL 3.0 is available, use glColorMaski to mask only first draw
        // buffer for anaglyph in transparency_mode 3
        glColorMaski(0, position_inv, position, position, true);
      } else {
        glColorMask(position_inv, position, position, true);
      }
    }

    if (position)
      glClear(GL_DEPTH_BUFFER_BIT);
    break;
#ifndef PURE_OPENGL_ES_2
  case cStereo_clone_dynamic:
    if (position_inv) {
      glClear(GL_ACCUM_BUFFER_BIT);
      OrthoDrawBuffer(G, GL_BACK_LEFT);
      if (times) {
        float dynamic_strength =
            SettingGetGlobal_f(G, cSetting_stereo_dynamic_strength);
        float vv[4] = {0.75F, 0.75F, 0.75F, 1.0F};
        vv[0] = dynamic_strength;
        vv[1] = dynamic_strength;
        vv[2] = dynamic_strength;
        glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, vv);
        glAccum(GL_ADD, 0.5);
        glDisable(GL_FOG);
      }
    } else {
      GLenum err;
      if (times) {
        glAccum(GL_ACCUM, -0.5);
      } else {
        glAccum(GL_ACCUM, 0.5);
      }
      if ((err = glGetError())) {
        PRINTFB(G, FB_Scene, FB_Errors)
        "Stereo Error 0x%x: stereo_mode=12 clone_dynamic requires access to "
        "the accumulation buffer,\n"
        "you need to start PyMOL with the -t argument, setting back to "
        "default\n",
            err ENDFB(G);
        SettingSetGlobal_i(G, cSetting_stereo_mode, cStereo_crosseye);
        SceneSetStereo(G, 0);
        return;
      }
      glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    }
    break;
  case cStereo_dynamic:
    if (position_inv) {
      if (times) {
        float dynamic_strength =
            SettingGetGlobal_f(G, cSetting_stereo_dynamic_strength);
        float vv[4] = {0.75F, 0.75F, 0.75F, 1.0F};
        vv[0] = dynamic_strength;
        vv[1] = dynamic_strength;
        vv[2] = dynamic_strength;
        glClearAccum(0.5, 0.5, 0.5, 0.5);
        glClear(GL_ACCUM_BUFFER_BIT);
        glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, vv);
        glDisable(GL_FOG);
        SceneSetViewport(G, I->rect.left + G->Option->winX / 2, I->rect.bottom,
            I->Width, I->Height);
      } else {
        glClearAccum(0.0, 0.0, 0.0, 0.0);
        glClear(GL_ACCUM_BUFFER_BIT);
        SceneSetViewport(G, I->rect.left, I->rect.bottom, I->Width, I->Height);
      }
    } else {
      GLenum err;
      if (times) {
        glAccum(GL_ACCUM, -0.5);
      } else {
        glAccum(GL_ACCUM, 0.5);
        glEnable(GL_SCISSOR_TEST);
      }
      if ((err = glGetError())) {
        if (SettingGetGlobal_i(G, cSetting_stereo_mode) != cStereo_crosseye) {
          PRINTFB(G, FB_Scene, FB_Errors)
          "Stereo Error 0x%x: stereo_mode=11 dynamic requires access to the "
          "accumulation buffer,\n"
          "you need to start PyMOL with the -t argument, setting back to "
          "default\n",
              err ENDFB(G);
          SettingSetGlobal_i(G, cSetting_stereo_mode, cStereo_crosseye);
          SceneSetStereo(G, 0);
        }
        return;
      }
      glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
      if (!times) {
        glDisable(GL_SCISSOR_TEST);
      }
    }
    break;
#ifdef _PYMOL_OPENVR
  case cStereo_openvr:
    OpenVREyeStart(G, position);
    break;
#endif
#endif
  }
}

/* SetDrawBufferForStereo : called after 2nd/right eye rendered in stereo to
   reset GL state properly based on what was changed in
   PrepareViewPortForStereoImpl per stereo_mode
 */
void SetDrawBufferForStereo(
    PyMOLGlobals* G, CScene* I, int stereo_mode, int times, int fog_active)
{
  switch (stereo_mode) {
  case cStereo_quadbuffer:
    OrthoDrawBuffer(G, GL_BACK_LEFT); /* leave us in a stereo context
                                         (avoids problems with cards than can't
                                         handle use of mono contexts) */
    break;
  case cStereo_crosseye:
  case cStereo_walleye:
  case cStereo_sidebyside:
  case cStereo_openvr:
    OrthoDrawBuffer(G, GL_BACK);
    break;
  case cStereo_geowall:
    break;
  case cStereo_stencil_by_row:
  case cStereo_stencil_by_column:
  case cStereo_stencil_checkerboard:
    glDisable(GL_STENCIL_TEST);
    break;
  case cStereo_stencil_custom:
    break;
  case cStereo_anaglyph:
    glColorMask(true, true, true, true);
    break;
  case cStereo_clone_dynamic:
#ifndef PURE_OPENGL_ES_2
    glAccum(GL_ACCUM, 0.5);
#endif
    if (times) {
      float vv[4] = {0.0F, 0.0F, 0.0F, 0.0F};
#ifndef PURE_OPENGL_ES_2
      glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, vv);
      if (fog_active)
        glEnable(GL_FOG);
#endif
      glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
      OrthoDrawBuffer(G, GL_BACK_RIGHT);
    }
#ifndef PURE_OPENGL_ES_2
    glAccum(GL_RETURN, 1.0);
#endif
    OrthoDrawBuffer(G, GL_BACK_LEFT);
    break;
  case cStereo_dynamic:
#ifndef PURE_OPENGL_ES_2
    glAccum(GL_ACCUM, 0.5);
#endif
    if (times) {
      float vv[4] = {0.0F, 0.0F, 0.0F, 0.0F};
#ifndef PURE_OPENGL_ES_2
      glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, vv);
      if (fog_active)
        glEnable(GL_FOG);
#endif
      glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    }
#ifndef PURE_OPENGL_ES_2
    glAccum(GL_RETURN, 1.0);
#endif
    if (times) {
      SceneSetViewport(
          G, I->rect.left, I->rect.bottom, I->Width + 2, I->Height + 2);
      glScissor(
          I->rect.left - 1, I->rect.bottom - 1, I->Width + 2, I->Height + 2);
      glEnable(GL_SCISSOR_TEST);
      glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
      glDisable(GL_SCISSOR_TEST);
    } else {
      glDisable(GL_SCISSOR_TEST);
    }
    break;
  }
}

void SceneInitializeViewport(PyMOLGlobals* G, bool offscreen)
{
  CScene* I = G->Scene;
  if (offscreen)
    SceneSetViewport(G, 0, 0, I->Width, I->Height);
  else {
    if (I->vp_prepareViewPortForStereo) {
      GLint currentFrameBuffer;
      glGetIntegerv(GL_FRAMEBUFFER_BINDING, &currentFrameBuffer);
      if (currentFrameBuffer ==
          G->ShaderMgr->defaultBackbuffer.framebuffer) { // if writing to screen, then
                                                  // set viewport to screen
        float width_scale;
        // this is called before preparing view port, since the prepare function
        // doesn't setup/change the viewport in all modes
        InitializeViewPortToScreenBlock(
            G, I, I->vp_pos, I->vp_oversize, &I->vp_stereo_mode, &width_scale);
      }
      I->vp_prepareViewPortForStereo(
          G, I, I->vp_stereo_mode, 0, I->vp_times, I->vp_pos, I->vp_oversize);
    } else {
      PRINTFB(G, FB_Scene, FB_Errors)
      " SceneInitializeViewport: I->vp_prepareViewPortForStereo=nullptr\n" ENDFB(
          G);
    }
  }
}

void SceneDrawStencilInBuffer(PyMOLGlobals* G, CScene* I, int stereo_mode)
{
  GLint viewport[4];
  glGetIntegerv(GL_VIEWPORT, viewport);

#ifndef PURE_OPENGL_ES_2
  glMatrixMode(GL_PROJECTION);
  glPushMatrix();
  glLoadIdentity();
  glOrtho(0, viewport[2], 0, viewport[3], -10.0, 10.0);
  glMatrixMode(GL_MODELVIEW);
  glPushMatrix();
  glLoadIdentity();
  glTranslatef(0.33F, 0.33F, 0.0F);

  glDisable(GL_ALPHA_TEST);
  glDisable(GL_LIGHTING);
  glDisable(GL_FOG);
  glDisable(GL_NORMALIZE);
  glDisable(GL_COLOR_MATERIAL);
  glDisable(GL_LINE_SMOOTH);
  glShadeModel(
      SettingGetGlobal_b(G, cSetting_pick_shading) ? GL_FLAT : GL_SMOOTH);
  glDisable(0x809D); /* GL_MULTISAMPLE_ARB */
#endif

  glDisable(GL_DEPTH_TEST);
  glDisable(GL_DITHER);
  glDisable(GL_BLEND);

  glDisable(GL_STENCIL_TEST);
  glClearStencil(0);
  glColorMask(false, false, false, false);
  glDepthMask(false);
  glClear(GL_STENCIL_BUFFER_BIT);

  glEnable(GL_STENCIL_TEST);
  glStencilFunc(GL_ALWAYS, 1, 1);
  glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);

#ifndef PURE_OPENGL_ES_2
  {
    int h = viewport[3], w = viewport[2];
    glLineWidth(1.0);
    switch (stereo_mode) {
    case cStereo_stencil_by_row: {
      int parity = I->StencilParity;
      ImmBatch batch;
      batch.begin(GL_LINES);
      for (int y = 0; y < h; y += 2) {
        batch.vertex2i(0, y + parity);
        batch.vertex2i(w, y + parity);
      }
      batch.end();
    } break;
    case cStereo_stencil_by_column: {
      ImmBatch batch;
      batch.begin(GL_LINES);
      for (int x = 0; x < w; x += 2) {
        batch.vertex2i(x, 0);
        batch.vertex2i(x, h);
      }
      batch.end();
    } break;
    case cStereo_stencil_checkerboard: {
      int m = 2 * ((h > w) ? h : w);
      ImmBatch batch;
      batch.begin(GL_LINES);
      for (int i = 0; i < m; i += 2) {
        batch.vertex2i(i, 0);
        batch.vertex2i(0, i);
      }
      batch.end();
    } break;
    }
  }
#endif

  glColorMask(true, true, true, true);
  glDepthMask(true);

#ifndef PURE_OPENGL_ES_2
  glMatrixMode(GL_MODELVIEW);
  glPopMatrix();
  glMatrixMode(GL_PROJECTION);
  glPopMatrix();
#endif
}

CGO* GenerateUnitScreenCGO(PyMOLGlobals* G)
{
  CGO cgo(G);
  CGOBegin(&cgo, GL_TRIANGLE_STRIP);
  CGOVertex(&cgo, -1.f, -1.f, 0.98f);
  CGOVertex(&cgo, 1.f, -1.f, 0.98f);
  CGOVertex(&cgo, -1.f, 1.f, 0.98f);
  CGOVertex(&cgo, 1.f, 1.f, 0.98f);
  CGOEnd(&cgo);
  assert(cgo.has_begin_end);
  return CGOOptimizeToVBONotIndexed(&cgo, 0);
}

/**
 * @return true if offscreen texture is requested for post-processing
 * @note For now, only antialiasing is the only postprocessing effect
 */
static bool NeedsOffscreenTextureForPP(PyMOLGlobals* G)
{
  return SettingGet<int>(G, cSetting_antialias_shader) != 0;
}

/**
 * @brief Renders the post processing stages
 * @param parentImage the parent framebuffer to render to at the end
 */
static void SceneRenderPostProcessStack(PyMOLGlobals* G, const GLFramebufferConfig& parentImage)
{
  /**
   * TODO: Postprocess rendering will eventually reside here.
   * For now we'll keep this generalized rendering function to
   * decouple antialiasing logic from framebuffer management.
   */
  SceneRenderAA(G, parentImage);
}

// Build the directional key light's view*projection in EYE space, so the post
// pass can reuse its existing eye-space position reconstruction (no camera
// inverse needed). The light dir matches the shading key light (eye-space
// normalize(0.4,0.4,1)). We look down -Ldir at the scene center (transformed to
// eye space by the camera modelview), with an orthographic frustum sized to the
// scene radius. Loaded as the renderer's PROJECTION while MODELVIEW stays the
// camera modelview, so vbo_vertex's projection*(modelview*model) yields light
// clip for model-space vertices.
static glm::mat4 SceneBuildLightViewProjEye(PyMOLGlobals* G)
{
  float mn[3], mx[3];
  glm::vec3 centerEye(0.0f);
  float radius = 10.0f;
  // Size the frustum to the non-solvent geometry: scattered crystallographic
  // waters would otherwise inflate the box, coarsening shadow-map depth
  // precision (→ slab self-shadow) and resolution. Fall back to all atoms.
  bool gotExtent = ExecutiveGetExtent(G, "not solvent", mn, mx, true, -1, false);
  if (!gotExtent)
    gotExtent = ExecutiveGetExtent(G, "all", mn, mx, true, -1, false);
  if (gotExtent) {
    glm::vec3 cw(
        (mn[0] + mx[0]) * 0.5f, (mn[1] + mx[1]) * 0.5f, (mn[2] + mx[2]) * 0.5f);
    glm::vec3 dw(mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2]);
    radius = 0.5f * glm::length(dw) * 1.2f; // 1.2x safety margin
    glm::mat4 mv = glm::make_mat4(SceneGetModelViewMatrixPtr(G)); // world->eye
    centerEye = glm::vec3(mv * glm::vec4(cw, 1.0f));
  }
  if (radius < 1.0f)
    radius = 1.0f;
  glm::vec3 Ldir = glm::normalize(glm::vec3(0.4f, 0.4f, 1.0f)); // toward light
  glm::vec3 up = (Ldir.z * Ldir.z < 0.81f) ? glm::vec3(0, 1, 0)
                                           : glm::vec3(1, 0, 0);
  glm::vec3 lightPos = centerEye + Ldir * (radius * 2.0f);
  glm::mat4 lightView = glm::lookAt(lightPos, centerEye, up);
  glm::mat4 lightProj =
      glm::ortho(-radius, radius, -radius, radius, 0.05f, radius * 4.0f);
  return lightProj * lightView;
}

/*========================================================================
 * SceneRenderMetal: Lightweight render path for Metal backend.
 *
 * Performs the update phase (SceneUpdate builds CGOs / VBOs on CPU),
 * sets up projection + modelview matrices, loads them into the Metal
 * renderer, then iterates scene objects via SceneRenderAll.  Object
 * render() methods dispatch CGO draws through CGORenderGL which
 * already routes VBOs to RendererMetal via drawVBOViaMetal().
 *========================================================================*/

/**
 * Point the Metal renderer's viewport + scissor at grid cell `slot` within the
 * scene viewport rect `vp` (Metal top-left backing px), and set grid->slot /
 * cur_viewport_size accordingly. Cell (col,row): col runs left→right, row 0 is
 * at the TOP, matching the GL grid layout. Integer scaling on the cell
 * boundaries avoids 1-px gaps between adjacent cells. Shared by the geometry
 * pass (SceneRenderMetal) and the selection overlay (SceneRenderMetalSelections)
 * so the per-cell math lives in exactly one place.
 */
static void SceneSetMetalGridCell(
    PyMOLGlobals* G, GridInfo* grid, const Rect2D& vp, int slot)
{
  int abs_slot = slot - grid->first_slot; // 0-based
  int col = abs_slot % grid->n_col;
  int row = abs_slot / grid->n_col;
  int vpX = vp.offset.x;
  int vpY = vp.offset.y;
  int vpW = static_cast<int>(vp.extent.width);
  int vpH = static_cast<int>(vp.extent.height);
  int x0 = vpX + (col * vpW) / grid->n_col;
  int x1 = vpX + ((col + 1) * vpW) / grid->n_col;
  int y0 = vpY + (row * vpH) / grid->n_row;
  int y1 = vpY + ((row + 1) * vpH) / grid->n_row;
  int cw = x1 - x0;
  int ch = y1 - y0;
  G->Renderer->viewport(x0, y0, cw, ch);
  G->Renderer->enable(pymol::Capability::ScissorTest);
  G->Renderer->scissor(x0, y0, cw, ch);
  grid->slot = slot;
  grid->cur_viewport_size = Extent2D{
      static_cast<std::uint32_t>(cw), static_cast<std::uint32_t>(ch)};
}

void SceneRenderMetal(PyMOLGlobals* G)
{
  if (!G->Renderer)
    return;

  CScene* I = G->Scene;

  // Metal requires VBO-based CGO optimization, not immediate mode
  static bool metalConfigDone = false;
  if (!metalConfigDone) {
    SettingSetGlobal_b(G, cSetting_use_shaders, true);
    SettingSetGlobal_i(G, cSetting_internal_gui, 0);
    SettingSetGlobal_i(G, cSetting_internal_feedback, 0);
    // Default the Metal post-process FXAA on (antialias_shader defaults to 0
    // headless). metal_ssao/metal_shadows already default true in SettingInfo.
    // All three remain user-overridable via cmd.set at runtime.
    SettingSetGlobal_i(G, cSetting_antialias_shader, 1);
    // Weighted-blended OIT handles transparent ordering on the GPU, so disable
    // the CPU global triangle sort (which would defer transparent geometry to
    // a sorted AlphaCGO instead of drawing it in the Transparent pass).
    SettingSetGlobal_b(G, cSetting_transparency_global_sort, false);
    // Force re-reshape so block rects are recalculated without internal GUI
    OrthoReshape(G, G->Option->winX, G->Option->winY, true);
    metalConfigDone = true;
  }

  // Drain deferred mouse/UI actions (click, drag, release). PyMOL_Button/Drag
  // queue these via OrthoDefer; the normal GL path runs them in
  // ExecutiveDrawNow, which the Metal path bypasses. Without this, mouse
  // rotate/zoom/pan never take effect. Runs inside the ValidContext window
  // (the bridge pushes a valid context around SceneRenderMetal), matching what
  // the deferred SceneClick/SceneDrag handlers expect.
  if (!SettingGetGlobal_b(G, cSetting_suspend_deferred))
    OrthoExecDeferred(G);

  // --- Update phase (CPU only, no GL) ---
  ExecutiveUpdateSceneMembers(G);
  SceneUpdate(G, false);

  // Advance any in-progress view animation (zoom/orient/center/set_view with
  // animate, scene transitions, etc.) BEFORE deriving the matrices from
  // I->m_view below. The GL SceneRender path does this; without it the Metal
  // renderer set up animations that never ticked, so animated camera commands
  // appeared to do nothing. The MTKView renders continuously, so the animation
  // plays out across frames from here.
  SceneUpdateAnimation(G);

  // --- Matrix setup ---
  auto aspRat = SceneGetAspectRatio(G);

  // Grid layout (grid_mode): compute the cell layout BEFORE the projection so
  // the per-cell aspect ratio (aspRat *= asp_adjust) feeds both the projection
  // matrix AND the post-process params (proj[0]/[5]). This mirrors the GL
  // SceneRender path (which does the same aspRat *= grid.asp_adjust). All cells
  // share one projection — only the viewport changes per slot — because every
  // cell has identical dimensions (window / n_col x n_row).
  auto grid_mode = SettingGet<GridMode>(G, cSetting_grid_mode);
  if (grid_mode != GridMode::NoGrid) {
    int grid_size = SceneGetGridSize(G, grid_mode);
    GridUpdate(&I->grid, aspRat, grid_mode, grid_size);
    if (I->grid.active)
      aspRat *= I->grid.asp_adjust;
  } else {
    I->grid.active = false;
  }

  SceneProjectionMatrix(
      G, I->m_view.m_clipSafe().m_front, I->m_view.m_clipSafe().m_back, aspRat);
  ScenePrepareMatrix(G, 0);

  // Load matrices into the Metal renderer
  {
    const float* proj = SceneGetProjectionMatrixPtr(G);
    const float* mv = SceneGetModelViewMatrixPtr(G);

    // Matrices may still be identity if the view hasn't been initialized.
    // SceneProjectionMatrix stores in I->projectionMatrix, ScenePrepareMatrix
    // stores in I->modelViewMatrix — both called above.

    G->Renderer->matrixMode(0x1701); // GL_PROJECTION = 0x1701
    G->Renderer->loadMatrixf(proj);
    G->Renderer->matrixMode(0x1700); // GL_MODELVIEW = 0x1700
    G->Renderer->loadMatrixf(mv);

    // Push per-frame post-process params (depth-cue/fog + SSAO). Fog matches
    // SceneSetFog: FogStart/FogEnd are eye-space distances; proj[10]/[14] let
    // the post shader reconstruct linear eye depth from the depth buffer.
    float front = I->m_view.m_clipSafe().m_front;
    float back = I->m_view.m_clipSafe().m_back;
    float fog_density = SettingGetGlobal_f(G, cSetting_fog);
    float fogStart =
        (back - front) * SettingGetGlobal_f(G, cSetting_fog_start) + front;
    float fogEnd = (fog_density > R_SMALL8 && fog_density != 1.0f)
        ? fogStart + (back - fogStart) / fog_density
        : back;
    int fogEnabled =
        (SettingGetGlobal_b(G, cSetting_depth_cue) && fog_density != 0.0f) ? 1
                                                                           : 0;
    const float* bg = ColorGet(G, SettingGetGlobal_color(G, cSetting_bg_rgb));
    // Drive the Metal scene-clear from bg_rgb (the GL path uses glClearColor;
    // the Metal renderer never read the setting, so the background stayed black).
    // Applied to the next beginFrame's clear — imperceptible at 60 fps. The clear
    // ALPHA follows ray_opaque_background: 0 → transparent (the offscreen PNG
    // export preserves alpha; the live view's layer is opaque so it's unaffected).
    int opaqueBg = SettingGetGlobal_b(G, cSetting_ray_opaque_background);
    G->Renderer->clearColor(bg[0], bg[1], bg[2], opaqueBg ? 1.0f : 0.0f);
    int aoEnabled = SettingGetGlobal_b(G, cSetting_metal_ssao) ? 1 : 0;
    int shadowEnabled = SettingGetGlobal_b(G, cSetting_metal_shadows) ? 1 : 0;
    int aaEnabled = SettingGetGlobal_i(G, cSetting_antialias_shader) != 0 ? 1 : 0;
    int outlineEnabled = SettingGetGlobal_b(G, cSetting_metal_outline) ? 1 : 0;
    int rtEnabled = SettingGetGlobal_b(G, cSetting_metal_raytrace) ? 1 : 0;
    int tonemapEnabled = SettingGetGlobal_b(G, cSetting_metal_tonemap) ? 1 : 0;
    float exposure = SettingGetGlobal_f(G, cSetting_metal_exposure);
    int rtShadowEnabled = SettingGetGlobal_b(G, cSetting_metal_rt_shadows) ? 1 : 0;
    // Outline contour color (resolved from the color setting, same ColorGet
    // pattern as bg_rgb above) and thickness in px — both Scene-panel tunable.
    const float* outlineCol =
        ColorGet(G, SettingGetGlobal_color(G, cSetting_metal_outline_color));
    float outlineWidth = SettingGetGlobal_f(G, cSetting_metal_outline_width);
    int dofEnabled = SettingGetGlobal_b(G, cSetting_metal_dof) ? 1 : 0;
    float dofFocus = SettingGetGlobal_f(G, cSetting_metal_dof_focus);
    if (dofFocus <= 0.0f) {
      // Auto-focus on the center of interest (the rotation origin) rather than
      // the screen-center pixel. The origin's eye-space distance is
      // -(modelview * origin).z (mv is column-major: row 2 = mv[2,6,10,14]).
      // If this can't be resolved to a positive distance, dofFocus stays 0 and
      // the shader falls back to sampling the center-pixel depth.
      float origin[3];
      SceneOriginGet(G, origin);
      float ez = mv[2] * origin[0] + mv[6] * origin[1] + mv[10] * origin[2] + mv[14];
      if (-ez > 0.0f)
        dofFocus = -ez;
    }
    float dofRange = SettingGetGlobal_f(G, cSetting_metal_dof_range);
    int temporalAO = SettingGetGlobal_b(G, cSetting_metal_temporal_ao) ? 1 : 0;
    int upscaleEnabled = SettingGetGlobal_b(G, cSetting_metal_upscale) ? 1 : 0;
    float dofAperture = SettingGetGlobal_f(G, cSetting_metal_dof_aperture);
    G->Renderer->setPostParams(fogEnabled, fogStart, fogEnd, bg[0], bg[1],
        bg[2], aoEnabled, shadowEnabled, aaEnabled, outlineEnabled, proj[10],
        proj[14], proj[0], proj[5], rtEnabled, tonemapEnabled, exposure,
        rtShadowEnabled, outlineCol[0], outlineCol[1], outlineCol[2],
        outlineWidth, dofEnabled, dofFocus, dofRange, temporalAO,
        upscaleEnabled, dofAperture);
    // Lighting model — the Metal lit shaders read these instead of hard-coded
    // constants, so the Scene-panel lighting sliders take effect.
    G->Renderer->setLightingParams(
        SettingGetGlobal_f(G, cSetting_ambient),
        SettingGetGlobal_f(G, cSetting_direct),
        SettingGetGlobal_f(G, cSetting_reflect),
        SettingGetGlobal_f(G, cSetting_specular),
        SettingGetGlobal_f(G, cSetting_shininess),
        SettingGetGlobal_f(G, cSetting_metal_sss_wrap));
    // MSAA: 4x when metal_msaa is on, otherwise single-sample. The renderer
    // stashes this and applies it at the next setDrawable (no encoder open),
    // so toggling at runtime never mismatches an in-flight encoder.
    G->Renderer->setDesiredSampleCount(
        SettingGetGlobal_b(G, cSetting_metal_msaa) ? 4 : 1);
  }

  // --- Scene state needed by RenderInfo ---
  I->VertexScale = SceneGetScreenVertexScale(G, nullptr);

  float zAxis[4] = {0.0, 0.0, 1.0, 0.0};
  float normal[4] = {0.0, 0.0, 1.0, 0.0};
  MatrixInvTransformC44fAs33f3f(
      glm::value_ptr(I->m_view.rotMatrix()), zAxis, normal);
  copy3f(normal, I->ViewNormal);
  I->LinesNormal[0] = I->ViewNormal[0];
  I->LinesNormal[1] = I->ViewNormal[1];
  I->LinesNormal[2] = I->ViewNormal[2];

  // Renderer state
  G->Renderer->lineWidth(SettingGet<float>(G, cSetting_line_width));
  G->Renderer->enable(pymol::Capability::DepthTest);
  G->Renderer->pointSize(SettingGet<float>(G, cSetting_dot_width));

  // --- Prepare unit context for gadgets ---
  auto scene_extent = SceneGetExtent(G);
  auto context = ScenePrepareUnitContext(scene_extent);

  // Transparency alpha CGO
  if (SettingGet<bool>(G, cSetting_transparency_global_sort) &&
      SettingGet<bool>(G, cSetting_transparency_mode)) {
    if (!I->AlphaCGO)
      I->AlphaCGO = CGONew(G);
  } else {
    CGOFree(I->AlphaCGO);
  }

  // --- Shadow map pre-pass: render the opaque geometry from the light's POV
  // into the depth map, so the post pass can PCF-sample real cast shadows. The
  // light VP is loaded as PROJECTION (camera MODELVIEW kept), the renderer
  // routes draws to depth-only pipelines, then restores the scene pass. ---
  // Skipped in grid mode: the shadow map is a single global texture, so it
  // can't be made per-cell, and a shared map would leak shadows between cells
  // (an object visible only in cell B darkening an object in cell A). Grid mode
  // therefore renders unshadowed (geometry-only parity for now).
  if (!I->grid.active && SettingGetGlobal_b(G, cSetting_metal_shadows)) {
    glm::mat4 lightVP_eye = SceneBuildLightViewProjEye(G);
    const float* mvp = SceneGetModelViewMatrixPtr(G);
    G->Renderer->setLightViewProjEye(glm::value_ptr(lightVP_eye));
    G->Renderer->matrixMode(0x1701); // PROJECTION = light VP (eye space)
    G->Renderer->loadMatrixf(glm::value_ptr(lightVP_eye));
    G->Renderer->matrixMode(0x1700); // MODELVIEW = camera modelview
    G->Renderer->loadMatrixf(mvp);
    G->Renderer->beginShadowPass();
    SceneRenderAll(G, &context, normal, nullptr, RenderPass::Opaque, false, 0.0f,
        &I->grid, 0, SceneRenderWhich::All, SceneRenderOrder::GadgetsLast);
    G->Renderer->endShadowPass();
    // Restore the camera matrices for the normal scene pass.
    G->Renderer->matrixMode(0x1701);
    G->Renderer->loadMatrixf(SceneGetProjectionMatrixPtr(G));
    G->Renderer->matrixMode(0x1700);
    G->Renderer->loadMatrixf(mvp);
  }

  // --- Render objects: opaque first, then transparent via order-independent
  // transparency (weighted-blended). The transparent pass accumulates into the
  // OIT targets between begin/endTransparentOIT; endFrame resolves them. ---
  if (I->grid.active) {
    // Grid mode: lay each slot's object(s) out in its own viewport cell.
    // SceneRenderAll already filters objects by grid->slot (SceneGetDrawFlag),
    // so we just set grid->slot + the cell viewport/scissor per iteration and
    // replay the same passes. Scissor clips each cell so nothing bleeds across
    // borders. Post-effects (SSAO/outline/OIT-resolve/FXAA) stay global — they
    // run once over the whole frame in endFrame; minor seams at cell edges are
    // acceptable for this geometry-first parity pass.
    int vpX = 0, vpY = 0, vpW = I->Width, vpH = I->Height;
    G->Renderer->getViewportRect(vpX, vpY, vpW, vpH);
    Rect2D sceneVP{vpX, vpY, static_cast<std::uint32_t>(vpW),
        static_cast<std::uint32_t>(vpH)};
    I->grid.cur_view = sceneVP;

    for (int slot = I->grid.first_slot; slot <= I->grid.last_slot; ++slot) {
      SceneSetMetalGridCell(G, &I->grid, sceneVP, slot);
      for (auto pass : {RenderPass::Opaque, RenderPass::Antialias}) {
        SceneRenderAll(G, &context, normal, nullptr, pass, false, 0.0f,
            &I->grid, 0, SceneRenderWhich::All, SceneRenderOrder::GadgetsLast);
      }
    }
    // Transparent OIT wraps every cell: all cells accumulate into the
    // full-frame OIT targets, resolved once in endFrame.
    G->Renderer->beginTransparentOIT();
    for (int slot = I->grid.first_slot; slot <= I->grid.last_slot; ++slot) {
      SceneSetMetalGridCell(G, &I->grid, sceneVP, slot);
      SceneRenderAll(G, &context, normal, nullptr, RenderPass::Transparent,
          false, 0.0f, &I->grid, 0, SceneRenderWhich::All,
          SceneRenderOrder::GadgetsLast);
    }
    G->Renderer->endTransparentOIT();

    // Restore the full scene viewport and drop the scissor so the fullscreen
    // post chain in endFrame (OIT resolve, SSAO, outline, FXAA) covers the
    // whole frame instead of being clipped to the last cell.
    G->Renderer->disable(pymol::Capability::ScissorTest);
    G->Renderer->viewport(vpX, vpY, vpW, vpH);
    I->grid.slot = 0;
  } else {
    for (auto pass : {RenderPass::Opaque, RenderPass::Antialias}) {
      SceneRenderAll(G, &context, normal, nullptr, pass, false, 0.0f,
          &I->grid, 0, SceneRenderWhich::All, SceneRenderOrder::GadgetsLast);
    }
    G->Renderer->beginTransparentOIT();
    SceneRenderAll(G, &context, normal, nullptr, RenderPass::Transparent, false,
        0.0f, &I->grid, 0, SceneRenderWhich::All, SceneRenderOrder::GadgetsLast);
    G->Renderer->endTransparentOIT();
  }

  // --- Render selection indicators ---
  // Collect selected atom positions and draw them as pink points
  // through the Metal renderer (the GL indicator pipeline is unavailable).
  // Guard: only attempt if the renderer's encoder is still alive after
  // SceneRenderAll (which may have ended/restarted it).
  if (G->Renderer && G->Renderer->hasActiveEncoder())
    SceneRenderMetalSelections(G);
}

// Draw a batch of selection-indicator points (overlay, no depth test) at the
// given world coordinates with the active theme's selection color.
static void SceneDrawMetalSelectionPoints(
    PyMOLGlobals* G, const std::vector<float>& coords)
{
  if (coords.empty())
    return;
  int nPoints = (int)(coords.size() / 3);
  G->Renderer->disable(pymol::Capability::DepthTest);
  G->Renderer->pointSize(12.0f); // Retina: need ~2x for visible size
  G->Renderer->beginBatch(pymol::PrimitiveType::Points);
  G->Renderer->batchColor4f(G->Renderer->selColor[0], G->Renderer->selColor[1],
      G->Renderer->selColor[2], 1.0f);
  for (int i = 0; i < nPoints; i++)
    G->Renderer->batchVertex3f(coords[i * 3], coords[i * 3 + 1], coords[i * 3 + 2]);
  G->Renderer->endBatch();
  G->Renderer->enable(pymol::Capability::DepthTest);
}

void SceneRenderMetalSelections(PyMOLGlobals* G)
{
  if (!G->Renderer || !G->Renderer->isRenderReady())
    return;

  CScene* I = G->Scene;

  if (I->grid.active) {
    // Grid mode: draw each cell's selection markers inside that cell's viewport.
    // ExecutiveGetSelectionCoords filters by the current grid->slot (via
    // SceneGetDrawFlagGrid), so per slot it returns only that cell object's
    // selected atoms — projected with the same camera into the cell viewport.
    int vpX = 0, vpY = 0, vpW = I->Width, vpH = I->Height;
    G->Renderer->getViewportRect(vpX, vpY, vpW, vpH);
    Rect2D sceneVP{vpX, vpY, static_cast<std::uint32_t>(vpW),
        static_cast<std::uint32_t>(vpH)};
    for (int slot = I->grid.first_slot; slot <= I->grid.last_slot; ++slot) {
      SceneSetMetalGridCell(G, &I->grid, sceneVP, slot);
      std::vector<float> coords;
      ExecutiveGetSelectionCoords(G, coords);
      SceneDrawMetalSelectionPoints(G, coords);
    }
    G->Renderer->disable(pymol::Capability::ScissorTest);
    G->Renderer->viewport(vpX, vpY, vpW, vpH);
    I->grid.slot = 0;
    return;
  }

  std::vector<float> coords;
  ExecutiveGetSelectionCoords(G, coords);
  SceneDrawMetalSelectionPoints(G, coords);
}
