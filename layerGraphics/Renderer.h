#pragma once
#include <cstddef>
#include <cstdint>

namespace pymol {

enum class PrimitiveType {
  Points,
  Lines,
  LineStrip,
  Triangles,
  TriangleStrip,
  TriangleFan,
  Quads
};

enum class BlendFunc {
  Zero,
  One,
  SrcAlpha,
  OneMinusSrcAlpha,
  DstAlpha,
  OneMinusDstAlpha,
  SrcColor,
  OneMinusSrcColor
};

enum class DepthFunc {
  Never,
  Less,
  Equal,
  LessEqual,
  Greater,
  NotEqual,
  GreaterEqual,
  Always
};

enum class BufferTarget { Array, ElementArray };

enum class BufferUsage { StaticDraw, DynamicDraw, StreamDraw };

enum class TextureTarget { Texture1D, Texture2D, Texture3D };

enum class Capability {
  DepthTest,
  Blend,
  CullFace,
  ScissorTest,
  StencilTest,
  Lighting,
  Fog,
  LineSmooth,
  Normalize,
  ColorMaterial,
  AlphaTest,
  PolygonOffset,
  Texture2D
};

class Renderer {
public:
  virtual ~Renderer() = default;

  // Frame lifecycle
  virtual void beginFrame() = 0;
  virtual void endFrame() = 0;

  // Viewport and clear
  virtual void viewport(int x, int y, int w, int h) = 0;
  // Reports the renderer's current viewport rect (the one last set by
  // viewport()). SceneRenderMetal needs this to subdivide the scene viewport
  // into grid_mode cells. Default: report nothing (GL path reads GL_VIEWPORT
  // itself). Returns true if x/y/w/h were filled.
  virtual bool getViewportRect(int& x, int& y, int& w, int& h) const
  {
    return false;
  }
  virtual void clear(bool color, bool depth, bool stencil) = 0;
  virtual void clearColor(float r, float g, float b, float a) = 0;
  virtual void scissor(int x, int y, int w, int h) = 0;

  // State management
  virtual void enable(Capability cap) = 0;
  virtual void disable(Capability cap) = 0;
  virtual void blendFunc(BlendFunc src, BlendFunc dst) = 0;
  virtual void depthFunc(DepthFunc func) = 0;
  virtual void depthMask(bool write) = 0;
  virtual void colorMask(bool r, bool g, bool b, bool a) = 0;
  virtual void lineWidth(float w) = 0;
  virtual void pointSize(float s) = 0;

  // Drawing
  virtual void drawArrays(PrimitiveType mode, int first, int count) = 0;
  virtual void drawElements(
      PrimitiveType mode, int count, const void* indices) = 0;

  // Buffers
  virtual uint32_t createBuffer() = 0;
  virtual void deleteBuffer(uint32_t id) = 0;
  virtual void bindBuffer(BufferTarget target, uint32_t id) = 0;
  virtual void bufferData(BufferTarget target, size_t size, const void* data,
      BufferUsage usage) = 0;

  // Vertex attributes
  virtual void vertexAttribPointer(int index, int size, int type,
      bool normalized, int stride, const void* offset) = 0;
  virtual void enableVertexAttribArray(int index) = 0;
  virtual void disableVertexAttribArray(int index) = 0;

  // Shaders
  virtual void useProgram(uint32_t programId) = 0;
  virtual void setUniform1i(int location, int v) = 0;
  virtual void setUniform1f(int location, float v) = 0;
  virtual void setUniform2f(int location, float v0, float v1) = 0;
  virtual void setUniform3f(int location, float v0, float v1, float v2) = 0;
  virtual void setUniform4f(
      int location, float v0, float v1, float v2, float v3) = 0;
  virtual void setUniformMatrix4fv(int location, const float* value) = 0;
  virtual void setUniformMatrix3fv(int location, const float* value) = 0;

  // Textures
  virtual uint32_t createTexture() = 0;
  virtual void deleteTexture(uint32_t id) = 0;
  virtual void bindTexture(TextureTarget target, uint32_t id) = 0;
  virtual void activeTexture(int unit) = 0;
  virtual void texParameteri(TextureTarget target, int pname, int param) = 0;

  // Framebuffers
  virtual uint32_t createFramebuffer() = 0;
  virtual void deleteFramebuffer(uint32_t id) = 0;
  virtual void bindFramebuffer(uint32_t id) = 0;

  // Matrix stack (legacy compatibility)
  virtual void matrixMode(int mode) = 0;
  virtual void loadIdentity() = 0;
  virtual void loadMatrixf(const float* m) = 0;
  virtual void pushMatrix() = 0;
  virtual void popMatrix() = 0;
  virtual void translatef(float x, float y, float z) = 0;
  virtual void scalef(float x, float y, float z) = 0;
  virtual void multMatrixf(const float* m) = 0;

  // Immediate mode replacement
  virtual void beginBatch(PrimitiveType mode) = 0;
  virtual void batchVertex3f(float x, float y, float z) = 0;
  virtual void batchVertex3fv(const float* v) = 0;
  virtual void batchVertex2f(float x, float y) = 0;
  virtual void batchVertex2i(int x, int y) = 0;
  virtual void batchColor3f(float r, float g, float b) = 0;
  virtual void batchColor3fv(const float* c) = 0;
  virtual void batchColor4f(float r, float g, float b, float a) = 0;
  virtual void batchColor4fv(const float* c) = 0;
  virtual void batchColor4ub(
      unsigned char r, unsigned char g, unsigned char b, unsigned char a) = 0;
  virtual void batchNormal3fv(const float* n) = 0;
  virtual void endBatch() = 0;

  // Returns true when the renderer is in a state that can accept draw calls.
  // Metal: checks that the command encoder and batch pipeline are valid.
  // GL: always returns true.
  virtual bool isRenderReady() const { return true; }

  /// Returns true if the renderer has an active command encoder that can
  /// accept draw calls. On GL this is always true. On Metal, it returns
  /// false if the encoder was ended or the command buffer was committed.
  virtual bool hasActiveEncoder() const { return true; }

  // Queries
  virtual void getIntegerv(int pname, int* params) = 0;
  virtual const char* getString(int name) = 0;
  virtual int getError() = 0;

  // Misc
  virtual void flush() = 0;
  virtual void finish() = 0;
  virtual void readPixels(
      int x, int y, int w, int h, int format, int type, void* pixels) = 0;
  virtual void pixelStorei(int pname, int param) = 0;

  // VBO rendering — draws interleaved vertex data with per-attribute offsets.
  // attrOffsets: byte offsets within stride for [pos, normal, color].
  // Use -1 for missing attributes.
  // colorType: 0 = UByte4Norm, 1 = Float4
  virtual void drawVBO(PrimitiveType mode, int vertexCount,
      const void* data, size_t dataSize, size_t stride,
      int posOffset, int normalOffset, int colorOffset, int colorType,
      int interiorCap = 0) {}
  // interiorCap: 1 => this is a clipped closed SURFACE; fill the slab
  // cross-section with a flat interior color (stencil cap). Default 0.
  virtual void drawVBOIndexed(PrimitiveType mode, int indexCount,
      const void* vertexData, size_t vertexDataSize, size_t stride,
      int posOffset, int normalOffset, int colorOffset, int colorType,
      const void* indexData, size_t indexDataSize, int interiorCap = 0) {}

  // Color for interior-cap cross-sections (ray_interior_color). overrideColor=
  // true => use this rgb for caps; false => per-primitive default (atom color
  // darkened for spheres/sticks, gray for surface). Default: no-op.
  virtual void setInteriorCapColor(float r, float g, float b, bool overrideColor) {}

  // Per-representation clip planes (eye-space distances from camera) for the
  // NEXT lit-VBO draw (cartoon/surface). Lets one rep clip tighter than the
  // global slab. front<0 disables per-rep clip (use the global slab only). The
  // member persists, so callers must set it before every draw. Default: no-op.
  virtual void setRepClip(float front, float back) {}

  // Arm the surface outer-contour outline for the NEXT surface draw: enabled=true
  // stashes that draw to be outlined (coverage-boundary) after the scene; rgba is
  // the line color (alpha folds in the opaque/transparency choice), widthPx the
  // on-screen thickness. enabled=false disarms (for non-surface reps). Default no-op.
  virtual void setRepContour(bool enabled, const float* rgba, float widthPx) {}

  // Arm per-rep exemption from the screen-space SSAO (crease) pass for the NEXT
  // lit-VBO draw. exempt=true stashes that draw's geometry so its (front-most)
  // pixels are masked out of the SSAO crease/contour darkening that otherwise
  // paints lines on cartoon/ribbon silhouettes and self-folds (#79). Cast shadows
  // are unaffected. The member persists, so callers set it before every draw.
  // Default: no-op.
  virtual void setRepScreenAO(bool exempt) {}

  // RGB of the 3D selection indicator squares (SceneRenderMetalSelections).
  // Driven by the active RayMol theme's selection color; defaults to pink.
  float selColor[3] = {1.0f, 0.2f, 0.6f};
  void setSelectionColor(float r, float g, float b) {
    selColor[0] = r; selColor[1] = g; selColor[2] = b;
  }

  // VBO buffer cache — returns a cached buffer ID for the given key,
  // creating it from data if not already cached.
  virtual void invalidateVBOCache(uint64_t key) {}

  // Screen-aligned textured text quads (labels + measurement text). The
  // interleaved vertex data carries the attributes the GL label shader uses;
  // byte offsets are within `stride` (-1 = absent). The glyph atlas is an
  // RGBA8 image whose pixels already carry the baked label color; `atlasGen`
  // lets the renderer skip re-upload when unchanged. Default: no-op (GL path
  // uses its own shader; this is for renderers without the GL shader infra).
  struct LabelDrawCall {
    int vertexCount = 0;
    const void* data = nullptr;
    size_t dataSize = 0;
    size_t stride = 0;
    int worldPosOff = -1;
    int targetPosOff = -1;
    int screenOff = -1;        // attr_screenoffset (vec3)
    int texOff = -1;           // attr_texcoords (vec2)
    int screenWorldOff = -1;   // attr_screenworldoffset (vec3)
    int relModeOff = -1;       // attr_relative_mode (float)
    const unsigned char* atlasPixels = nullptr;
    int atlasW = 0;
    int atlasH = 0;
    uint64_t atlasGen = 0;
    float screenW = 1.f;
    float screenH = 1.f;
    float screenOriginVertexScale = 1.f;
    float scaleByVertexScale = 0.f;
    float labelTextureSize = 1.f;
    float front = 0.f;
    float clipRange = 1.f;
  };
  virtual void drawLabels(const LabelDrawCall&) {}

  // Sphere impostors: interleaved triangle-list VBO (6 verts/sphere, two tris
  // per screen-aligned quad) with attributes a_vertex_radius (Float4
  // center+radius), a_Color (UByte4Norm), a_rightUpFlags (corner code).
  // Offsets are byte offsets within `stride` (-1 = absent). Default: no-op.
  struct SphereImpostorDrawCall {
    int sphereCount = 0;
    const void* data = nullptr;
    size_t dataSize = 0;
    size_t stride = 0;
    int posRadiusOff = -1;   // a_vertex_radius (Float4)
    int colorOff = -1;       // a_Color (UByte4Norm)
    int rightUpOff = -1;     // a_rightUpFlags
    int rightUpIsFloat = 1;  // 1 = Float, 0 = UByte
    float sphereSizeScale = 1.0f;
    int ortho = 0;           // 1 = orthographic
    int interiorCap = 0;     // 1 = fill the slab cross-section with interior color
  };
  virtual void drawSphereImpostors(const SphereImpostorDrawCall&) {}

  // Cylinder impostors: interleaved triangle-list VBO (8 verts/cylinder box,
  // 36 indices) + a UInt32 index buffer. Ported from cylinder.vs/cylinder.fs:
  // per-pixel ray-cylinder intersection with flat/round caps and two-color
  // interpolation along the bond. Offsets are byte offsets within `stride`
  // (-1 = absent). `a_cap` is supplied as a constant (capConst), not a VBO
  // attribute, in the common case. Default: no-op.
  struct CylinderImpostorDrawCall {
    int cylinderCount = 0;
    const void* vdata = nullptr;  size_t vdataSize = 0;  size_t stride = 0;
    const void* idata = nullptr;  size_t idataSize = 0;  int indexCount = 0;
    int v1Off = -1;       // attr_vertex1 (Float3)
    int v2Off = -1;       // attr_vertex2 (Float3)
    int colorOff = -1;    // a_Color
    int color2Off = -1;   // a_Color2
    int radiusOff = -1;   // attr_radius (Float)
    int flagsOff = -1;    // attr_flags (UByte: out/up/right corner code)
    int colorIsFloat = 0; // a_Color/a_Color2 format: 1=Float4, 0=UByte4Norm
    int flagsIsFloat = 0; // attr_flags format: 1=Float, 0=UByte
    float uniRadius = 0.0f;  // uni_radius (0 => use attr_radius directly)
    float capConst = 15.0f;  // a_cap bits (default cCylShaderBothCapsRound)
    int ortho = 0;
    int noFlatCaps = 1;      // 1 => round caps (matches GL shader default)
    int interiorCap = 0;     // 1 = fill the slab cross-section with interior color
  };
  virtual void drawCylinderImpostors(const CylinderImpostorDrawCall&) {}

  // Per-frame post-process parameters (depth-cue/fog + SSAO + screen-space
  // shadows). fogStart/fogEnd are eye-space distances; projA/projB are
  // projection[10]/[14] (linear eye depth) and projX/projY are projection[0]/[5]
  // (eye-space x/y reconstruction + reprojection for the shadow march).
  // Default: no-op.
  virtual void setPostParams(int fogEnabled, float fogStart, float fogEnd,
      float bgR, float bgG, float bgB, int aoEnabled, int shadowEnabled,
      int aaEnabled, int outlineEnabled, float projA, float projB, float projX,
      float projY, int rtEnabled = 0, int tonemapEnabled = 0,
      float exposure = 1.0f, int rtShadowEnabled = 0, float outlineR = 0.0f,
      float outlineG = 0.0f, float outlineB = 0.0f, float outlineWidth = 1.4f,
      int dofEnabled = 0, float dofFocus = 0.0f, float dofRange = 14.0f,
      int temporalAO = 0, int upscaleEnabled = 0, float dofAperture = 14.0f)
  {
  }

  // PyMOL lighting model (ambient/direct/reflect/specular/shininess). Default:
  // no-op (the GL renderer reads these settings itself). The Metal renderer
  // uploads them into its lit shaders so the Scene lighting sliders take effect.
  virtual void setLightingParams(float ambient, float direct, float reflect,
      float specular, float shininess, float sssWrap = 0.0f)
  {
  }

  // MSAA sample count for the scene (opaque) pass. SceneRenderMetal calls this
  // each frame from the metal_msaa setting (4 = on, 1 = off). The renderer
  // stashes it and applies the rebuild at the next frame's setDrawable (before
  // any encoder is open), so toggling never mismatches an in-flight encoder.
  // Default: no-op (GL path unaffected).
  virtual void setDesiredSampleCount(int n) {}

  // Order-independent transparency: SceneRenderMetal calls these around the
  // RenderPass::Transparent iteration. Between them, transparent draws
  // accumulate into weighted-blended OIT targets (depth-tested vs the opaque
  // depth, no depth-write) instead of blending into the scene color; endFrame
  // resolves them over the opaque color. Default: no-op (GL path unaffected).
  virtual void beginTransparentOIT() {}
  virtual void endTransparentOIT() {}

  // Real shadow map. SceneRenderMetal sets the light's eye-space view-projection
  // via setLightViewProjEye, then replays the opaque geometry between
  // beginShadowPass/endShadowPass with the light VP loaded (matrixMode/
  // loadMatrixf); draws route to depth-only pipelines writing the light-POV
  // depth map, which the post pass PCF-samples. Default: no-op (GL unaffected).
  virtual void beginShadowPass() {}
  virtual void endShadowPass() {}
  virtual void setLightViewProjEye(const float* m) {}
  // World half-extent of the shadow ortho box, so the receiver can express its
  // self-shadow bias in Angstroms (scale-invariant) rather than a frustum
  // fraction. Default: no-op (GL unaffected).
  virtual void setShadowFrustum(float radius) {}
  // User multiplier on the self-shadow depth bias (metal_shadow_bias). Default
  // no-op (GL unaffected).
  virtual void setShadowBias(float bias) {}

  // GPU-tessellated Bezier tubes ("tube cartoon"). controlPoints is a tightly
  // packed array of cubic Bezier patches: 4 Float3 control points each
  // (P0,P1,P2,P3), dataSize bytes total. radius = tube radius; r/g/b = color.
  // Each patch is tessellated on the GPU into a smooth tube. Default: no-op.
  virtual void drawBezierTubes(const void* controlPoints, size_t dataSize,
      float radius, float r, float g, float b)
  {
  }
};

} // namespace pymol
