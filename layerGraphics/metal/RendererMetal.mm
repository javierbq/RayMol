#include "RendererMetal.h"

#import <simd/simd.h>
#include <TargetConditionals.h>
#if !TARGET_OS_SIMULATOR
#import <MetalFX/MetalFX.h>   // MTLFXSpatialScaler (metal_upscale); macOS 13 / iOS 16+
                              // — absent from the iOS Simulator SDK, so guarded.
#endif
#include <algorithm>
#include <cmath>
#include "MyPNG.h"
#include "Image.h"

// Read a Metal BGRA8 texture and write it to a PNG via PyMOL's libpng writer.
// Converts BGRA→RGBA and flips to PyMOL's bottom-up row order. Runs off the
// render thread (command-buffer completion handler) after the GPU finishes.
static void rtWriteTextureToPNG(id<MTLTexture> tex, const std::string& path)
{
  if (!tex) return;
  NSUInteger w = tex.width, h = tex.height;
  if (w == 0 || h == 0) return;
  NSUInteger bpr = w * 4;
  std::vector<uint8_t> bgra((size_t)bpr * h);
  [tex getBytes:bgra.data() bytesPerRow:bpr
     fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
  pymol::Image img((int)w, (int)h);
  uint8_t* dst = img.bits();
  for (NSUInteger y = 0; y < h; ++y) {
    const uint8_t* s = bgra.data() + (size_t)y * bpr;
    uint8_t* d = dst + (size_t)(h - 1 - y) * bpr;   // top-down -> bottom-up
    for (NSUInteger x = 0; x < w; ++x) {
      d[x * 4 + 0] = s[x * 4 + 2];   // R <- B
      d[x * 4 + 1] = s[x * 4 + 1];   // G
      d[x * 4 + 2] = s[x * 4 + 0];   // B <- R
      d[x * 4 + 3] = s[x * 4 + 3];   // A
    }
  }
  MyPNGWrite(path.c_str(), img, 0.0f, cMyPNG_FormatPNG, 1, 1.0f, 1.0f);
}

namespace pymol {

// ---------------------------------------------------------------------------
#pragma mark - Static matrix helpers
// ---------------------------------------------------------------------------

RendererMetal::Mat4 RendererMetal::identityMatrix()
{
  Mat4 m{};
  m[0] = m[5] = m[10] = m[15] = 1.0f;
  return m;
}

RendererMetal::Mat4 RendererMetal::multiplyMatrices(
    const Mat4& a, const Mat4& b)
{
  Mat4 r{};
  for (int col = 0; col < 4; ++col) {
    for (int row = 0; row < 4; ++row) {
      float sum = 0.0f;
      for (int k = 0; k < 4; ++k) {
        sum += a[k * 4 + row] * b[col * 4 + k];
      }
      r[col * 4 + row] = sum;
    }
  }
  return r;
}

RendererMetal::Mat4 RendererMetal::translationMatrix(float x, float y, float z)
{
  Mat4 m = identityMatrix();
  m[12] = x;
  m[13] = y;
  m[14] = z;
  return m;
}

RendererMetal::Mat4 RendererMetal::scaleMatrix(float x, float y, float z)
{
  Mat4 m{};
  m[0] = x;
  m[5] = y;
  m[10] = z;
  m[15] = 1.0f;
  return m;
}

// ---------------------------------------------------------------------------
#pragma mark - Metal primitive type mapping
// ---------------------------------------------------------------------------

MTLPrimitiveType RendererMetal::toMTL(PrimitiveType t)
{
  switch (t) {
  case PrimitiveType::Points: return MTLPrimitiveTypePoint;
  case PrimitiveType::Lines: return MTLPrimitiveTypeLine;
  case PrimitiveType::LineStrip: return MTLPrimitiveTypeLineStrip;
  case PrimitiveType::Triangles: return MTLPrimitiveTypeTriangle;
  case PrimitiveType::TriangleStrip: return MTLPrimitiveTypeTriangleStrip;
  case PrimitiveType::TriangleFan:
    // Metal has no triangle fan — callers should convert to triangles
    return MTLPrimitiveTypeTriangle;
  case PrimitiveType::Quads:
    // Metal has no quads — callers should convert to triangles
    return MTLPrimitiveTypeTriangle;
  }
  return MTLPrimitiveTypeTriangle;
}

// ---------------------------------------------------------------------------
#pragma mark - Metal blend factor mapping
// ---------------------------------------------------------------------------

static MTLBlendFactor toMTLBlend(BlendFunc f)
{
  switch (f) {
  case BlendFunc::Zero: return MTLBlendFactorZero;
  case BlendFunc::One: return MTLBlendFactorOne;
  case BlendFunc::SrcAlpha: return MTLBlendFactorSourceAlpha;
  case BlendFunc::OneMinusSrcAlpha: return MTLBlendFactorOneMinusSourceAlpha;
  case BlendFunc::DstAlpha: return MTLBlendFactorDestinationAlpha;
  case BlendFunc::OneMinusDstAlpha:
    return MTLBlendFactorOneMinusDestinationAlpha;
  case BlendFunc::SrcColor: return MTLBlendFactorSourceColor;
  case BlendFunc::OneMinusSrcColor: return MTLBlendFactorOneMinusSourceColor;
  }
  return MTLBlendFactorOne;
}

static MTLCompareFunction toMTLCompare(DepthFunc f)
{
  switch (f) {
  case DepthFunc::Never: return MTLCompareFunctionNever;
  case DepthFunc::Less: return MTLCompareFunctionLess;
  case DepthFunc::Equal: return MTLCompareFunctionEqual;
  case DepthFunc::LessEqual: return MTLCompareFunctionLessEqual;
  case DepthFunc::Greater: return MTLCompareFunctionGreater;
  case DepthFunc::NotEqual: return MTLCompareFunctionNotEqual;
  case DepthFunc::GreaterEqual: return MTLCompareFunctionGreaterEqual;
  case DepthFunc::Always: return MTLCompareFunctionAlways;
  }
  return MTLCompareFunctionLess;
}

// ---------------------------------------------------------------------------
#pragma mark - Constructor / Destructor
// ---------------------------------------------------------------------------

RendererMetal::RendererMetal(id<MTLDevice> device, id<MTLCommandQueue> queue)
    : _device(device)
    , _queue(queue)
    , _cmdBuffer(nil)
    , _encoder(nil)
    , _passDesc(nil)
    , _drawable(nil)
    , _currentPipeline(nil)
    , _batchPipeline(nil)
    , _vboPipelineUByte(nil)
    , _vboPipelineFloat(nil)
    , _vboVertexFunc(nil)
    , _vboFragmentFunc(nil)
    , _vboVertexUnlitFunc(nil)
    , _vboFragmentUnlitFunc(nil)
    , _vboVertexUnlitFlatFunc(nil)
    , _batchBuffer(nil)
    , _sphereImpostorPipeline(nil)
    , _cylinderImpostorPipeline(nil)
    , _depthStencilState(nil)
{
  _modelviewMatrix = identityMatrix();
  _modelviewInv = identityMatrix();
  _projectionMatrix = identityMatrix();
  std::memset(_uniformData, 0, sizeof(_uniformData));
  // Hardware ray tracing capability (M-series Apple GPUs support it). Gated so
  // metal_raytrace is a no-op on machines without it (zero regression).
  _rtSupported = device != nil && [device supportsRaytracing];

  // Create initial depth stencil state
  applyDepthStencilState();

  // Build the built-in pipelines (re-callable so setSampleCount can rebuild
  // them at a new MSAA sample count).
  buildBatchPipeline();
  buildVBOPipelines();
}

// Built-in batch pipeline (immediate-mode beginBatch/endBatch + selection
// indicators). Rebuilt by setSampleCount when the MSAA sample count changes.
void RendererMetal::buildBatchPipeline()
{
  // MRC: release the previous pipeline before rebuilding (e.g. on MSAA change).
  // On the first call (from the ctor) _batchPipeline is nil, so this is a no-op.
  [_batchPipeline release];
  _batchPipeline = nil;
  NSString* batchSrc = @R"(
#include <metal_stdlib>
using namespace metal;

struct BatchVertexIn {
  float3 position [[attribute(0)]];
  float4 color    [[attribute(1)]];
  float3 normal   [[attribute(2)]];
};

struct BatchUniforms {
  float4x4 modelview;
  float4x4 projection;
  float pointSize;
  float _pad[3];
};

struct BatchVertexOut {
  float4 position [[position]];
  float4 color;
  float pointSize [[point_size]];
};

vertex BatchVertexOut batch_vertex(
    BatchVertexIn in [[stage_in]],
    constant BatchUniforms& uniforms [[buffer(1)]])
{
  BatchVertexOut out;
  out.position = uniforms.projection * uniforms.modelview * float4(in.position, 1.0);
  out.color = in.color;
  out.pointSize = uniforms.pointSize;
  return out;
}

fragment float4 batch_fragment(BatchVertexOut in [[stage_in]])
{
  return in.color;
}
)";

  NSError* error = nil;
  id<MTLLibrary> batchLib = [_device newLibraryWithSource:batchSrc
                                                 options:nil
                                                   error:&error];
  if (batchLib) {
    id<MTLFunction> vertFunc = [batchLib newFunctionWithName:@"batch_vertex"];
    id<MTLFunction> fragFunc = [batchLib newFunctionWithName:@"batch_fragment"];

    if (vertFunc && fragFunc) {
      // Vertex descriptor matching BatchVertex { float3 pos, float4 color, float3 normal }
      MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
      // position: offset 0, float3
      vd.attributes[0].format = MTLVertexFormatFloat3;
      vd.attributes[0].offset = 0;
      vd.attributes[0].bufferIndex = 0;
      // color: offset 12, float4
      vd.attributes[1].format = MTLVertexFormatFloat4;
      vd.attributes[1].offset = 3 * sizeof(float);
      vd.attributes[1].bufferIndex = 0;
      // normal: offset 28, float3
      vd.attributes[2].format = MTLVertexFormatFloat3;
      vd.attributes[2].offset = 7 * sizeof(float);
      vd.attributes[2].bufferIndex = 0;
      // stride = sizeof(BatchVertex) = 10 floats = 40 bytes
      vd.layouts[0].stride = 10 * sizeof(float);
      vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

      MTLRenderPipelineDescriptor* psd =
          [[MTLRenderPipelineDescriptor alloc] init];
      psd.vertexFunction = vertFunc;
      psd.fragmentFunction = fragFunc;
      psd.vertexDescriptor = vd;
      psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      psd.colorAttachments[0].blendingEnabled = YES;
      psd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
      psd.colorAttachments[0].destinationRGBBlendFactor =
          MTLBlendFactorOneMinusSourceAlpha;
      psd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
      psd.colorAttachments[0].destinationAlphaBlendFactor =
          MTLBlendFactorOneMinusSourceAlpha;
      psd.rasterSampleCount = _sampleCount;
      psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

      _batchPipeline = [_device newRenderPipelineStateWithDescriptor:psd
                                                               error:&error];
      if (!_batchPipeline) {
        NSLog(@"RendererMetal: failed to create batch pipeline: %@", error);
      }
      [psd release];  // MRC: descriptor (+1) consumed by pipeline creation
    }
    // MRC: the functions (+1) and library (+1) aren't needed past pipeline build.
    [vertFunc release];
    [fragFunc release];
    [batchLib release];
  } else {
    NSLog(@"RendererMetal: failed to compile batch shader: %@", error);
  }
}

void RendererMetal::setSampleCount(NSUInteger n)
{
  if (n < 1) n = 1;
  if (n == _sampleCount) return;
  _sampleCount = n;
  // Rebuild every sample-count-dependent (opaque-pass) pipeline. OIT and
  // post-process pipelines stay single-sample. Lazy pipelines rebuild on next
  // use once nil'd; batch + VBO are rebuilt eagerly here.
  // MRC: release the +1 sample-count-dependent pipelines before discarding them.
  // Lazy ones (sphere/cylinder/bezier/label/line) rebuild on next use; the eager
  // batch/VBO pipelines are rebuilt by build*Pipelines() below.
  [_sphereImpostorPipeline release];   _sphereImpostorPipeline = nil;
  [_cylinderImpostorPipeline release]; _cylinderImpostorPipeline = nil;
  _cylinderPipelineStride = 0;
  [_bezierTubePipeline release];       _bezierTubePipeline = nil;
  [_labelPipeline release];            _labelPipeline = nil;
  [_vboLinePipeline release];          _vboLinePipeline = nil;  // lazy; rebuilt on next line draw
  // The interior-cap MARK pipeline is lazy + sample-count-dependent but is NOT
  // rebuilt by buildVBOPipelines (it's stride-keyed, built in drawVBO*). Drop it
  // so it rebuilds at the new count — otherwise its rasterSampleCount would
  // mismatch the scene pass (leak + Metal validation error on capped surfaces).
  [_capMarkPipeline release];          _capMarkPipeline = nil;  _capMarkStride = 0;
  // The layout pipeline cache is keyed by sample count; drop it so one-off
  // pipelines rebuild at the new count (release the +1s the cache owns).
  for (auto& kv : _vboPipelineCache) [kv.second release];
  _vboPipelineCache.clear();
  buildBatchPipeline();
  buildVBOPipelines();
  // Force scene-target recreation (single-sample vs multisampled) next frame.
  // MRC: release the old MS targets now; ensurePostTargets recreates them and its
  // own release of these ivars then sees nil (a safe no-op).
  [_sceneColorMS release];  _sceneColorMS = nil;
  [_sceneDepthMS release];  _sceneDepthMS = nil;
  _rtW = 0;
  _rtH = 0;
}

RendererMetal::~RendererMetal()
{
  // MRC (no ARC, no autorelease pool): every +1-owned Metal/CF object created
  // via alloc/init or a -new* method must be released here, or the entire GPU
  // resource set leaks each time the renderer is torn down (device/context loss,
  // view reinit). NOT released here: _device/_queue (plain ctor assignment, no
  // retain — owned by the Metal layer), the per-frame _cmdBuffer/_encoder/
  // _drawable (autoreleased), and _passDesc/_screenPassDesc/_currentPipeline
  // (non-owning aliases of owned objects).

  // Pooled Metal objects held by value in STL maps: clear()/erase() does NOT
  // send -release under MRC, so release each entry before clearing.
  for (auto& kv : _vboCache) [kv.second release];
  _vboCache.clear();
  for (auto& kv : _vboPipelineCache) [kv.second release];
  _vboPipelineCache.clear();
  for (auto& kv : _buffers) [kv.second release];
  _buffers.clear();
  for (auto& kv : _textures) [kv.second release];
  _textures.clear();
  for (auto& kv : _fbColorAttachments) [kv.second release];
  _fbColorAttachments.clear();
  for (auto& kv : _fbDepthAttachments) [kv.second release];
  _fbDepthAttachments.clear();

  // Offscreen scene/post/OIT/RT-AO/shadow targets + atlas + capture copy
  // (mirror the ensurePostTargets release block, which only covers resize).
  [_sceneColor release];     [_sceneDepth release];     [_postColor release];
  [_sceneColorMS release];   [_sceneDepthMS release];
  [_oitAccum release];       [_oitReveal release];
  [_rtAO release];           [_rtAOHistory release];    [_rtAOAccum release];
  [_shadowDepth release];    [_labelAtlas release];

  // Render-pass descriptors ([[MTLRenderPassDescriptor alloc] init], +1).
  [_scenePassDesc release];  [_oitPassDesc release];    [_shadowPassDesc release];

  // Pipeline states (newRenderPipelineStateWithDescriptor, +1).
  [_batchPipeline release];
  [_vboPipelineUByte release];        [_vboPipelineFloat release];
  [_sphereImpostorPipeline release];  [_cylinderImpostorPipeline release];
  [_vboOitPipelineUByte release];     [_vboOitPipelineFloat release];
  [_sphereOitPipeline release];       [_cylinderOitPipeline release];
  [_oitResolvePipeline release];
  [_vboShadowPipelineUByte release];  [_vboShadowPipelineFloat release];
  [_sphereShadowPipeline release];    [_cylinderShadowPipeline release];
  [_shadowDebugPipeline release];
  [_capMarkPipeline release];         [_capFillPipeline release];
  [_coveragePipeline release];        [_surfaceContourPipeline release];
  [_surfaceCoverageTex release];
  [_aoExemptMaskTex release];         [_aoMaskPipeline release];
  [_aoMaskDepthState release];
  [_vboLinePipeline release];         [_bezierTubePipeline release];
  [_blitPipeline release];            [_ssaoPipeline release];
  [_fxaaPipeline release];            [_outlinePipeline release];
  [_tonemapPipeline release];         [_dofPipeline release];
  [_exportAlphaPipeline release];
  [_rtAOPipeline release];            [_rtResolvePipeline release];
  [_rtAOAccumPipeline release];       [_labelPipeline release];

  // Shader functions (newFunctionWithName, +1).
  [_vboVertexFunc release];           [_vboFragmentFunc release];
  [_vboVertexUnlitFunc release];      [_vboFragmentUnlitFunc release];
  [_vboVertexUnlitFlatFunc release];
  [_vboFragmentOitFunc release];      [_vboFragmentShadowFunc release];
  [_capMarkVtxFunc release];          [_capMarkFragFunc release];
  [_capFillVtxFunc release];          [_capFillFragFunc release];
  [_lineAAVtxFunc release];           [_lineAAFragFunc release];

  // Samplers (newSamplerStateWithDescriptor, +1).
  [_postSampler release];   [_shadowSampler release];   [_labelSampler release];

  // Depth-stencil states (newDepthStencilStateWithDescriptor, +1).
  [_depthStencilState release];  [_shadowDepthState release];
  [_capMarkDSS release];         [_capFillDSS release];
  [_oitDepthState release];      [_bezierDepthState release];

  // Real-time ray-tracing buffers + acceleration structures (+1).
  [_rtProtoVerts release];       [_rtProtoIndices release];
  [_rtSphereProtoAS release];    [_rtTriProtoAS release];   [_rtInstanceAS release];
  [_bezierTessFactors release];

  // Reusable batch buffer (+1; grown via newBufferWithLength).
  [_batchBuffer release];

  // MRC: the grow-on-demand line-AA scratch buffer is owned here.
  [_lineBuffer release];
  _lineBuffer = nil;
  _lineBufferSize = 0;
  [(id)_upscaler release];   // MetalFX spatial scaler (MRC)
  _upscaler = nil;
}

// ---------------------------------------------------------------------------
#pragma mark - Drawable setup
// ---------------------------------------------------------------------------

void RendererMetal::setDrawable(
    id<CAMetalDrawable> drawable, MTLRenderPassDescriptor* passDesc)
{
  _drawable = drawable;
  _screenPassDesc = passDesc;       // the drawable target (final composite pass)
  // Apply any pending MSAA sample-count change here, before any encoder is open
  // (endFrame ended the previous one and beginFrame hasn't run yet). This
  // rebuilds the opaque pipelines + forces target recreation below, so the new
  // count is consistent for the whole upcoming frame. Early-returns if unchanged.
  setSampleCount(_desiredSampleCount);
  // Render the scene into offscreen targets sized to the drawable; the existing
  // scene-draw code keys off _passDesc, so point it at the offscreen descriptor.
  id<MTLTexture> tex = drawable.texture;
  // Reduced-resolution rendering (metal_upscale): size the scene + post-chain
  // targets at _renderScale of the drawable; the final blit upscales to the
  // native drawable. _renderScale==1 (upscale off, the default) is byte-identical.
  // Forced to native when a frame PNG capture is pending so exports stay full-res.
  _renderScale = (_upscaleEnabled && _capturePath.empty()) ? 0.667f : 1.0f;
  NSUInteger rw = (NSUInteger)lround(tex.width * _renderScale);
  NSUInteger rh = (NSUInteger)lround(tex.height * _renderScale);
  if (rw < 1) rw = 1;
  if (rh < 1) rh = 1;
  ensurePostTargets(rw, rh);
  // Remember the live render height so pixel-radius post passes (DoF/outline)
  // scale up for hi-res offscreen exports (which size _rtH directly via
  // beginOffscreen and never touch _liveRefH). On the live path this keeps
  // pixelRadiusScale()==1, so the on-screen appearance is unchanged.
  _liveRefH = rh;
  _passDesc = _scenePassDesc;
}

void RendererMetal::ensureUpscaler(NSUInteger inW, NSUInteger inH,
                                   NSUInteger outW, NSUInteger outH)
{
#if TARGET_OS_SIMULATOR
  // MetalFX is absent from the iOS Simulator SDK — force the bilinear fallback.
  _metalfxSupported = 0;
  (void)inW; (void)inH; (void)outW; (void)outH;
  return;
#else
  if (_metalfxSupported == 0)
    return;  // known-unsupported device: caller uses the bilinear fallback
  if (inW == 0 || inH == 0 || outW == 0 || outH == 0)
    return;
  if (@available(macOS 13.0, iOS 16.0, *)) {
    if (_metalfxSupported < 0)
      _metalfxSupported = [MTLFXSpatialScalerDescriptor supportsDevice:_device] ? 1 : 0;
    if (_metalfxSupported != 1)
      return;
    if (_upscaler && _upInW == inW && _upInH == inH &&
        _upOutW == outW && _upOutH == outH)
      return;  // existing scaler already matches the requested in/out sizes
    MTLFXSpatialScalerDescriptor* d = [[MTLFXSpatialScalerDescriptor alloc] init];
    d.inputWidth = inW;
    d.inputHeight = inH;
    d.outputWidth = outW;
    d.outputHeight = outH;
    // Scene color + drawable are both BGRA8Unorm (display-referred LDR), so use
    // the perceptual color mode.
    d.colorTextureFormat = _sceneColor ? _sceneColor.pixelFormat : MTLPixelFormatBGRA8Unorm;
    d.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
    d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    id<MTLFXSpatialScaler> ns = [d newSpatialScalerWithDevice:_device];  // +1 (MRC)
    [d release];
    if (ns) {
      [(id)_upscaler release];
      _upscaler = ns;  // take ownership of the +1 from new...
      _upInW = inW; _upInH = inH; _upOutW = outW; _upOutH = outH;
    } else {
      _metalfxSupported = 0;  // creation failed -> permanently fall back
    }
  } else {
    _metalfxSupported = 0;
  }
#endif  // !TARGET_OS_SIMULATOR
}

// ---------------------------------------------------------------------------
#pragma mark - Encoder management
// ---------------------------------------------------------------------------

void RendererMetal::ensureEncoder()
{
  if (_encoder) return;
  if (!_cmdBuffer || !_passDesc) return;

  // Don't create an encoder on an already-committed command buffer.
  // After endFrame() commits the buffer, its status changes from
  // MTLCommandBufferStatusNotEnqueued/Enqueued to Committed/Completed.
  MTLCommandBufferStatus status = [_cmdBuffer status];
  if (status >= MTLCommandBufferStatusCommitted) {
    return;
  }

  _encoder = [_cmdBuffer renderCommandEncoderWithDescriptor:_passDesc];
  if (!_encoder) return;

  // Restore viewport
  [_encoder setViewport:_viewport];

  // Restore scissor if enabled
  if (_scissorEnabled) {
    [_encoder setScissorRect:_scissorRect];
  }

  // Apply depth stencil state
  if (_depthStencilState) {
    [_encoder setDepthStencilState:_depthStencilState];
  }

  // Set cull mode
  [_encoder setCullMode:_cullFaceEnabled ? MTLCullModeBack : MTLCullModeNone];
}

void RendererMetal::applyDepthStencilState()
{
  if (!_depthStencilDirty) return;

  MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
  desc.depthCompareFunction =
      _depthTestEnabled ? _depthCompareFunc : MTLCompareFunctionAlways;
  desc.depthWriteEnabled = _depthWriteEnabled;
  // MRC: this runs whenever the depth mode changes (frequently — per rep, and
  // every frame from endShadowPass). Release the previous state before replacing
  // it and release the descriptor, or both leak on every call. Any state still
  // referenced by an in-flight command buffer is kept alive by Metal's own retain.
  [_depthStencilState release];
  _depthStencilState = [_device newDepthStencilStateWithDescriptor:desc];
  [desc release];
  _depthStencilDirty = false;

  if (_encoder) {
    [_encoder setDepthStencilState:_depthStencilState];
  }
}

void RendererMetal::setInteriorCapColor(float r, float g, float b, bool overrideColor)
{
  _capColor[0] = r; _capColor[1] = g; _capColor[2] = b;
  _capColorOverride = overrideColor;
}

void RendererMetal::setRepClip(float front, float back)
{
  _repClipFront = front;       // < 0 disables per-rep clip in the lit fragment
  _repClipBack = back;
}

void RendererMetal::setRepContour(bool enabled, const float* rgba, float widthPx)
{
  _repContourEnabled = enabled; // armed => the next surface draw is stashed
  if (enabled) {
    _contourColor[0] = rgba[0]; _contourColor[1] = rgba[1];
    _contourColor[2] = rgba[2]; _contourColor[3] = rgba[3];
    _contourWidth = widthPx;
  }
}

void RendererMetal::setRepScreenAO(bool exempt)
{
  _repAOExempt = exempt; // armed => the next lit-VBO draw is stashed for the mask
}

// Rasterize the stashed cartoon/ribbon draws into _aoExemptMaskTex (R8), DEPTH-
// TESTED (LessEqual, no write) against the resolved _sceneDepth so only the
// front-most cartoon pixels are marked (a cartoon pixel hidden behind a stick or
// surface fails the test, so those foreground pixels keep their AO). Reuses the
// coverage vertex/fragment (position-only, writes 1.0). Returns false (mask not
// bound; caller sets aoExemptEnabled=0) when there is nothing to exempt.
// See post_ssao_fog for how the mask gates the SSAO term (shadows are kept).
bool RendererMetal::renderAOExemptMask()
{
  if (_aoExemptDraws.empty() || !_aoExemptMaskTex || !_coverageVtxFunc ||
      !_coverageFragFunc || !_sceneDepth || !_cmdBuffer)
    return false;

  // Depth-compare state: test vs stored scene depth, never write it back.
  if (!_aoMaskDepthState) {
    MTLDepthStencilDescriptor* dsd = [[MTLDepthStencilDescriptor alloc] init];
    dsd.depthCompareFunction = MTLCompareFunctionLessEqual;
    dsd.depthWriteEnabled = NO;
    _aoMaskDepthState = [_device newDepthStencilStateWithDescriptor:dsd];
    [dsd release];
  }

  MTLRenderPassDescriptor* mpd = [MTLRenderPassDescriptor renderPassDescriptor];
  mpd.colorAttachments[0].texture = _aoExemptMaskTex;
  mpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  mpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  mpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  // Load the existing scene depth to test against; STORE it unchanged (no depth
  // write happens) so the following SSAO pass still reads valid _sceneDepth.
  mpd.depthAttachment.texture = _sceneDepth;
  mpd.depthAttachment.loadAction = MTLLoadActionLoad;
  mpd.depthAttachment.storeAction = MTLStoreActionStore;
  mpd.stencilAttachment.texture = _sceneDepth;
  mpd.stencilAttachment.loadAction = MTLLoadActionLoad;
  mpd.stencilAttachment.storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> me =
      [_cmdBuffer renderCommandEncoderWithDescriptor:mpd];
  if (_aoMaskDepthState) [me setDepthStencilState:_aoMaskDepthState];
  // Slope-scaled negative depth bias: pull the mask fragments slightly toward the
  // camera so grazing cartoon triangles at folds (whose single-sample re-raster
  // depth can exceed the MSAA-resolved scene depth by a sub-texel amount) still
  // pass the LessEqual test and get masked — otherwise an AO contour line leaks
  // through right at the fold. Slope-scaled so nearly-flat faces get almost no
  // bias (can't sneak a cartoon that's genuinely behind a stick into the mask).
  [me setDepthBias:0.0f slopeScale:-3.0f clamp:0.0f];
  [me setCullMode:MTLCullModeNone];
  for (const auto& cd : _aoExemptDraws) {
    if (!_aoMaskPipeline || _aoMaskStride != cd.stride) {
      MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
      vd.attributes[0].format = MTLVertexFormatFloat3;
      vd.attributes[0].offset = (NSUInteger)(cd.posOffset < 0 ? 0 : cd.posOffset);
      vd.attributes[0].bufferIndex = 0;
      vd.layouts[0].stride = (NSUInteger)cd.stride;
      vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
      MTLRenderPipelineDescriptor* pd2 = [[MTLRenderPipelineDescriptor alloc] init];
      pd2.vertexFunction = _coverageVtxFunc;
      pd2.fragmentFunction = _coverageFragFunc;
      pd2.vertexDescriptor = vd;
      pd2.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
      // Depth-tested against _sceneDepth (Depth32Float_Stencil8).
      pd2.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      pd2.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      pd2.rasterSampleCount = 1;
      NSError* pe = nil;
      [_aoMaskPipeline release];  // MRC: release the previous-stride pipeline
      _aoMaskPipeline = [_device newRenderPipelineStateWithDescriptor:pd2 error:&pe];
      _aoMaskStride = cd.stride;
      if (!_aoMaskPipeline)
        NSLog(@"RendererMetal: AO-exempt mask pipeline failed: %@", pe);
      [vd release]; [pd2 release];  // MRC: consumed by pipeline creation
    }
    if (!_aoMaskPipeline) continue;
    [me setRenderPipelineState:_aoMaskPipeline];
    [me setVertexBuffer:cd.vbo offset:0 atIndex:0];
    struct { float modelview[16]; float projection[16]; float pointSize; float pad[3]; } cu;
    std::memcpy(cu.modelview, cd.modelview, 64);
    std::memcpy(cu.projection, cd.projection, 64);
    cu.pointSize = 1.0f; cu.pad[0] = cu.pad[1] = cu.pad[2] = 0.0f;
    [me setVertexBytes:&cu length:sizeof(cu) atIndex:1];
    { struct { float front, back, enabled, pad; } _cl = { cd.clipFront, cd.clipBack,
        cd.clipFront >= 0.0f ? 1.0f : 0.0f, 0.0f };
      [me setFragmentBytes:&_cl length:sizeof(_cl) atIndex:1]; }
    if (cd.ibo) {
      [me drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                     indexCount:(NSUInteger)cd.count
                      indexType:MTLIndexTypeUInt32
                    indexBuffer:cd.ibo
              indexBufferOffset:0];
    } else {
      [me drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
              vertexCount:(NSUInteger)cd.count];
    }
  }
  [me endEncoding];
  return true;
}

// ---------------------------------------------------------------------------
#pragma mark - Frame lifecycle
// ---------------------------------------------------------------------------

void RendererMetal::beginFrame()
{
  // Ray tracing: (re)build the atom-sphere acceleration structure from the
  // PREVIOUS frame's accumulated geometry, BEFORE this frame's command buffer
  // exists — building (with its own cmd buffer + wait) must not happen while a
  // render command buffer is in flight (that stalls/blackouts the frame).
  // Model-space geometry is stable, so one-frame latency is invisible.
  if (_rtEnabled) ensureRayTracingAS();
  _rtSpheres.clear();  // re-accumulated during this frame's opaque pass
  _rtTris.clear();

  _cmdBuffer = [_queue commandBuffer];
  _encoder = nil;
  _oitActive = false;
  _oitHasContent = false;
  _coverageDraws.clear();  // surface outer-contour: re-stashed during this frame
  _contourActive = false;
  _aoExemptDraws.clear();  // cartoon/ribbon AO-exempt mask: re-stashed this frame

  // Configure clear values on the render pass descriptor
  if (_passDesc) {
    _passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    _passDesc.colorAttachments[0].clearColor =
        MTLClearColorMake(_clearR, _clearG, _clearB, _clearA);
    _passDesc.depthAttachment.loadAction = MTLLoadActionClear;
    _passDesc.depthAttachment.clearDepth = 1.0;
    _passDesc.stencilAttachment.loadAction = MTLLoadActionClear;
    _passDesc.stencilAttachment.clearStencil = 0;

    // Create the encoder immediately to ensure the clear executes
    _encoder = [_cmdBuffer renderCommandEncoderWithDescriptor:_passDesc];
  }
}

void RendererMetal::endFrame()
{
  if (_encoder) {
    [_encoder endEncoding];
    _encoder = nil;
  }

  // The scene was rendered to _sceneColor/_sceneDepth; run the post-process
  // chain, whose final pass writes to the drawable.
  if (_drawable && _cmdBuffer && _screenPassDesc && _sceneColor) {
    runPostChain();
    [_cmdBuffer presentDrawable:_drawable];
  } else if (_drawable && _cmdBuffer) {
    [_cmdBuffer presentDrawable:_drawable];
  }

  if (_cmdBuffer) {
    [_cmdBuffer commit];
    _cmdBuffer = nil;
  }

  _drawable = nil;
  _passDesc = nil;
  _screenPassDesc = nil;
}

// ---------------------------------------------------------------------------
#pragma mark - Hi-res offscreen render → PNG
// ---------------------------------------------------------------------------

// Size the post targets to an arbitrary W×H and point the scene pass at them.
// There is no drawable: the caller runs beginFrame / scene-draw / endOffscreen,
// and runPostChain (gated on !_offscreen) skips the drawable blit, leaving the
// post-processed color in sceneSrc for the PNG capture block to write out.
void RendererMetal::beginOffscreen(int w, int h, const std::string& path)
{
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  _offscreen = true;
  _drawable = nil;
  _screenPassDesc = nil;
  _renderScale = 1.0f;  // offscreen export always renders at full requested res
  // Force target recreation at the requested resolution, then aim the scene
  // pass + viewport at it. (ensurePostTargets early-returns if size matches.)
  ensurePostTargets((NSUInteger)w, (NSUInteger)h);
  _passDesc = _scenePassDesc;
  setLetterboxOrigin(0, 0);
  viewport(0, 0, w, h);
  requestPNGCapture(path);
}

// End the offscreen render: close the scene encoder, run the full post chain
// (which writes the PNG via the capture block), commit, and block until the
// GPU finishes so the file exists on return. Leaves _offscreen=false; the next
// live setDrawable recreates the targets at the window size.
void RendererMetal::endOffscreen()
{
  if (_encoder) {
    [_encoder endEncoding];
    _encoder = nil;
  }
  if (_cmdBuffer && _sceneColor) {
    runPostChain();
  }
  if (_cmdBuffer) {
    [_cmdBuffer commit];
    [_cmdBuffer waitUntilCompleted];  // completion handler writes the PNG
    _cmdBuffer = nil;
  }
  _offscreen = false;
  _passDesc = nil;
}

// ---------------------------------------------------------------------------
#pragma mark - Post-processing (offscreen scene target + fullscreen passes)
// ---------------------------------------------------------------------------

// Fullscreen-triangle vertex shader + post-process fragment shaders. A single
// library so all post pipelines share the vertex function.
static NSString* const kPostSrc = @R"(
#include <metal_stdlib>
using namespace metal;

struct PostVOut { float4 position [[position]]; float2 uv; };

vertex PostVOut post_vertex(uint vid [[vertex_id]]) {
  // Oversized triangle covering the screen: ids 0,1,2 -> (0,0),(2,0),(0,2).
  float2 p = float2((vid << 1) & 2, vid & 2);
  PostVOut o;
  o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
  o.uv = float2(p.x, 1.0 - p.y); // texture v=0 is top of screen
  return o;
}

fragment float4 post_blit(PostVOut in [[stage_in]],
    texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]]) {
  return src.sample(s, in.uv);
}

// Filmic tone-map + exposure. Applies an exposure multiplier then the ACES
// approximation (Narkowicz 2015), mapping scene radiance to display so bright
// specular highlights roll off smoothly instead of clipping flat, and an
// exposure < 1 tames washed-out bright backgrounds. Runs before FXAA (whose
// luma math assumes ~[0,1] display values). Milestone 1 operates on the
// existing 8-bit LDR scene color; promoting the scene chain to RGBA16Float is a
// follow-up that lets highlights exceed 1.0 before the roll-off.
struct ToneU { float exposure; float tonemap; float _p0, _p1; };
fragment float4 post_tonemap(PostVOut in [[stage_in]],
    texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]],
    constant ToneU& u [[buffer(0)]]) {
  // Exposure is an independent control: it scales scene radiance whether or not
  // filmic tone-mapping is on. With tone-map on, apply the ACES curve (which
  // rolls highlights off smoothly); with it off, just clamp the exposed color.
  float3 c = src.sample(s, in.uv).rgb * u.exposure;
  if (u.tonemap > 0.5) {
    const float a = 2.51, b = 0.03, cc = 2.43, d = 0.59, e = 0.14;
    c = (c * (a * c + b)) / (c * (cc * c + d) + e);
  }
  return float4(saturate(c), 1.0);
}

// Offscreen transparent export: keep the fully post-processed RGB but rewrite
// alpha from scene depth so the background (depth at the far plane) becomes
// transparent and geometry stays opaque. Runs only for the offscreen PNG path
// when a transparent background was requested (ray_opaque_background 0); the
// live view never uses it. Alpha is binary (no matte fringing toward bg_rgb);
// exporting at 2x and downscaling anti-aliases the cutout.
fragment float4 post_export_alpha(PostVOut in [[stage_in]],
    texture2d<float> src [[texture(0)]],
    depth2d<float> depthTex [[texture(1)]],
    texture2d<float> revealTex [[texture(2)]], sampler s [[sampler(0)]]) {
  float d = depthTex.sample(s, in.uv);
  // Opaque geometry (depth < far) stays fully opaque; the far-plane background is
  // cut out. BUT transparent reps (the molecular surface) render via weighted-
  // blended OIT and do NOT write depth, so a depth-only cutout erases them from
  // the exported alpha wherever the translucent shell overhangs the background —
  // the surface vanishes from a transparent-background PNG while showing fine in
  // the viewport (issue #22). Recover their coverage from the OIT transmittance
  // (cover = 1 - reveal, matching oit_resolve) so the surface survives the matte.
  float cover = 1.0 - revealTex.sample(s, in.uv).r;
  float a = (d < 0.99995) ? 1.0 : cover;   // far plane == cleared background
  return float4(src.sample(s, in.uv).rgb, a);
}

// Weighted-blended OIT resolve: composite accumulated transparent color over
// the (already post-processed) opaque color. reveal = Π(1-α) = transmittance.
fragment float4 oit_resolve(PostVOut in [[stage_in]],
    texture2d<float> opaqueTex [[texture(0)]],
    texture2d<float> accumTex [[texture(1)]],
    texture2d<float> revealTex [[texture(2)]],
    sampler s [[sampler(0)]]) {
  float3 opaque = opaqueTex.sample(s, in.uv).rgb;
  float reveal = revealTex.sample(s, in.uv).r;
  float4 accum = accumTex.sample(s, in.uv);
  float3 avg = accum.rgb / max(accum.a, 1e-5);
  float cover = 1.0 - reveal;            // fraction covered by transparency
  return float4(avg * cover + opaque * (1.0 - cover), 1.0);
}

// FXAA (Timothy Lottes' classic console variant) — edge-aware blur that
// smooths ALL silhouettes, including the impostor ray-cast sphere/cylinder
// edges that geometry MSAA can't touch. Operates on luma of the composited
// scene color.
static float fxaa_luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

fragment float4 post_fxaa(PostVOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
  float2 inv = 1.0 / float2(tex.get_width(), tex.get_height());
  float3 rgbM = tex.sample(smp, in.uv).rgb;
  float lumaM  = fxaa_luma(rgbM);
  float lumaNW = fxaa_luma(tex.sample(smp, in.uv + float2(-1.0, -1.0) * inv).rgb);
  float lumaNE = fxaa_luma(tex.sample(smp, in.uv + float2( 1.0, -1.0) * inv).rgb);
  float lumaSW = fxaa_luma(tex.sample(smp, in.uv + float2(-1.0,  1.0) * inv).rgb);
  float lumaSE = fxaa_luma(tex.sample(smp, in.uv + float2( 1.0,  1.0) * inv).rgb);
  float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
  float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));
  float range = lumaMax - lumaMin;
  // Skip near-flat regions (no visible edge).
  if (range < max(0.0312, lumaMax * 0.125))
    return float4(rgbM, 1.0);

  float2 dir;
  dir.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
  dir.y =  ((lumaNW + lumaSW) - (lumaNE + lumaSE));
  float dirReduce =
      max((lumaNW + lumaNE + lumaSW + lumaSE) * (0.25 * 0.125), 1.0 / 128.0);
  float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
  dir = clamp(dir * rcpDirMin, -8.0, 8.0) * inv;

  float3 rgbA = 0.5 * (tex.sample(smp, in.uv + dir * (1.0 / 3.0 - 0.5)).rgb +
                       tex.sample(smp, in.uv + dir * (2.0 / 3.0 - 0.5)).rgb);
  float3 rgbB = rgbA * 0.5 + 0.25 * (tex.sample(smp, in.uv + dir * -0.5).rgb +
                                     tex.sample(smp, in.uv + dir *  0.5).rgb);
  float lumaB = fxaa_luma(rgbB);
  if (lumaB < lumaMin || lumaB > lumaMax)
    return float4(rgbA, 1.0);
  return float4(rgbB, 1.0);
}

// SSAO (depth-difference / crease shading) + depth-cue fog, in one pass.
// Reads the scene color + scene depth, darkens creases where neighbors are
// modestly closer to the camera, then fades toward the background color with
// distance (PyMOL depth_cue). Scale-invariant: occlusion uses RELATIVE depth
// difference so it needs no per-scene world-unit tuning.
struct PostU {
  float projA;       // projection[10]
  float projB;       // projection[14]
  float fogStart;    // eye-space distance
  float fogEnd;
  float bgR, bgG, bgB;
  float fogEnabled;
  float aoEnabled;
  float aoIntensity;
  float aoRadiusPx;  // sample radius in pixels at render resolution
  float projX;       // projection[0]
  float projY;       // projection[5]
  float shadowEnabled;
  float shadowIntensity;
  float aoExemptEnabled; // >0.5: aoMaskTex marks pixels that skip the SSAO term (#79)
  float4x4 lightViewProj; // eye-space light view*proj for shadow-map sampling
};

// Linear eye distance (positive, toward the scene) from window depth [0,1].
static float post_linear_depth(float d, float projA, float projB) {
  float ndcz = 2.0 * d - 1.0;
  float ez = -projB / (ndcz + projA); // eye z (negative, in front of camera)
  return -ez;                         // distance from camera (positive)
}

// Eye-space position from a window depth at a given screen uv (the inverse of the
// perspective projection; matches the reconstruction used by the shadow/AO passes).
static float3 post_eye_pos(float2 uv, float d, float projA, float projB,
                           float projX, float projY) {
  float ez = -projB / ((2.0 * d - 1.0) + projA); // eye z (negative)
  float ndcx = 2.0 * uv.x - 1.0;
  float ndcy = 1.0 - 2.0 * uv.y;
  return float3(ndcx * (-ez) / projX, ndcy * (-ez) / projY, ez);
}

// Robust eye-space surface normal from the depth buffer. Plain
// cross(dfdx(p), dfdy(p)) uses the 2x2 quad derivative, which at a silhouette
// straddles the depth discontinuity to the background/behind geometry: the
// derivative blows up and the normal points sideways/garbage in a 1-2px band along
// EVERY silhouette. In the screen-space shadow that corrupts the light-facing
// faceGate, flipping it between ~0 and ~1 pixel-to-pixel along the aliased edge, so
// the shadow term switches on/off and reads as a serrated lighter border on helices
// and sticks. Instead, reconstruct the 4 axis-neighbours and, per axis, difference
// against the neighbour on the CONTINUOUS side (smaller window-depth step) so the
// stencil never crosses the silhouette. In the smooth interior this equals the old
// derivative; only the edge band changes.
static float3 post_eye_normal(depth2d<float> depthTex, sampler s, float2 uv,
                              float2 invres, float cd, float3 cp, float projA,
                              float projB, float projX, float projY) {
  float2 ux = float2(invres.x, 0.0);
  float2 uy = float2(0.0, invres.y);
  float dl = depthTex.sample(s, uv - ux), dr = depthTex.sample(s, uv + ux);
  float dd = depthTex.sample(s, uv - uy), du = depthTex.sample(s, uv + uy);
  float3 gx = (abs(dl - cd) < abs(dr - cd))
                  ? (cp - post_eye_pos(uv - ux, dl, projA, projB, projX, projY))
                  : (post_eye_pos(uv + ux, dr, projA, projB, projX, projY) - cp);
  float3 gy = (abs(dd - cd) < abs(du - cd))
                  ? (cp - post_eye_pos(uv - uy, dd, projA, projB, projX, projY))
                  : (post_eye_pos(uv + uy, du, projA, projB, projX, projY) - cp);
  float3 n = normalize(cross(gx, gy));
  if (n.z < 0.0) n = -n; // face toward camera
  return n;
}

fragment float4 post_ssao_fog(PostVOut in [[stage_in]],
    texture2d<float> colorTex [[texture(0)]],
    depth2d<float> depthTex [[texture(1)]],
    depth2d<float> shadowTex [[texture(2)]],
    texture2d<float> aoMaskTex [[texture(3)]],
    sampler s [[sampler(0)]],
    sampler shadowSamp [[sampler(1)]],
    constant PostU& u [[buffer(0)]]) {
  float3 color = colorTex.sample(s, in.uv).rgb;
  float d = depthTex.sample(s, in.uv);

  // Interior-cap cross-sections are drawn at a sentinel depth right at the near
  // plane (~1e-5); nothing else sits that close (it would be clipped). Treat
  // those pixels as a flat solid fill: skip AO + shadow so the cut face stays
  // clean instead of being shaded by the screen-space post passes.
  bool flatCap = (d <= 0.0015);

  // Per-rep AO exemption (#79): aoMaskTex.r == 1 on front-most cartoon/ribbon
  // pixels. The depth-step SSAO term paints dark contour lines on their
  // silhouettes/self-folds/coil-crossings, so it is SKIPPED there (surface
  // pockets keep their AO). Cast SHADOWS are NOT skipped — cartoons still receive
  // directional shadows for depth (its self-shadow gates suppress the ribbon
  // darkening itself). Dilate the mask by two texels so grazing cartoon triangles
  // at folds (whose single-sample re-raster depth can just miss the MSAA-resolved
  // scene depth) are still covered and no AO line leaks through at the fold.
  bool aoExempt = false;
  if (u.aoExemptEnabled > 0.5) {
    float2 iv = 1.0 / float2(colorTex.get_width(), colorTex.get_height());
    float m = 0.0;
    for (int dy = -2; dy <= 2; dy++)
      for (int dx = -2; dx <= 2; dx++)
        m = max(m, aoMaskTex.sample(s, in.uv + float2(float(dx), float(dy)) * iv).r);
    aoExempt = (m > 0.5);
  }

  float ao = 1.0;
  if (u.aoEnabled > 0.5 && d < 0.99999 && !flatCap && !aoExempt) {
    float zc = post_linear_depth(d, u.projA, u.projB);
    float2 invres = 1.0 / float2(colorTex.get_width(), colorTex.get_height());
    const int N = 12;
    const float TWO_PI = 6.28318530718;
    const float range = 0.06; // ignore occluders farther than 6% of center z
    float occ = 0.0;
    for (int i = 0; i < N; i++) {
      float ang = (float(i) + 0.5) * (TWO_PI / float(N));
      // vary the radius across the ring to cover the disk
      float rr = u.aoRadiusPx * (0.35 + 0.65 * float((i % 4) + 1) / 4.0);
      float2 off = float2(cos(ang), sin(ang)) * rr * invres;
      float dn = depthTex.sample(s, in.uv + off);
      if (dn >= 0.99999) continue; // background neighbor: no occlusion (no halo)
      float zn = post_linear_depth(dn, u.projA, u.projB);
      float diff = zc - zn; // > 0 when neighbor is closer to camera (occluder)
      if (diff > 0.0) {
        float rel = diff / max(zc, 1e-4);
        float w = smoothstep(0.0, 0.01, rel) *
                  (1.0 - smoothstep(range * 0.5, range, rel));
        occ += w;
      }
    }
    ao = clamp(1.0 - (occ / float(N)) * u.aoIntensity, 0.0, 1.0);
  }
  color *= ao;

  // Real shadow map: reconstruct the eye-space surface point, project it into
  // the light's clip space, and PCF-compare against the stored light-POV depth.
  // To keep shadows that "make visual sense" on cartoons, two gates suppress
  // self/adjacent shadowing (a ribbon/helix darkening itself) while preserving
  // shadows cast by clearly-separated geometry and deep surface pockets:
  //   (1) NORMAL gate — only light-facing surfaces receive shadow; faces turned
  //       away are already dark from the diffuse term, so shadowing them too
  //       just reads as nonsense double-darkening.
  //   (2) SEPARATION gate — the occluder must be meaningfully closer to the
  //       light than the receiver (a real gap), not the same/adjacent surface.
  if (u.shadowEnabled > 0.5 && d < 0.99999 && !flatCap) {
    float3 p = post_eye_pos(in.uv, d, u.projA, u.projB, u.projX, u.projY);
    // Eye-space surface normal, reconstructed robustly from the depth buffer so the
    // stencil never crosses a silhouette (see post_eye_normal). The old
    // cross(dfdx(p),dfdy(p)) produced garbage normals in a 1-2px band at every
    // silhouette, giving a noisy faceGate that read as a serrated lighter border.
    float2 invres = 1.0 / float2(colorTex.get_width(), colorTex.get_height());
    float3 nrm = post_eye_normal(depthTex, s, in.uv, invres, d, p,
                                 u.projA, u.projB, u.projX, u.projY);
    float3 Ldir = normalize(float3(0.4, 0.4, 1.0));      // key light (eye space)
    float faceGate = smoothstep(0.0, 0.35, dot(nrm, Ldir));
    float4 lc = u.lightViewProj * float4(p, 1.0);        // eye -> light clip
    if (faceGate > 0.0 && lc.w > 0.0) {
      float3 ndc = lc.xyz / lc.w;                        // light NDC, GL [-1,1]
      float2 suv = float2(0.5 * ndc.x + 0.5, 0.5 - 0.5 * ndc.y);
      float fragDepth = 0.5 + 0.5 * ndc.z;               // same 0.5+0.5 remap
      if (suv.x > 0.0 && suv.x < 1.0 && suv.y > 0.0 && suv.y < 1.0 &&
          fragDepth > 0.0 && fragDepth < 1.0) {
        // Separation threshold (light-space depth). Large enough that a thin
        // cartoon slab or an adjacent coil does NOT cast onto itself, small
        // enough that a distinctly-separated caster and deep surface pockets
        // still do. Slope term adds margin on faces grazing to the light.
        float2 dd = float2(dfdx(fragDepth), dfdy(fragDepth));
        float sep = 0.022 + 2.5 * (abs(dd.x) + abs(dd.y));
        sep = min(sep, 0.05);
        // Cartoon/ribbon receivers (aoExempt, the #79 mask) self-shadow on their
        // OWN coarse triangle mesh: the shadow map is rasterized from the same
        // low-poly cartoon tube, so the receiver's light-space depth crosses the
        // stored (faceted) caster depth per-triangle and the small default `sep`
        // lets that leak through as blocky, per-triangle self-shadow acne — the
        // "triangles under shadows". Cartoon self-shadow is unwanted anyway (see
        // the self-shadow suppression note in this pass), so on cartoon pixels
        // raise the separation to a fixed fraction of the (scale-invariant)
        // light-space depth range. This suppresses self + adjacent occlusion so
        // the ribbon is cleanly lit, while genuinely separated casters (gap >
        // kCartoonSelfShadowSep) still shadow it. Surface pixels are NOT masked,
        // so surface pockets keep the fine default sep and their AO/shadow detail.
        if (aoExempt) {
          const float kCartoonSelfShadowSep = 0.12;
          sep = max(sep, kCartoonSelfShadowSep);
        }
        float2 texel =
            1.0 / float2(shadowTex.get_width(), shadowTex.get_height());
        // 4x4 taps of hardware-bilinear depth comparison (sample_compare with a
        // LessEqual comparison sampler). Each tap is sub-texel smooth, and the
        // 1.5-texel spacing widens the penumbra so the edge reads as a soft
        // gradient rather than blocky steps at high magnification.
        float lit = 0.0;
        for (int j = -2; j <= 1; j++)
          for (int i = -2; i <= 1; i++) {
            float2 off = (float2(i, j) + 0.5) * 1.5 * texel;
            lit += shadowTex.sample_compare(shadowSamp, suv + off, fragDepth - sep);
          }
        float shadow = (1.0 - lit / 16.0) * faceGate;    // 0 lit .. 1 occluded
        color *= (1.0 - shadow * u.shadowIntensity);
      }
    }
  }

  if (u.fogEnabled > 0.5 && d < 0.99999) {
    float dist = post_linear_depth(d, u.projA, u.projB);
    float fog = clamp((u.fogEnd - dist) / max(u.fogEnd - u.fogStart, 1e-4),
                      0.0, 1.0);
    color = mix(float3(u.bgR, u.bgG, u.bgB), color, fog);
  }
  return float4(color, 1.0);
}

// Silhouette / toon outlines: depth-based Sobel edge detection. Strong depth
// discontinuities (object silhouettes + where one part occludes another) get a
// dark contour. Scale-invariant: the gradient is taken relative to the center
// linear depth. Composited over the resolved scene color.
struct OutlineU {
  float projA, projB;     // projection[10]/[14] for linear depth
  float invW, invH;       // 1/resolution
  float colR, colG, colB; // outline color
  float thickness;        // sample step in pixels
};
fragment float4 post_outline(PostVOut in [[stage_in]],
    texture2d<float> colorTex [[texture(0)]],
    depth2d<float> depthTex [[texture(1)]],
    sampler s [[sampler(0)]],
    constant OutlineU& u [[buffer(0)]]) {
  float3 color = colorTex.sample(s, in.uv).rgb;
  float dc = depthTex.sample(s, in.uv);
  float2 px = float2(u.invW, u.invH) * u.thickness;
  // 3x3 linear-depth samples
  float zc = post_linear_depth(dc, u.projA, u.projB);
  float2 o = px;
  float zl = post_linear_depth(depthTex.sample(s, in.uv + float2(-o.x, 0)), u.projA, u.projB);
  float zr = post_linear_depth(depthTex.sample(s, in.uv + float2( o.x, 0)), u.projA, u.projB);
  float zt = post_linear_depth(depthTex.sample(s, in.uv + float2(0, -o.y)), u.projA, u.projB);
  float zb = post_linear_depth(depthTex.sample(s, in.uv + float2(0,  o.y)), u.projA, u.projB);
  // gradient magnitude relative to center depth (scale-invariant)
  float gx = abs(zr - zl);
  float gy = abs(zb - zt);
  float grad = (gx + gy) / max(zc, 1e-3);
  float edge = smoothstep(0.02, 0.08, grad);
  // don't outline pure background (both center far)
  edge *= step(dc, 0.99999);
  color = mix(color, float3(u.colR, u.colG, u.colB), edge);
  return float4(color, 1.0);
}

// Surface OUTER contour: outline the boundary of the surface coverage mask
// (covTex.r = 1 where the surface covers the screen, 0 elsewhere). A pixel is on
// the contour where coverage differs from a neighbor within the line width, so
// the line traces the outer silhouette (and any interior holes) of the surface —
// independent of the surface's transparency or the depth buffer. Composited over
// the scene color.
struct ContourU {
  float invW, invH;             // 1/resolution
  float thickness;              // ring radius in pixels (~half the line width)
  float colR, colG, colB, colA; // line color; colA folds in opaque/transparency
};
fragment float4 post_surface_contour(PostVOut in [[stage_in]],
    texture2d<float> colorTex [[texture(0)]],
    texture2d<float> covTex [[texture(1)]],
    sampler s [[sampler(0)]],
    constant ContourU& u [[buffer(0)]]) {
  float3 color = colorTex.sample(s, in.uv).rgb;
  float c = covTex.sample(s, in.uv).r;
  float2 px = float2(u.invW, u.invH) * max(u.thickness, 1.0);
  float e = 0.0;
  e = max(e, abs(c - covTex.sample(s, in.uv + float2( px.x, 0)).r));
  e = max(e, abs(c - covTex.sample(s, in.uv + float2(-px.x, 0)).r));
  e = max(e, abs(c - covTex.sample(s, in.uv + float2(0,  px.y)).r));
  e = max(e, abs(c - covTex.sample(s, in.uv + float2(0, -px.y)).r));
  e = max(e, abs(c - covTex.sample(s, in.uv + float2( px.x,  px.y)).r));
  e = max(e, abs(c - covTex.sample(s, in.uv + float2(-px.x,  px.y)).r));
  e = max(e, abs(c - covTex.sample(s, in.uv + float2( px.x, -px.y)).r));
  e = max(e, abs(c - covTex.sample(s, in.uv + float2(-px.x, -px.y)).r));
  float a = clamp(e, 0.0, 1.0) * u.colA;
  color = mix(color, float3(u.colR, u.colG, u.colB), a);
  return float4(color, 1.0);
}

// Stage-1 debug: show the raw light-POV shadow depth map as grayscale (near
// dark, far/background white). Env-gated (PYMOL_SHADOW_DEBUG). Removed in S2.
fragment float4 post_shadow_debug(PostVOut in [[stage_in]],
    depth2d<float> shadowTex [[texture(1)]],
    sampler s [[sampler(0)]]) {
  float dpt = shadowTex.sample(s, in.uv);
  return float4(dpt, dpt, dpt, 1.0);
}

// Depth-of-field: circle-of-confusion blur by each pixel's distance from a focal
// plane. CoC grows with |eyeDist - focus| / range; a golden-angle disk gather of
// the composited color, depth-similarity weighted (the same exp(-|dz|/ztol) idea
// as the RT composite) so sharp foreground does not bleed onto blurred regions.
// focusDist<=0 => auto-focus on the screen-center pixel's depth.
struct DofU {
  float projA, projB;     // projection[10]/[14] for linear eye depth
  float invW, invH;       // 1/resolution
  float focusDist;        // eye-space focus distance; <=0 => auto (screen center)
  float focusRange;       // eye-space distance over which CoC ramps 0->1
  float maxRadiusPx;      // blur radius in px at CoC=1
  float _pad;
};
fragment float4 post_dof(PostVOut in [[stage_in]],
    texture2d<float> colorTex [[texture(0)]],
    depth2d<float> depthTex [[texture(1)]],
    sampler s [[sampler(0)]],
    constant DofU& u [[buffer(0)]]) {
  float3 base = colorTex.sample(s, in.uv).rgb;
  float centerEye = post_linear_depth(depthTex.sample(s, in.uv), u.projA, u.projB);
  float focus = u.focusDist > 0.0 ? u.focusDist
      : post_linear_depth(depthTex.sample(s, float2(0.5, 0.5)), u.projA, u.projB);
  float coc = clamp(abs(centerEye - focus) / max(u.focusRange, 1e-3), 0.0, 1.0);
  float radius = coc * u.maxRadiusPx;
  if (radius < 0.5) return float4(base, 1.0);
  const int N = 16;
  float3 sum = base;
  float wsum = 1.0;
  float ztol = max(0.10 * max(centerEye, focus), 0.5);
  float2 texel = float2(u.invW, u.invH);
  for (int i = 0; i < N; ++i) {
    float t = (float(i) + 0.5) / float(N);
    float ang = float(i) * 2.39996323; // golden angle
    float2 dir = float2(cos(ang), sin(ang)) * sqrt(t);
    float2 off = dir * radius * texel;
    float3 c = colorTex.sample(s, in.uv + off).rgb;
    float zs = post_linear_depth(depthTex.sample(s, in.uv + off), u.projA, u.projB);
    float w = exp(-abs(zs - centerEye) / ztol);
    sum += c * w;
    wsum += w;
  }
  return float4(sum / wsum, 1.0);
}

// Temporal AO accumulation: EMA the per-frame raw RT AO (.r) + traced shadow
// (.g) into a history buffer. reset>0.5 takes the current frame fully (the view
// or geometry changed); otherwise blends current into history by alpha. Writes
// the RG16Float accumulation target read by the RT composite pass.
struct AoAccumU { float alpha; float reset; float _p0; float _p1; };
fragment float4 post_ao_accum(PostVOut in [[stage_in]],
    texture2d<float> curTex [[texture(0)]],
    texture2d<float> histTex [[texture(1)]],
    sampler s [[sampler(0)]],
    constant AoAccumU& u [[buffer(0)]]) {
  float2 cur = curTex.sample(s, in.uv).rg;
  float2 hist = histTex.sample(s, in.uv).rg;
  // On reset take the current frame DIRECTLY — do not mix(hist, cur, 1.0): the
  // history texture is uninitialized (NaN) on the first frame, and mix computes
  // hist*(1-a)+cur*a, where NaN*0 = NaN would poison even the reset output and
  // propagate black through the feedback loop.
  float2 outv = u.reset > 0.5 ? cur : mix(hist, cur, u.alpha);
  return float4(outv.x, outv.y, 0.0, 1.0);
}
)";

void RendererMetal::ensurePostTargets(NSUInteger w, NSUInteger h)
{
  if (w == 0 || h == 0) return;
  buildPostPipelines();
  if (_sceneColor && _rtW == w && _rtH == h) return;
  _rtW = w; _rtH = h;

  // MRC (no ARC): release the PREVIOUS size's targets before reallocating.
  // Without this, every resize leaks a full target set, and a continuous
  // resize drag leaks dozens of full-res (MSAA) sets per second → the app is
  // OOM-jettisoned on a memory-constrained device ("crashes on resize").
  // The render-pass descriptors are updated below, so any in-flight command
  // buffer keeps its own retain until it completes — this is safe.
  [_sceneColor release];   [_postColor release];   [_sceneDepth release];
  [_sceneColorMS release];  [_sceneDepthMS release];
  [_oitAccum release];      [_oitReveal release];
  [_rtAO release];
  [_rtAOHistory release];   [_rtAOAccum release];
  [_surfaceCoverageTex release];
  [_aoExemptMaskTex release];
  _sceneColor = _postColor = _sceneDepth = nil;
  _sceneColorMS = _sceneDepthMS = nil;
  _oitAccum = _oitReveal = nil;
  _surfaceCoverageTex = nil;
  _aoExemptMaskTex = nil;
  _rtAO = nil;
  _rtAOHistory = _rtAOAccum = nil;
  _rtAOHistoryValid = false;  // resized AO targets: history is stale, hard-reset

  MTLTextureDescriptor* cd = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w height:h mipmapped:NO];
  cd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  cd.storageMode = MTLStorageModePrivate;
  _sceneColor = [_device newTextureWithDescriptor:cd];
  _postColor = [_device newTextureWithDescriptor:cd];

  // Surface outer-contour coverage mask (single-sample R8): the surface footprint
  // is rendered here after the scene, then post_surface_contour outlines its
  // boundary. Single-sample so the post pass reads it directly (no MSAA resolve).
  MTLTextureDescriptor* covd = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                   width:w height:h mipmapped:NO];
  covd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  covd.storageMode = MTLStorageModePrivate;
  _surfaceCoverageTex = [_device newTextureWithDescriptor:covd];
  // Per-rep AO-exempt mask (#79): same single-sample R8, rasterized depth-tested
  // against _sceneDepth so only front-most cartoon/ribbon pixels are marked.
  _aoExemptMaskTex = [_device newTextureWithDescriptor:covd];

  // Raw RT terms: ambient occlusion in .r, traced light-visibility (hard
  // shadow) in .g. Kept in its own float texture so the composite pass can
  // depth-aware-blur both — that blur is what removes the Monte-Carlo speckle
  // the raw estimates would otherwise show. RG (not R) so the metal_rt_shadows
  // path can carry the traced shadow term alongside AO at no extra pass.
  MTLTextureDescriptor* aod = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                   width:w height:h mipmapped:NO];
  aod.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  aod.storageMode = MTLStorageModePrivate;
  _rtAO = [_device newTextureWithDescriptor:aod];
  // Temporal-AO history + accumulation targets (same RG16Float layout as _rtAO).
  _rtAOHistory = [_device newTextureWithDescriptor:aod];
  _rtAOAccum = [_device newTextureWithDescriptor:aod];
  _rtAOHistoryValid = false;

  MTLTextureDescriptor* dd = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                   width:w height:h mipmapped:NO];
  dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  dd.storageMode = MTLStorageModePrivate;
  _sceneDepth = [_device newTextureWithDescriptor:dd];

  if (!_scenePassDesc)
    _scenePassDesc = [[MTLRenderPassDescriptor alloc] init];
  if (_sampleCount > 1) {
    // MSAA: the scene renders to multisampled targets and resolves into the
    // single-sample _sceneColor/_sceneDepth that the post chain samples.
    // StoreAndMultisampleResolve keeps the MS content so the scene encoder can
    // be resumed (selection indicators) across the OIT pass before the final
    // resolve.
    MTLTextureDescriptor* cms = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w height:h mipmapped:NO];
    cms.textureType = MTLTextureType2DMultisample;
    cms.sampleCount = _sampleCount;
    cms.usage = MTLTextureUsageRenderTarget;
    cms.storageMode = MTLStorageModePrivate;
    _sceneColorMS = [_device newTextureWithDescriptor:cms];
    MTLTextureDescriptor* dms = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                     width:w height:h mipmapped:NO];
    dms.textureType = MTLTextureType2DMultisample;
    dms.sampleCount = _sampleCount;
    dms.usage = MTLTextureUsageRenderTarget;
    dms.storageMode = MTLStorageModePrivate;
    _sceneDepthMS = [_device newTextureWithDescriptor:dms];

    _scenePassDesc.colorAttachments[0].texture = _sceneColorMS;
    _scenePassDesc.colorAttachments[0].resolveTexture = _sceneColor;
    _scenePassDesc.colorAttachments[0].storeAction =
        MTLStoreActionStoreAndMultisampleResolve;
    _scenePassDesc.depthAttachment.texture = _sceneDepthMS;
    _scenePassDesc.depthAttachment.resolveTexture = _sceneDepth;
    _scenePassDesc.depthAttachment.depthResolveFilter =
        MTLMultisampleDepthResolveFilterSample0;
    _scenePassDesc.depthAttachment.storeAction =
        MTLStoreActionStoreAndMultisampleResolve;
    _scenePassDesc.stencilAttachment.texture = _sceneDepthMS;
    _scenePassDesc.stencilAttachment.storeAction = MTLStoreActionDontCare;
  } else {
    _sceneColorMS = nil;
    _sceneDepthMS = nil;
    _scenePassDesc.colorAttachments[0].texture = _sceneColor;
    _scenePassDesc.colorAttachments[0].resolveTexture = nil;
    _scenePassDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    _scenePassDesc.depthAttachment.texture = _sceneDepth;
    _scenePassDesc.depthAttachment.resolveTexture = nil;
    _scenePassDesc.depthAttachment.storeAction = MTLStoreActionStore;
    _scenePassDesc.stencilAttachment.texture = _sceneDepth;
  }

  // OIT accumulation targets (weighted-blended). accum holds Σ premul·weight,
  // reveal holds Π(1-α). They share the opaque depth (tested, not written).
  MTLTextureDescriptor* ad = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                   width:w height:h mipmapped:NO];
  ad.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  ad.storageMode = MTLStorageModePrivate;
  _oitAccum = [_device newTextureWithDescriptor:ad];
  MTLTextureDescriptor* rd = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float
                                   width:w height:h mipmapped:NO];
  rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  rd.storageMode = MTLStorageModePrivate;
  _oitReveal = [_device newTextureWithDescriptor:rd];

  if (!_oitPassDesc)
    _oitPassDesc = [[MTLRenderPassDescriptor alloc] init];
  _oitPassDesc.colorAttachments[0].texture = _oitAccum;
  _oitPassDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
  _oitPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  _oitPassDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
  _oitPassDesc.colorAttachments[1].texture = _oitReveal;
  _oitPassDesc.colorAttachments[1].loadAction = MTLLoadActionClear;
  _oitPassDesc.colorAttachments[1].clearColor = MTLClearColorMake(1, 0, 0, 0);
  _oitPassDesc.colorAttachments[1].storeAction = MTLStoreActionStore;
  _oitPassDesc.depthAttachment.texture = _sceneDepth;
  _oitPassDesc.depthAttachment.loadAction = MTLLoadActionLoad; // keep opaque depth
  _oitPassDesc.depthAttachment.storeAction = MTLStoreActionStore;
  _oitPassDesc.stencilAttachment.texture = _sceneDepth;
  _oitPassDesc.stencilAttachment.loadAction = MTLLoadActionLoad;

  // Shadow map: fixed-resolution single-sample depth target rendered from the
  // light POV. Independent of the viewport (kShadowDim^2), so it survives
  // resize without recreation. A depth-only pass (no color attachment) is valid.
  if (!_shadowDepth) {
    MTLTextureDescriptor* sd = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                     width:kShadowDim height:kShadowDim
                                 mipmapped:NO];
    sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    sd.storageMode = MTLStorageModePrivate;
    _shadowDepth = [_device newTextureWithDescriptor:sd];
  }
  if (!_shadowPassDesc) {
    _shadowPassDesc = [[MTLRenderPassDescriptor alloc] init];
    _shadowPassDesc.depthAttachment.texture = _shadowDepth;
    _shadowPassDesc.depthAttachment.loadAction = MTLLoadActionClear;
    _shadowPassDesc.depthAttachment.clearDepth = 1.0;
    _shadowPassDesc.depthAttachment.storeAction = MTLStoreActionStore;
  }
}

void RendererMetal::buildPostPipelines()
{
  if (_blitPipeline) return;
  NSError* err = nil;
  id<MTLLibrary> lib = [_device newLibraryWithSource:kPostSrc options:nil error:&err];
  if (!lib) { NSLog(@"RendererMetal: post lib compile failed: %@", err); return; }

  if (!_postSampler) {
    MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _postSampler = [_device newSamplerStateWithDescriptor:sd];
    [sd release];  // MRC: descriptor (+1) consumed by sampler creation
  }
  if (!_shadowSampler) {
    // Depth-COMPARISON sampler with LINEAR filtering: each sample_compare tap
    // does hardware 2x2 bilinear PCF (sub-texel-smooth occlusion fraction)
    // instead of a hard nearest-texel compare, so shadow edges don't stair-step
    // into blocks at high zoom. compareFunction = LessEqual matches the manual
    // `fragDepth - sep <= storedDepth` test. Clamp avoids border false shadows.
    MTLSamplerDescriptor* ss = [[MTLSamplerDescriptor alloc] init];
    ss.minFilter = MTLSamplerMinMagFilterLinear;
    ss.magFilter = MTLSamplerMinMagFilterLinear;
    ss.sAddressMode = MTLSamplerAddressModeClampToEdge;
    ss.tAddressMode = MTLSamplerAddressModeClampToEdge;
    ss.compareFunction = MTLCompareFunctionLessEqual;
    _shadowSampler = [_device newSamplerStateWithDescriptor:ss];
    [ss release];  // MRC: descriptor (+1) consumed by sampler creation
  }

  id<MTLFunction> vfn = [lib newFunctionWithName:@"post_vertex"];
  auto mkpipe = [&](NSString* name) -> id<MTLRenderPipelineState> {
    id<MTLFunction> ffn = [lib newFunctionWithName:name];
    if (!vfn || !ffn) { [ffn release]; return nil; }
    MTLRenderPipelineDescriptor* psd = [[MTLRenderPipelineDescriptor alloc] init];
    psd.vertexFunction = vfn; psd.fragmentFunction = ffn;
    psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    NSError* e = nil;
    id<MTLRenderPipelineState> p =
        [_device newRenderPipelineStateWithDescriptor:psd error:&e];
    if (!p) NSLog(@"RendererMetal: post pipeline %@ failed: %@", name, e);
    [psd release];  // MRC: descriptor (+1) consumed by pipeline creation
    [ffn release];  // MRC: fragment function (+1) retained by the pipeline
    return p;
  };
  _blitPipeline = mkpipe(@"post_blit");
  _tonemapPipeline = mkpipe(@"post_tonemap");
  _exportAlphaPipeline = mkpipe(@"post_export_alpha");
  _fxaaPipeline = mkpipe(@"post_fxaa");
  _ssaoPipeline = mkpipe(@"post_ssao_fog");
  _oitResolvePipeline = mkpipe(@"oit_resolve");
  _outlinePipeline = mkpipe(@"post_outline");
  _surfaceContourPipeline = mkpipe(@"post_surface_contour");
  _dofPipeline = mkpipe(@"post_dof");
  _shadowDebugPipeline = mkpipe(@"post_shadow_debug");
  // Temporal-AO accumulate pipeline writes the RG16Float accumulation target, so
  // it cannot use mkpipe (which hardcodes BGRA8). Built inline with that format.
  {
    id<MTLFunction> afn = [lib newFunctionWithName:@"post_ao_accum"];
    if (vfn && afn) {
      MTLRenderPipelineDescriptor* psd = [[MTLRenderPipelineDescriptor alloc] init];
      psd.vertexFunction = vfn; psd.fragmentFunction = afn;
      psd.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;
      NSError* e = nil;
      _rtAOAccumPipeline = [_device newRenderPipelineStateWithDescriptor:psd error:&e];
      if (!_rtAOAccumPipeline)
        NSLog(@"RendererMetal: post_ao_accum pipeline failed: %@", e);
      [psd release];  // MRC: descriptor (+1) consumed by pipeline creation
    }
    [afn release];  // MRC: function (+1) retained by the pipeline
  }
  // MRC: the shared vertex function and the source library (+1) are no longer
  // needed once all post pipelines are built.
  [vfn release];
  [lib release];
}

void RendererMetal::setPostParams(int fogEnabled, float fogStart, float fogEnd,
    float bgR, float bgG, float bgB, int aoEnabled, int shadowEnabled,
    int aaEnabled, int outlineEnabled, float projA, float projB, float projX,
    float projY, int rtEnabled, int tonemapEnabled, float exposure,
    int rtShadowEnabled, float outlineR, float outlineG, float outlineB,
    float outlineWidth, int dofEnabled, float dofFocus, float dofRange,
    int temporalAO, int upscaleEnabled, float dofAperture)
{
  _dofEnabled = dofEnabled;
  _dofFocus = dofFocus;
  _dofRange = dofRange;
  _dofAperture = dofAperture;
  _temporalAOEnabled = temporalAO;
  _upscaleEnabled = upscaleEnabled;
  _tonemapEnabled = tonemapEnabled;
  _exposure = exposure;
  _rtShadowEnabled = rtShadowEnabled;
  _outlineR = outlineR; _outlineG = outlineG; _outlineB = outlineB;
  _outlineWidth = outlineWidth;
  _postFogEnabled = fogEnabled;
  _fogStart = fogStart;
  _fogEnd = fogEnd;
  _bgR = bgR; _bgG = bgG; _bgB = bgB;
  _aoEnabled = aoEnabled;
  _shadowEnabled = shadowEnabled;
  _aaEnabled = aaEnabled;
  _outlineEnabled = outlineEnabled;
  _projA = projA;
  _projB = projB;
  _projX = projX;
  _projY = projY;
  static bool noRT = getenv("PYMOL_NO_RT") != nullptr;
  _rtEnabled = (rtEnabled && _rtSupported && !noRT) ? 1 : 0;
}

void RendererMetal::setLightingParams(float ambient, float direct,
    float reflect, float specular, float shininess, float sssWrap)
{
  _lightAmbient = ambient;
  _lightDirect = direct;
  _lightReflect = reflect;
  _lightSpecular = specular;
  _lightShininess = shininess;
  _sssWrap = sssWrap;
}

// ---------------------------------------------------------------------------
#pragma mark - Real-time ray tracing: acceleration structures
// ---------------------------------------------------------------------------

// Separate MSL source (only compiled when the device supports ray tracing, so
// the #include <metal_raytracing> + intersector code can never break the main
// post library on non-RT devices). Fullscreen fragment pass: reconstruct the
// eye-space position + normal from the scene depth, transform to MODEL space
// (where the acceleration structure lives), trace ambient-occlusion rays + a
// shadow ray against the atom-sphere instance AS, and composite (+ depth fog).
static NSString* const kRTSrc = @R"(
#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace raytracing;

struct PostVOut { float4 position [[position]]; float2 uv; };
vertex PostVOut rt_vertex(uint vid [[vertex_id]]) {
  float2 p = float2((vid << 1) & 2, vid & 2);
  PostVOut o;
  o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
  o.uv = float2(p.x, 1.0 - p.y);
  return o;
}

struct RTU {
  float4x4 invModelview;   // eye -> model/world
  float4 lightDirModel;    // model-space direction TOWARD the key light
  float4 bgFog;            // bg.rgb, fogEnabled
  float projA, projB, projX, projY;
  float fogStart, fogEnd, aoRadius, aoIntensity;
  float shadowIntensity, nSamples, frame, rtShadow; // rtShadow>0.5: trace shadows
  float4x4 lightViewProj;  // eye-space light view*proj for shadow-map sampling
};

static float rt_hash(float2 p) {
  return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

// Van der Corput radical inverse (base 2) -> Hammersley point set. Stratified
// (low-discrepancy) AO directions have far lower variance than the old per-pixel
// white-noise hash at the same sample count, so much less grain; and since they
// don't depend on the frame counter, the AO is identical every frame (no shimmer).
static float rt_radinv2(uint bits) {
  bits = (bits << 16) | (bits >> 16);
  bits = ((bits & 0x55555555u) << 1) | ((bits & 0xAAAAAAAAu) >> 1);
  bits = ((bits & 0x33333333u) << 2) | ((bits & 0xCCCCCCCCu) >> 2);
  bits = ((bits & 0x0F0F0F0Fu) << 4) | ((bits & 0xF0F0F0F0u) >> 4);
  bits = ((bits & 0x00FF00FFu) << 8) | ((bits & 0xFF00FF00u) >> 8);
  return float(bits) * 2.3283064365386963e-10;
}
static float2 rt_hammersley(uint i, uint n) {
  return float2(float(i) / float(n), rt_radinv2(i));
}

// Pass A: trace ambient-occlusion rays, write the raw AO term to an R16Float
// target. Deterministic Hammersley directions (frame-stable -> no shimmer) with
// a cheap per-pixel rotation so residual error is a fine pattern the composite
// pass blurs away.
fragment float4 rt_ao(PostVOut in [[stage_in]],
    depth2d<float> depthTex [[texture(1)]],
    sampler s [[sampler(0)]],
    instance_acceleration_structure accel [[buffer(0)]],
    constant RTU& u [[buffer(1)]]) {
  float d = depthTex.sample(s, in.uv);
  if (d >= 0.99999 || d <= 0.0015) return float4(1.0, 1.0, 1.0, 1.0);  // no occlusion

  // Eye-space position + robust normal (matches post_ssao_fog reconstruction).
  // post_eye_normal avoids the cross-silhouette derivative blow-up that plain
  // cross(dfdx,dfdy) produces, which otherwise mis-orients the AO hemisphere /
  // ray-origin bias in a 1-2px band along every silhouette.
  float3 pEye = post_eye_pos(in.uv, d, u.projA, u.projB, u.projX, u.projY);
  float2 invres = 1.0 / float2(depthTex.get_width(), depthTex.get_height());
  float3 nEye = post_eye_normal(depthTex, s, in.uv, invres, d, pEye,
                                u.projA, u.projB, u.projX, u.projY);

  float3 pModel = (u.invModelview * float4(pEye, 1.0)).xyz;
  float3 nModel = normalize((u.invModelview * float4(nEye, 0.0)).xyz);
  float3 upv = abs(nModel.z) < 0.9 ? float3(0, 0, 1) : float3(1, 0, 0);
  float3 tx = normalize(cross(upv, nModel));
  float3 ty = cross(nModel, tx);

  intersector<instancing> it;
  it.assume_geometry_type(geometry_type::triangle);
  it.accept_any_intersection(true);   // occlusion: stop at first hit

  float bias = max(u.aoRadius * 0.03, 0.02);
  float3 origin = pModel + nModel * bias;

  int N = max(int(u.nSamples), 1);
  float rot = rt_hash(in.uv * 1024.0 + u.frame); // per-pixel Cranley-Patterson rotation; +frame jitters per-frame for temporal AO (frame=0 => identical to before)
  float occ = 0.0;
  for (int i = 0; i < N; ++i) {
    float2 hx = rt_hammersley(uint(i), uint(N));
    float h1 = hx.x;
    float phi = 6.2831853 * fract(hx.y + rot);
    float r = sqrt(h1);                  // cosine-weighted hemisphere
    float3 dirT = float3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - h1)));
    float3 dir = normalize(dirT.x * tx + dirT.y * ty + dirT.z * nModel);
    ray rr;
    rr.origin = origin;
    rr.direction = dir;
    rr.min_distance = bias;
    rr.max_distance = u.aoRadius;
    auto res = it.intersect(rr, accel);
    if (res.type != intersection_type::none) occ += 1.0;
  }
  float ao = 1.0 - (occ / float(N)) * u.aoIntensity;

  // Traced hard shadow toward the key light (model space), written to .g.
  // Reuses the same instance AS that already holds spheres + tessellated
  // cylinders + cartoon/surface triangles, so the shadow is cast uniformly by
  // every representation — no shadow-map resolution/peter-panning. vis = 1 lit,
  // 0 occluded. Back-facing fragments skip the ray (vis=1); the composite
  // faceGate zeroes their cast-shadow term so diffuse alone darkens them.
  float vis = 1.0;
  if (u.rtShadow > 0.5) {
    float3 Lm = normalize(u.lightDirModel.xyz);
    if (dot(nModel, Lm) > 0.0) {
      ray sr;
      sr.origin = origin;            // already pModel + nModel*bias
      sr.direction = Lm;
      sr.min_distance = bias;
      sr.max_distance = 1.0e4;       // full directional shadow, not just contact
      auto sres = it.intersect(sr, accel);
      if (sres.type != intersection_type::none) vis = 0.0;
    }
  }
  return float4(ao, vis, 0.0, 1.0);
}

// Pass B: composite. Read scene color, DEPTH-AWARE-BLUR the raw AO term (5x5,
// silhouette-preserving) to remove the Monte-Carlo speckle, apply it, then the
// shadow-map PCF and depth-cue fog (identical to the old single-pass resolve).
fragment float4 rt_composite(PostVOut in [[stage_in]],
    texture2d<float> colorTex [[texture(0)]],
    depth2d<float> depthTex [[texture(1)]],
    depth2d<float> shadowTex [[texture(2)]],
    texture2d<float> aoTex [[texture(3)]],
    sampler s [[sampler(0)]],
    sampler shadowSamp [[sampler(1)]],
    constant RTU& u [[buffer(1)]]) {
  float3 col = colorTex.sample(s, in.uv).rgb;
  float d = depthTex.sample(s, in.uv);
  if (d >= 0.99999) return float4(col, 1.0);  // background: leave as-is
  if (d <= 0.0015) return float4(col, 1.0);   // interior-cap cross-section: flat

  // Eye-space position + robust normal (matches post_ssao_fog reconstruction).
  // post_eye_normal avoids the cross-silhouette derivative blow-up that plain
  // cross(dfdx,dfdy) produces (serrated lighter shadow border on edges).
  float3 pEye = post_eye_pos(in.uv, d, u.projA, u.projB, u.projX, u.projY);
  float2 invres = 1.0 / float2(colorTex.get_width(), colorTex.get_height());
  float3 nEye = post_eye_normal(depthTex, s, in.uv, invres, d, pEye,
                                u.projA, u.projB, u.projX, u.projY);

  // Depth-aware 5x5 blur of the AO term: weight neighbours by eye-space depth
  // closeness so AO doesn't bleed across object silhouettes.
  float2 texel = 1.0 / float2(aoTex.get_width(), aoTex.get_height());
  float ztol = max(0.5 * u.aoRadius, 0.5);
  float aoSum = 0.0, visSum = 0.0, wSum = 0.0;
  for (int j = -2; j <= 2; ++j)
    for (int i = -2; i <= 2; ++i) {
      float2 uv = in.uv + float2(i, j) * texel;
      float dn = depthTex.sample(s, uv);
      if (dn >= 0.99999) continue;
      float ezn = -u.projB / ((2.0 * dn - 1.0) + u.projA);
      float w = exp(-abs(ezn - pEye.z) / ztol);
      float2 rg = aoTex.sample(s, uv).rg;
      aoSum += rg.r * w;
      visSum += rg.g * w;
      wSum += w;
    }
  float ao = wSum > 0.0 ? (aoSum / wSum) : aoTex.sample(s, in.uv).r;
  float vis = wSum > 0.0 ? (visSum / wSum) : aoTex.sample(s, in.uv).g;
  col *= ao;

  // Cast shadows. Two paths share the shadowIntensity gate:
  //  - metal_rt_shadows (u.rtShadow): use the hard shadow ray traced in rt_ao
  //    (visibility in .g), gated by a model-space faceGate so only lit faces
  //    receive a cast-shadow term (back faces are darkened by diffuse alone).
  //  - otherwise: the original shadow-map PCF (unchanged fallback), kept so the
  //    default RT path and non-RT-capable GPUs are byte-for-byte identical.
  if (u.shadowIntensity > 0.0 && u.rtShadow > 0.5) {
    float3 nModel = normalize((u.invModelview * float4(nEye, 0.0)).xyz);
    float3 Lm = normalize(u.lightDirModel.xyz);
    float faceGate = smoothstep(0.0, 0.35, dot(nModel, Lm));
    float shadow = (1.0 - vis) * faceGate;
    col *= (1.0 - shadow * u.shadowIntensity);
  } else if (u.shadowIntensity > 0.0) {
    float3 Ldir = normalize(float3(0.4, 0.4, 1.0));      // key light (eye space)
    float faceGate = smoothstep(0.0, 0.35, dot(nEye, Ldir));
    float4 lc = u.lightViewProj * float4(pEye, 1.0);     // eye -> light clip
    if (faceGate > 0.0 && lc.w > 0.0) {
      float3 ndc = lc.xyz / lc.w;
      float2 suv = float2(0.5 * ndc.x + 0.5, 0.5 - 0.5 * ndc.y);
      float fragDepth = 0.5 + 0.5 * ndc.z;
      if (suv.x > 0.0 && suv.x < 1.0 && suv.y > 0.0 && suv.y < 1.0 &&
          fragDepth > 0.0 && fragDepth < 1.0) {
        float2 dd = float2(dfdx(fragDepth), dfdy(fragDepth));
        float sep = min(0.022 + 2.5 * (abs(dd.x) + abs(dd.y)), 0.05);
        float2 stex = 1.0 / float2(shadowTex.get_width(), shadowTex.get_height());
        float lit = 0.0;
        for (int j = -2; j <= 1; j++)
          for (int i = -2; i <= 1; i++) {
            float2 off = (float2(i, j) + 0.5) * 1.5 * stex;
            lit += shadowTex.sample_compare(shadowSamp, suv + off, fragDepth - sep);
          }
        float shadow = (1.0 - lit / 16.0) * faceGate;
        col *= (1.0 - shadow * u.shadowIntensity);
      }
    }
  }

  // Depth-cue fog toward bg (eye distance), matching the SSAO pass.
  if (u.bgFog.w > 0.5) {
    float dist = -pEye.z; // eye distance (pEye.z is the eye-space z, negative)
    float f = clamp((dist - u.fogStart) / max(u.fogEnd - u.fogStart, 1e-3), 0.0, 1.0);
    col = mix(col, u.bgFog.rgb, f);
  }
  return float4(col, 1.0);
}
)";


// Tessellate a cylinder (a→b, radius r) into a K-sided tube (no caps — bonded
// atoms cover the ends) and append the triangles (x,y,z per vertex) to `out`.
static void rtAppendCylinder(std::vector<float>& out, simd_float3 a, simd_float3 b, float r)
{
  simd_float3 axis = b - a;
  float len = simd_length(axis);
  if (len < 1e-5f || r <= 0.0f) return;
  axis /= len;
  simd_float3 up = fabsf(axis.z) < 0.9f ? simd_make_float3(0, 0, 1)
                                        : simd_make_float3(1, 0, 0);
  simd_float3 t1 = simd_normalize(simd_cross(up, axis));
  simd_float3 t2 = simd_cross(axis, t1);
  const int K = 6;
  simd_float3 ringA[K], ringB[K];
  for (int i = 0; i < K; ++i) {
    float ang = 6.2831853f * (float)i / (float)K;
    simd_float3 off = (cosf(ang) * t1 + sinf(ang) * t2) * r;
    ringA[i] = a + off;
    ringB[i] = b + off;
  }
  auto push = [&](simd_float3 p) { out.push_back(p.x); out.push_back(p.y); out.push_back(p.z); };
  for (int i = 0; i < K; ++i) {
    int j = (i + 1) % K;
    push(ringA[i]); push(ringA[j]); push(ringB[j]);
    push(ringA[i]); push(ringB[j]); push(ringB[i]);
  }
}

// Append the triangles of a VBO (cartoon/surface mesh) to `out`, reading the
// float3 position at posOffset. Handles triangle list/strip/fan/quads; indices
// are UInt32 (matches drawVBOIndexed) or sequential when indexData is null.
static void rtAppendVBOTris(std::vector<float>& out, PrimitiveType mode,
    int count, const void* data, size_t stride, int posOffset, const void* indexData)
{
  if (!data || stride == 0 || posOffset < 0 || count < 3) return;
  const uint8_t* base = static_cast<const uint8_t*>(data);
  const uint32_t* idx = static_cast<const uint32_t*>(indexData);
  auto gi = [&](int k) -> uint32_t { return idx ? idx[k] : (uint32_t)k; };
  auto push = [&](uint32_t vi) {
    const float* p = reinterpret_cast<const float*>(base + (size_t)vi * stride + posOffset);
    out.push_back(p[0]); out.push_back(p[1]); out.push_back(p[2]);
  };
  auto tri = [&](uint32_t i0, uint32_t i1, uint32_t i2) { push(i0); push(i1); push(i2); };
  using PT = PrimitiveType;
  if (mode == PT::Triangles) {
    for (int k = 0; k + 2 < count; k += 3) tri(gi(k), gi(k + 1), gi(k + 2));
  } else if (mode == PT::TriangleStrip) {
    for (int k = 0; k + 2 < count; ++k)
      (k & 1) ? tri(gi(k + 1), gi(k), gi(k + 2)) : tri(gi(k), gi(k + 1), gi(k + 2));
  } else if (mode == PT::TriangleFan) {
    for (int k = 1; k + 1 < count; ++k) tri(gi(0), gi(k), gi(k + 1));
  } else if (mode == PT::Quads) {
    for (int k = 0; k + 3 < count; k += 4) {
      tri(gi(k), gi(k + 1), gi(k + 2));
      tri(gi(k), gi(k + 2), gi(k + 3));
    }
  }
}

// Build (and synchronously complete) an acceleration structure from a descriptor.
// Used only when geometry changes, so the CPU stall is acceptable.
id<MTLAccelerationStructure>
RendererMetal::buildAccelStructure(MTLAccelerationStructureDescriptor* desc)
{
  MTLAccelerationStructureSizes sizes =
      [_device accelerationStructureSizesWithDescriptor:desc];
  id<MTLAccelerationStructure> as =
      [_device newAccelerationStructureWithSize:sizes.accelerationStructureSize];
  if (!as) return nil;
  id<MTLBuffer> scratch =
      [_device newBufferWithLength:std::max<NSUInteger>(sizes.buildScratchBufferSize, 16)
                          options:MTLResourceStorageModePrivate];
  id<MTLCommandBuffer> cb = [_queue commandBuffer];
  id<MTLAccelerationStructureCommandEncoder> e = [cb accelerationStructureCommandEncoder];
  [e buildAccelerationStructure:as descriptor:desc scratchBuffer:scratch scratchBufferOffset:0];
  [e endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  // MRC: the build has completed, so the scratch buffer (+1) is no longer needed.
  [scratch release];
  return as;  // +1 — caller takes ownership (stored in an _rt*AS ivar, dtor releases)
}

// One shared unit-radius icosphere (icosahedron subdivided once, ~80 tris) used
// as the instanced primitive — occlusion-only, so a coarse sphere is plenty.
void RendererMetal::buildSphereProtoAS()
{
  if (_rtSphereProtoAS) return;

  const float t = (1.0f + std::sqrt(5.0f)) * 0.5f;
  std::vector<simd_float3> v = {
      simd_make_float3(-1, t, 0), simd_make_float3(1, t, 0),
      simd_make_float3(-1, -t, 0), simd_make_float3(1, -t, 0),
      simd_make_float3(0, -1, t), simd_make_float3(0, 1, t),
      simd_make_float3(0, -1, -t), simd_make_float3(0, 1, -t),
      simd_make_float3(t, 0, -1), simd_make_float3(t, 0, 1),
      simd_make_float3(-t, 0, -1), simd_make_float3(-t, 0, 1)};
  std::vector<uint32_t> f = {
      0,11,5, 0,5,1, 0,1,7, 0,7,10, 0,10,11, 1,5,9, 5,11,4, 11,10,2, 10,7,6,
      7,1,8, 3,9,4, 3,4,2, 3,2,6, 3,6,8, 3,8,9, 4,9,5, 2,4,11, 6,2,10,
      8,6,7, 9,8,1};
  // One level of subdivision (midpoint split), then project to the unit sphere.
  std::unordered_map<uint64_t, uint32_t> midCache;
  auto midpoint = [&](uint32_t a, uint32_t b) -> uint32_t {
    uint64_t key = (uint64_t)std::min(a, b) << 32 | std::max(a, b);
    auto it = midCache.find(key);
    if (it != midCache.end()) return it->second;
    simd_float3 m = simd_normalize((v[a] + v[b]) * 0.5f);
    v.push_back(m);
    uint32_t idx = (uint32_t)v.size() - 1;
    midCache[key] = idx;
    return idx;
  };
  std::vector<uint32_t> f2;
  f2.reserve(f.size() * 4);
  for (size_t i = 0; i < f.size(); i += 3) {
    uint32_t a = f[i], b = f[i + 1], c = f[i + 2];
    uint32_t ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a);
    uint32_t tri[] = {a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca};
    f2.insert(f2.end(), tri, tri + 12);
  }
  for (auto& p : v) p = simd_normalize(p);

  std::vector<float> verts;
  verts.reserve(v.size() * 3);
  for (auto& p : v) { verts.push_back(p.x); verts.push_back(p.y); verts.push_back(p.z); }

  _rtProtoVerts = [_device newBufferWithBytes:verts.data()
                                       length:verts.size() * sizeof(float)
                                      options:MTLResourceStorageModeShared];
  _rtProtoIndices = [_device newBufferWithBytes:f2.data()
                                         length:f2.size() * sizeof(uint32_t)
                                        options:MTLResourceStorageModeShared];
  _rtProtoIndexCount = (uint32_t)f2.size();

  MTLAccelerationStructureTriangleGeometryDescriptor* geo =
      [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
  geo.vertexBuffer = _rtProtoVerts;
  geo.vertexStride = 3 * sizeof(float);
  geo.vertexFormat = MTLAttributeFormatFloat3;
  geo.indexBuffer = _rtProtoIndices;
  geo.indexType = MTLIndexTypeUInt32;
  geo.triangleCount = _rtProtoIndexCount / 3;
  geo.opaque = YES;

  MTLPrimitiveAccelerationStructureDescriptor* pdesc =
      [MTLPrimitiveAccelerationStructureDescriptor descriptor];
  pdesc.geometryDescriptors = @[geo];
  _rtSphereProtoAS = buildAccelStructure(pdesc);
}

// (Re)build the instance acceleration structure (one icosphere instance per
// atom, transform = translate(center)·scale(radius), MODEL space). Rebuilt only
// when the accumulated sphere set changes — model-space centers are invariant
// under camera rotation, so this does NOT rebuild while orbiting.
void RendererMetal::ensureRayTracingAS()
{
  if (!_rtEnabled || !_rtSupported) { _rtReady = false; return; }
  size_t nSph = _rtSpheres.size() / 4;
  size_t nTris = (_rtTris.size() / 3) / 3;   // verts→triangles
  if (nSph == 0 && nTris == 0) { _rtReady = false; return; }

  if (nSph > 0) buildSphereProtoAS();

  // Cheap change signature (counts + sampled coords) — rebuild only when the
  // geometry actually changes (stable across camera rotation, so no rebuild
  // while orbiting). Full FNV over big surface meshes every frame is wasteful.
  uint64_t h = 1469598103934665603ULL;
  auto mix = [&](uint64_t x) { h ^= x; h *= 1099511628211ULL; };
  mix(nSph); mix(nTris);
  auto sampleHash = [&](const std::vector<float>& vv) {
    size_t m = vv.size();
    if (!m) return;
    size_t step = m > 1024 ? m / 1024 : 1;
    for (size_t i = 0; i < m; i += step) { uint32_t b; std::memcpy(&b, &vv[i], 4); mix(b); }
  };
  sampleHash(_rtSpheres); sampleHash(_rtTris);
  if (_rtReady && _rtInstanceAS && h == _rtSphereHash) { /* unchanged */ }
  else {
    // (Re)build the world-triangle primitive AS (sticks + cartoon/surface).
    [_rtTriProtoAS release];  // MRC: release the previous rebuild's proto AS (+1)
    _rtTriProtoAS = nil;
    if (nTris > 0) {
      id<MTLBuffer> tb = [_device newBufferWithBytes:_rtTris.data()
                                              length:_rtTris.size() * sizeof(float)
                                             options:MTLResourceStorageModeShared];
      MTLAccelerationStructureTriangleGeometryDescriptor* tgeo =
          [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
      tgeo.vertexBuffer = tb;
      tgeo.vertexStride = 3 * sizeof(float);
      tgeo.vertexFormat = MTLAttributeFormatFloat3;
      tgeo.triangleCount = nTris;
      tgeo.opaque = YES;
      MTLPrimitiveAccelerationStructureDescriptor* pd =
          [MTLPrimitiveAccelerationStructureDescriptor descriptor];
      pd.geometryDescriptors = @[tgeo];
      _rtTriProtoAS = buildAccelStructure(pd);
      // MRC: buildAccelStructure committed+waited, so the source vertex buffer
      // (+1) is no longer needed (the AS holds its own compacted geometry).
      [tb release];
    }

    // Top-level instance AS: N icosphere instances (atoms) + 1 world-tri
    // instance (identity). instancedAccelerationStructures indexes the protos.
    NSMutableArray* protos = [NSMutableArray array];
    int sphereIdx = -1, triIdx = -1;
    if (nSph > 0 && _rtSphereProtoAS) { sphereIdx = (int)protos.count; [protos addObject:_rtSphereProtoAS]; }
    if (_rtTriProtoAS) { triIdx = (int)protos.count; [protos addObject:_rtTriProtoAS]; }
    size_t nInst = (sphereIdx >= 0 ? nSph : 0) + (triIdx >= 0 ? 1 : 0);
    if (nInst == 0 || protos.count == 0) { _rtReady = false; return; }

    id<MTLBuffer> instBuf =
        [_device newBufferWithLength:nInst * sizeof(MTLAccelerationStructureInstanceDescriptor)
                            options:MTLResourceStorageModeShared];
    auto* inst = (MTLAccelerationStructureInstanceDescriptor*)instBuf.contents;
    size_t ii = 0;
    if (sphereIdx >= 0) {
      for (size_t i = 0; i < nSph; ++i, ++ii) {
        float x = _rtSpheres[i * 4], y = _rtSpheres[i * 4 + 1],
              z = _rtSpheres[i * 4 + 2], r = _rtSpheres[i * 4 + 3];
        if (r <= 0.0f) r = 0.001f;
        MTLPackedFloat4x3 m;
        m.columns[0].x = r; m.columns[0].y = 0; m.columns[0].z = 0;
        m.columns[1].x = 0; m.columns[1].y = r; m.columns[1].z = 0;
        m.columns[2].x = 0; m.columns[2].y = 0; m.columns[2].z = r;
        m.columns[3].x = x; m.columns[3].y = y; m.columns[3].z = z;
        inst[ii].transformationMatrix = m;
        inst[ii].options = MTLAccelerationStructureInstanceOptionOpaque;
        inst[ii].mask = 0xFF;
        inst[ii].intersectionFunctionTableOffset = 0;
        inst[ii].accelerationStructureIndex = sphereIdx;
      }
    }
    if (triIdx >= 0) {
      MTLPackedFloat4x3 m;
      m.columns[0].x = 1; m.columns[0].y = 0; m.columns[0].z = 0;
      m.columns[1].x = 0; m.columns[1].y = 1; m.columns[1].z = 0;
      m.columns[2].x = 0; m.columns[2].y = 0; m.columns[2].z = 1;
      m.columns[3].x = 0; m.columns[3].y = 0; m.columns[3].z = 0;
      inst[ii].transformationMatrix = m;
      inst[ii].options = MTLAccelerationStructureInstanceOptionOpaque;
      inst[ii].mask = 0xFF;
      inst[ii].intersectionFunctionTableOffset = 0;
      inst[ii].accelerationStructureIndex = triIdx;
      ++ii;
    }

    MTLInstanceAccelerationStructureDescriptor* idesc =
        [MTLInstanceAccelerationStructureDescriptor descriptor];
    idesc.instancedAccelerationStructures = protos;
    idesc.instanceCount = (NSUInteger)nInst;
    idesc.instanceDescriptorBuffer = instBuf;
    [_rtInstanceAS release];  // MRC: release the previous rebuild's instance AS (+1)
    _rtInstanceAS = buildAccelStructure(idesc);
    [instBuf release];  // MRC: build committed+waited; instance descriptor buffer (+1) done
    _rtSphereHash = h;
    _rtBuiltCount = nSph;
    _rtReady = (_rtInstanceAS != nil);

    static int once = 0;
    if (_rtReady && once++ < 5)
      NSLog(@"RendererMetal RT: AS rebuilt — %zu spheres + %zu triangles", nSph, nTris);
  }

  // Lazily compile the RT resolve pipeline (separate library so the raytracing
  // intersector code can't affect the main post library). If it fails, the RT
  // pass is skipped and the SSAO/shadow path runs — zero regression.
  if (_rtReady && !_rtResolvePipeline) {
    NSError* err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:kRTSrc options:nil error:&err];
    if (lib) {
      // Pass A: raw AO (.r) + traced light-visibility (.g) -> RG16Float.
      MTLRenderPipelineDescriptor* pa = [[MTLRenderPipelineDescriptor alloc] init];
      pa.vertexFunction = [lib newFunctionWithName:@"rt_vertex"];
      pa.fragmentFunction = [lib newFunctionWithName:@"rt_ao"];
      pa.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;
      _rtAOPipeline = [_device newRenderPipelineStateWithDescriptor:pa error:&err];
      // Pass B: blur AO + shadow/fog composite -> BGRA8.
      MTLRenderPipelineDescriptor* pd = [[MTLRenderPipelineDescriptor alloc] init];
      pd.vertexFunction = [lib newFunctionWithName:@"rt_vertex"];
      pd.fragmentFunction = [lib newFunctionWithName:@"rt_composite"];
      pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      _rtResolvePipeline = [_device newRenderPipelineStateWithDescriptor:pd error:&err];
    }
    if (!_rtAOPipeline || !_rtResolvePipeline)
      NSLog(@"RendererMetal RT: AO/composite pipeline failed: %@", err);
  }
}

void RendererMetal::runPostChain()
{
  if (!_blitPipeline) return;

  static bool noAA = getenv("PYMOL_NO_AA") != nullptr;
  static bool noAO = getenv("PYMOL_NO_AO") != nullptr;
  static bool noShadow = getenv("PYMOL_NO_SHADOW") != nullptr;
  bool doAO = _ssaoPipeline && _aoEnabled && !noAO;
  bool doFog = _ssaoPipeline && _postFogEnabled;
  bool doShadow = _ssaoPipeline && _shadowEnabled && !noShadow;
  bool doRT = _rtEnabled && _rtReady && _rtResolvePipeline && _rtAOPipeline &&
              _rtInstanceAS && _postColor && _rtAO;
  id<MTLTexture> sceneSrc = _sceneColor;

  // Pass 1-RT: real ray-traced AO + shadow (+ fog), replacing the SSAO/shadow
  // pass when metal_raytrace is on. Traces against the atom-sphere instance AS.
  if (doRT) {
    struct RTU {
      float invModelview[16];
      float lightDirModel[4];
      float bgFog[4];
      float projA, projB, projX, projY;
      float fogStart, fogEnd, aoRadius, aoIntensity;
      float shadowIntensity, nSamples, frame, rtShadow;
      float lightViewProj[16];   // eye-space light VP for shadow-map sampling
    } u;
    std::memcpy(u.invModelview, _modelviewInv.data(), 16 * sizeof(float));
    simd_float4x4 inv;
    std::memcpy(&inv, _modelviewInv.data(), 64);
    simd_float4 le = simd_normalize(simd_make_float4(0.4f, 0.4f, 1.0f, 0.0f));
    simd_float4 lm = simd_mul(inv, simd_make_float4(le.x, le.y, le.z, 0.0f));
    u.lightDirModel[0] = lm.x; u.lightDirModel[1] = lm.y;
    u.lightDirModel[2] = lm.z; u.lightDirModel[3] = 0.0f;
    u.bgFog[0] = _bgR; u.bgFog[1] = _bgG; u.bgFog[2] = _bgB;
    u.bgFog[3] = doFog ? 1.0f : 0.0f;
    u.projA = _projA; u.projB = _projB; u.projX = _projX; u.projY = _projY;
    u.fogStart = _fogStart; u.fogEnd = _fogEnd;
    u.aoRadius = 5.0f; u.aoIntensity = 0.72f;
    u.shadowIntensity = doShadow ? 0.45f : 0.0f;
    // 16 stratified (Hammersley) samples + the composite-pass blur is clean and
    // shimmer-free; for the single-shot offscreen PNG (no temporal smoothing)
    // trace more rays since each export frame stands alone.
    u.nSamples = _offscreen ? 48.0f : 16.0f;
    // Temporal AO: when enabled (and not a single-shot offscreen export), advance
    // the frame counter so rt_ao jitters each frame; the accumulate pass below
    // EMAs successive frames toward offscreen quality. Off => frame 0, which is
    // bit-identical to the previous frame-stable behavior (no shimmer).
    bool doTemporalAO = _temporalAOEnabled && !_offscreen && _rtAOAccumPipeline
        && _rtAOHistory && _rtAOAccum;
    u.frame = doTemporalAO ? (float)(_aoFrameCounter++ & 1023) : 0.0f;
    // metal_rt_shadows: trace a hard shadow ray in rt_ao instead of sampling the
    // shadow map in rt_composite. Only meaningful when shadows are on (the
    // composite still gates on shadowIntensity). Default off -> shadow-map path.
    u.rtShadow = _rtShadowEnabled ? 1.0f : 0.0f;
    std::memcpy(u.lightViewProj, _lightViewProjEye, 16 * sizeof(float));

    // Pass A: trace AO -> _rtAO (R16Float).
    // MRC: all per-frame render-pass descriptors in runPostChain use the
    // autoreleased +renderPassDescriptor ctor (NOT [[alloc] init], which is +1
    // and would leak every frame — runPostChain runs once per presented frame).
    // The per-pass encoders below are likewise autoreleased and have never
    // leaked, confirming the per-frame main-thread autorelease pool drains them.
    MTLRenderPassDescriptor* pa = [MTLRenderPassDescriptor renderPassDescriptor];
    pa.colorAttachments[0].texture = _rtAO;
    pa.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pa.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> ea =
        [_cmdBuffer renderCommandEncoderWithDescriptor:pa];
    [ea setRenderPipelineState:_rtAOPipeline];
    if (_rtSphereProtoAS)
      [ea useResource:_rtSphereProtoAS usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    if (_rtTriProtoAS)
      [ea useResource:_rtTriProtoAS usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    [ea setFragmentTexture:_sceneDepth atIndex:1];
    [ea setFragmentSamplerState:_postSampler atIndex:0];
    [ea setFragmentAccelerationStructure:_rtInstanceAS atBufferIndex:0];
    [ea setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [ea drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [ea endEncoding];

    // Pass A.5 (temporal AO only): EMA the freshly-traced _rtAO into history, so
    // a held-still view converges toward offscreen quality. Hard-reset (take the
    // current frame fully) on the first frame, a geometry change (_rtSphereHash),
    // or any camera move (_modelviewInv delta) so changes clear with no ghost.
    // Pass B then composites the accumulated AO instead of the single raw frame.
    id<MTLTexture> aoForComposite = _rtAO;
    if (doTemporalAO) {
      bool camMoved = false;
      for (int i = 0; i < 16; ++i)
        if (fabsf(_modelviewInv[i] - _modelviewInvPrev[i]) > 1e-6f) { camMoved = true; break; }
      bool reset = !_rtAOHistoryValid || camMoved || (_rtSphereHash != _rtAOHashPrev);
      struct { float alpha; float reset; float p0; float p1; } au;
      au.alpha = 0.1f; au.reset = reset ? 1.0f : 0.0f; au.p0 = au.p1 = 0.0f;
      MTLRenderPassDescriptor* pacc = [MTLRenderPassDescriptor renderPassDescriptor];
      pacc.colorAttachments[0].texture = _rtAOAccum;
      pacc.colorAttachments[0].loadAction = MTLLoadActionDontCare;
      pacc.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLRenderCommandEncoder> eacc =
          [_cmdBuffer renderCommandEncoderWithDescriptor:pacc];
      [eacc setRenderPipelineState:_rtAOAccumPipeline];
      [eacc setFragmentTexture:_rtAO atIndex:0];
      [eacc setFragmentTexture:_rtAOHistory atIndex:1];
      [eacc setFragmentSamplerState:_postSampler atIndex:0];
      [eacc setFragmentBytes:&au length:sizeof(au) atIndex:0];
      [eacc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [eacc endEncoding];
      // Persist the accumulation as next frame's history.
      id<MTLBlitCommandEncoder> blit = [_cmdBuffer blitCommandEncoder];
      [blit copyFromTexture:_rtAOAccum toTexture:_rtAOHistory];
      [blit endEncoding];
      aoForComposite = _rtAOAccum;
      _rtAOHistoryValid = true;
      _rtAOHashPrev = _rtSphereHash;
      _modelviewInvPrev = _modelviewInv;
    }

    // Pass B: depth-aware-blur the AO + shadow/fog composite -> _postColor.
    MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = _postColor;
    pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> er =
        [_cmdBuffer renderCommandEncoderWithDescriptor:pd];
    [er setRenderPipelineState:_rtResolvePipeline];
    [er setFragmentTexture:_sceneColor atIndex:0];
    [er setFragmentTexture:_sceneDepth atIndex:1];
    [er setFragmentTexture:_shadowDepth atIndex:2];
    [er setFragmentTexture:aoForComposite atIndex:3];
    [er setFragmentSamplerState:_postSampler atIndex:0];
    [er setFragmentSamplerState:_shadowSampler atIndex:1];
    [er setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [er drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [er endEncoding];
    sceneSrc = _postColor;
  }

  // Pass 1: SSAO + screen-space shadows + depth-cue/fog (color+depth -> post).
  else if ((doAO || doFog || doShadow) && _postColor) {
    // Per-rep AO/shadow exemption (#79): rasterize the stashed cartoon/ribbon
    // draws (depth-tested vs the scene) into _aoExemptMaskTex BEFORE the SSAO
    // pass, so post_ssao_fog can skip the contour terms on those pixels. Only
    // meaningful when AO or shadow is actually running.
    bool aoMaskReady = (doAO || doShadow) ? renderAOExemptMask() : false;

    struct {
      float projA, projB, fogStart, fogEnd;
      float bgR, bgG, bgB, fogEnabled;
      float aoEnabled, aoIntensity, aoRadiusPx, projX;
      float projY, shadowEnabled, shadowIntensity, aoExemptEnabled;
      float lightViewProj[16]; // eye-space light VP (matches MSL PostU)
    } u;
    u.projA = _projA; u.projB = _projB;
    u.fogStart = _fogStart; u.fogEnd = _fogEnd;
    u.bgR = _bgR; u.bgG = _bgG; u.bgB = _bgB;
    u.fogEnabled = doFog ? 1.0f : 0.0f;
    u.aoEnabled = doAO ? 1.0f : 0.0f;
    u.aoIntensity = 0.8f;
    u.aoRadiusPx = (float)_rtH * 0.015f; // ~1.5% of height
    u.projX = _projX; u.projY = _projY;
    u.shadowEnabled = doShadow ? 1.0f : 0.0f;
    u.shadowIntensity = 0.45f;
    u.aoExemptEnabled = aoMaskReady ? 1.0f : 0.0f;
    std::memcpy(u.lightViewProj, _lightViewProjEye, 16 * sizeof(float));

    MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = _postColor;
    pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e1 =
        [_cmdBuffer renderCommandEncoderWithDescriptor:pd];
    [e1 setRenderPipelineState:_ssaoPipeline];
    [e1 setFragmentTexture:_sceneColor atIndex:0];
    [e1 setFragmentTexture:_sceneDepth atIndex:1];
    [e1 setFragmentTexture:_shadowDepth atIndex:2];
    // texture(3) = AO-exempt mask; bind a valid 2D texture even when unused
    // (aoExemptEnabled gates the sample), since the shader declares it.
    [e1 setFragmentTexture:(aoMaskReady ? _aoExemptMaskTex : _sceneColor) atIndex:3];
    [e1 setFragmentSamplerState:_postSampler atIndex:0];
    [e1 setFragmentSamplerState:_shadowSampler atIndex:1];
    [e1 setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [e1 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e1 endEncoding];
    sceneSrc = _postColor;
  }

  // Pass 2: OIT resolve — composite accumulated transparency over the opaque
  // (post-processed) color. Ping-pongs to whichever target isn't the source.
  if (_oitHasContent && _oitResolvePipeline && _oitAccum) {
    id<MTLTexture> dst = (sceneSrc == _sceneColor) ? _postColor : _sceneColor;
    MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = dst;
    pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e2 =
        [_cmdBuffer renderCommandEncoderWithDescriptor:pd];
    [e2 setRenderPipelineState:_oitResolvePipeline];
    [e2 setFragmentTexture:sceneSrc atIndex:0];
    [e2 setFragmentTexture:_oitAccum atIndex:1];
    [e2 setFragmentTexture:_oitReveal atIndex:2];
    [e2 setFragmentSamplerState:_postSampler atIndex:0];
    [e2 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e2 endEncoding];
    sceneSrc = dst;
  }

  // Pass 2.5: depth-of-field — CoC blur by distance from the focal plane. Runs
  // on the fully-composited (opaque + OIT) color, before outlines. Default off
  // (_dofEnabled) => skipped entirely, so the default render is unchanged.
  if (_dofEnabled && _dofPipeline && _sceneDepth) {
    id<MTLTexture> dst = (sceneSrc == _sceneColor) ? _postColor : _sceneColor;
    struct {
      float projA, projB, invW, invH;
      float focusDist, focusRange, maxRadiusPx, _pad;
    } u;
    u.projA = _projA; u.projB = _projB;
    u.invW = (_rtW > 0) ? 1.0f / (float)_rtW : 0.0f;
    u.invH = (_rtH > 0) ? 1.0f / (float)_rtH : 0.0f;
    u.focusDist = _dofFocus;
    u.focusRange = (_dofRange > 0.01f) ? _dofRange : 14.0f;
    // Resolution-relative: the aperture is authored in px at the live resolution,
    // so scale it for hi-res exports (pixelRadiusScale()==1 on the live view) —
    // otherwise the bokeh nearly vanishes in 2x/4K Copy/Save output (#48).
    u.maxRadiusPx = ((_dofAperture > 0.0f) ? _dofAperture : 14.0f) * pixelRadiusScale();
    u._pad = 0.0f;
    MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = dst;
    pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> ed =
        [_cmdBuffer renderCommandEncoderWithDescriptor:pd];
    [ed setRenderPipelineState:_dofPipeline];
    [ed setFragmentTexture:sceneSrc atIndex:0];
    [ed setFragmentTexture:_sceneDepth atIndex:1];
    [ed setFragmentSamplerState:_postSampler atIndex:0];
    [ed setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [ed drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [ed endEncoding];
    sceneSrc = dst;
  }

  // Pass 3: silhouette/toon outlines (depth-based edges over the scene color).
  if (_outlineEnabled && _outlinePipeline && _sceneDepth) {
    id<MTLTexture> dst = (sceneSrc == _sceneColor) ? _postColor : _sceneColor;
    struct {
      float projA, projB, invW, invH;
      float colR, colG, colB, thickness;
    } u;
    u.projA = _projA; u.projB = _projB;
    u.invW = (_rtW > 0) ? 1.0f / (float)_rtW : 0.0f;
    u.invH = (_rtH > 0) ? 1.0f / (float)_rtH : 0.0f;
    u.colR = _outlineR; u.colG = _outlineG; u.colB = _outlineB;
    // Resolution-relative thickness so outlines aren't hairline-thin in hi-res
    // exports (pixelRadiusScale()==1 on the live view; see #48).
    u.thickness = _outlineWidth * pixelRadiusScale();
    MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = dst;
    pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e3 =
        [_cmdBuffer renderCommandEncoderWithDescriptor:pd];
    [e3 setRenderPipelineState:_outlinePipeline];
    [e3 setFragmentTexture:sceneSrc atIndex:0];
    [e3 setFragmentTexture:_sceneDepth atIndex:1];
    [e3 setFragmentSamplerState:_postSampler atIndex:0];
    [e3 setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [e3 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e3 endEncoding];
    sceneSrc = dst;
  }

  // Pass 3.4: surface OUTER contour. Render the stashed surface footprint into a
  // coverage mask, then outline the mask boundary over the scene color. Works on
  // transparent/clipped surfaces (coverage is independent of depth/OIT).
  if (_contourActive && !_coverageDraws.empty() && _surfaceContourPipeline &&
      _surfaceCoverageTex && _coverageVtxFunc && _coverageFragFunc) {
    // (a) Coverage mask: rasterize the stashed surface draws (position-only,
    // per-rep clip applied) into the R8 mask, cleared to 0.
    MTLRenderPassDescriptor* cpd = [MTLRenderPassDescriptor renderPassDescriptor];
    cpd.colorAttachments[0].texture = _surfaceCoverageTex;
    cpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    cpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    cpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> ce =
        [_cmdBuffer renderCommandEncoderWithDescriptor:cpd];
    for (const auto& cd : _coverageDraws) {
      if (!_coveragePipeline || _coverageStride != cd.stride) {
        MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
        vd.attributes[0].format = MTLVertexFormatFloat3;
        vd.attributes[0].offset = (NSUInteger)(cd.posOffset < 0 ? 0 : cd.posOffset);
        vd.attributes[0].bufferIndex = 0;
        vd.layouts[0].stride = (NSUInteger)cd.stride;
        vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        MTLRenderPipelineDescriptor* pd2 = [[MTLRenderPipelineDescriptor alloc] init];
        pd2.vertexFunction = _coverageVtxFunc;
        pd2.fragmentFunction = _coverageFragFunc;
        pd2.vertexDescriptor = vd;
        pd2.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
        pd2.rasterSampleCount = 1;
        NSError* pe = nil;
        [_coveragePipeline release];  // MRC: release the previous-stride pipeline
        _coveragePipeline = [_device newRenderPipelineStateWithDescriptor:pd2 error:&pe];
        _coverageStride = cd.stride;
        if (!_coveragePipeline)
          NSLog(@"RendererMetal: coverage pipeline failed: %@", pe);
        [vd release]; [pd2 release];  // MRC: consumed by pipeline creation
      }
      if (!_coveragePipeline) continue;
      [ce setRenderPipelineState:_coveragePipeline];
      [ce setCullMode:MTLCullModeNone];
      [ce setVertexBuffer:cd.vbo offset:0 atIndex:0];
      struct { float modelview[16]; float projection[16]; float pointSize; float pad[3]; } cu;
      std::memcpy(cu.modelview, cd.modelview, 64);
      std::memcpy(cu.projection, cd.projection, 64);
      cu.pointSize = 1.0f; cu.pad[0] = cu.pad[1] = cu.pad[2] = 0.0f;
      [ce setVertexBytes:&cu length:sizeof(cu) atIndex:1];
      // Coverage mask is intentionally CLIP-AGNOSTIC for the per-rep clip: the
      // outer contour must trace the surface's true outer silhouette, not the
      // per-rep "peek inside" clip cross-section. Feeding cd.clipFront/Back here
      // discards the clipped fragments, so the clip cut edge would enter the
      // mask boundary and get outlined (the reported bug). Bind a disabled clip
      // (enabled=0) so the mask is the full surface footprint. The GLOBAL slab
      // still applies (it rides in cd.projection, shared with the live draw), and
      // the visible clipped surface + its interior cap are drawn by separate
      // passes that keep the per-rep clip — only the contour changes.
      { struct { float front, back, enabled, pad; } _cl = { -1.0f, 1e6f, 0.0f, 0.0f };
        [ce setFragmentBytes:&_cl length:sizeof(_cl) atIndex:1]; }
      if (cd.ibo) {
        [ce drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                       indexCount:(NSUInteger)cd.count
                        indexType:MTLIndexTypeUInt32
                      indexBuffer:cd.ibo
                indexBufferOffset:0];
      } else {
        [ce drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:(NSUInteger)cd.count];
      }
    }
    [ce endEncoding];

    // (b) Outline the coverage boundary over the scene color.
    id<MTLTexture> dst = (sceneSrc == _sceneColor) ? _postColor : _sceneColor;
    struct { float invW, invH, thickness, colR, colG, colB, colA, _pad; } u;
    u.invW = (_rtW > 0) ? 1.0f / (float)_rtW : 0.0f;
    u.invH = (_rtH > 0) ? 1.0f / (float)_rtH : 0.0f;
    float halfW = _contourWidth * 0.5f;
    u.thickness = (halfW < 0.5f ? 0.5f : halfW) * pixelRadiusScale();
    u.colR = _contourColor[0]; u.colG = _contourColor[1];
    u.colB = _contourColor[2]; u.colA = _contourColor[3];
    u._pad = 0.0f;
    MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = dst;
    pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> ec =
        [_cmdBuffer renderCommandEncoderWithDescriptor:pd];
    [ec setRenderPipelineState:_surfaceContourPipeline];
    [ec setFragmentTexture:sceneSrc atIndex:0];
    [ec setFragmentTexture:_surfaceCoverageTex atIndex:1];
    [ec setFragmentSamplerState:_postSampler atIndex:0];
    [ec setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [ec drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [ec endEncoding];
    sceneSrc = dst;
  }

  // Pass 3.5: exposure + (optional) filmic tone-map. Runs after OIT/outline but
  // BEFORE the final FXAA/blit (FXAA's luma math assumes display values). Placed
  // ahead of the !_offscreen block so the offscreen PNG capture (which reads
  // sceneSrc directly) is processed identically to the live view. Exposure is
  // independent of the tone-map toggle, so the pass also runs when exposure != 1.
  bool exposureActive = (_exposure < 0.999f || _exposure > 1.001f);
  if ((_tonemapEnabled || exposureActive) && _tonemapPipeline) {
    id<MTLTexture> dst = (sceneSrc == _sceneColor) ? _postColor : _sceneColor;
    struct { float exposure; float tonemap; float _p0, _p1; } u;
    u.exposure = _exposure;
    u.tonemap = _tonemapEnabled ? 1.0f : 0.0f;
    u._p0 = u._p1 = 0.0f;
    MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = dst;
    pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> et =
        [_cmdBuffer renderCommandEncoderWithDescriptor:pd];
    [et setRenderPipelineState:_tonemapPipeline];
    [et setFragmentTexture:sceneSrc atIndex:0];
    [et setFragmentSamplerState:_postSampler atIndex:0];
    [et setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [et drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [et endEncoding];
    sceneSrc = dst;
  }

  // Transparent-export alpha (offscreen only). When a transparent background was
  // requested (ray_opaque_background 0 -> clear alpha 0), rewrite the captured
  // alpha from scene depth so the background is cut out while geometry stays
  // opaque. The post passes above all emit alpha=1, so this restores a usable
  // matte regardless of which of them ran. Live rendering (to a drawable) never
  // takes this path — its layer is opaque.
  if (_offscreen && _clearA < 0.5f && _exportAlphaPipeline && _sceneDepth) {
    id<MTLTexture> dst = (sceneSrc == _sceneColor) ? _postColor : _sceneColor;
    MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = dst;
    pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> ea =
        [_cmdBuffer renderCommandEncoderWithDescriptor:pd];
    [ea setRenderPipelineState:_exportAlphaPipeline];
    [ea setFragmentTexture:sceneSrc atIndex:0];
    [ea setFragmentTexture:_sceneDepth atIndex:1];
    [ea setFragmentTexture:_oitReveal atIndex:2];  // recover transparent (surface) coverage
    [ea setFragmentSamplerState:_postSampler atIndex:0];
    [ea drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [ea endEncoding];
    sceneSrc = dst;
  }

  // Final pass → drawable: FXAA if available, else a 1:1 blit.
  // PYMOL_NO_AA forces the blit (A/B testing + user escape hatch).
  // Skipped entirely in offscreen mode — there is no drawable; the post chain
  // output in sceneSrc feeds the PNG capture below directly. FXAA still ran as
  // a ping-pong pass above if enabled, so the captured image is anti-aliased.
  if (!_offscreen) {
    _screenPassDesc.depthAttachment.texture = nil;
    _screenPassDesc.stencilAttachment.texture = nil;
    _screenPassDesc.colorAttachments[0].loadAction = MTLLoadActionDontCare;

    // Stage-1 debug: blit the raw shadow depth map to the drawable instead of
    // the scene, so we can eyeball the light-POV depth. Env-gated; removed in S2.
    static bool shadowDebug = getenv("PYMOL_SHADOW_DEBUG") != nullptr;
    if (shadowDebug && _shadowDebugPipeline && _shadowDepth) {
      id<MTLRenderCommandEncoder> dbg =
          [_cmdBuffer renderCommandEncoderWithDescriptor:_screenPassDesc];
      [dbg setRenderPipelineState:_shadowDebugPipeline];
      [dbg setFragmentTexture:_shadowDepth atIndex:1];
      [dbg setFragmentSamplerState:_postSampler atIndex:0];
      [dbg drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [dbg endEncoding];
      return;
    }

    // Reduced-resolution present (metal_upscale): upscale sceneSrc (rendered at
    // _renderScale) to the native drawable. Prefer the MetalFX spatial scaler
    // (sharp, recovers edge detail); fall back to the FXAA/blit pass (bilinear)
    // when MetalFX is unavailable or the scaler couldn't be created. When upscale
    // is off (_renderScale==1, the default) doUpscale is false and this is the
    // unchanged final-blit path.
    id<MTLTexture> drawTex = _drawable ? _drawable.texture : nil;
    bool doUpscale = (_upscaleEnabled && _renderScale < 0.999f && sceneSrc && drawTex);
    if (doUpscale)
      ensureUpscaler(sceneSrc.width, sceneSrc.height, drawTex.width, drawTex.height);
#if !TARGET_OS_SIMULATOR
    if (doUpscale && _upscaler) {
      if (@available(macOS 13.0, iOS 16.0, *)) {
        id<MTLFXSpatialScaler> sc = (id<MTLFXSpatialScaler>)_upscaler;
        sc.colorTexture = sceneSrc;
        sc.outputTexture = drawTex;
        [sc encodeToCommandBuffer:_cmdBuffer];  // NOT a render-encoder pass
      }
    } else
#endif  // !TARGET_OS_SIMULATOR — sim has no MetalFX; always takes the blit path
    {
      id<MTLRenderPipelineState> finalPipe =
          (_fxaaPipeline && _aaEnabled && !noAA) ? _fxaaPipeline : _blitPipeline;
      id<MTLRenderCommandEncoder> enc =
          [_cmdBuffer renderCommandEncoderWithDescriptor:_screenPassDesc];
      [enc setRenderPipelineState:finalPipe];
      [enc setFragmentTexture:sceneSrc atIndex:0];
      [enc setFragmentSamplerState:_postSampler atIndex:0];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [enc endEncoding];
    }
  }

  // Pending rendered-frame PNG capture (png ray=0): copy the final
  // post-processed color into a CPU-readable texture and write the PNG once the
  // GPU completes. Captures at the current render resolution.
  if (!_capturePath.empty() && sceneSrc) {
    NSUInteger cw = sceneSrc.width, ch = sceneSrc.height;
    // Allocate a FRESH staging texture per capture (not a shared ivar): two
    // captures a frame or two apart would otherwise blit into the same texture
    // while the prior completion handler is still reading it off the GPU thread
    // — a data race producing a torn/garbled PNG.
    MTLTextureDescriptor* d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:cw height:ch mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> capTex = [_device newTextureWithDescriptor:d];  // +1 (owned here)
    id<MTLBlitCommandEncoder> be = [_cmdBuffer blitCommandEncoder];
    [be copyFromTexture:sceneSrc sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(cw, ch, 1)
              toTexture:capTex destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
    [be endEncoding];
    std::string path = _capturePath;
    _capturePath.clear();
    [_cmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
      rtWriteTextureToPNG(capTex, path);
    }];
    // MRC: the copied handler block retained capTex and releases it when the
    // block is destroyed (after it runs), so drop our +1 now — the texture stays
    // alive for exactly this capture's handler and is then freed once.
    [capTex release];
  }
}

id<MTLDepthStencilState> RendererMetal::oitDepthState()
{
  // Transparent/OIT draws: depth-test vs opaque (LessEqual), never write depth.
  // Identical for every transparent draw, so build once and cache (MRC: +1,
  // released in the destructor).
  if (!_oitDepthState) {
    MTLDepthStencilDescriptor* dsd = [[MTLDepthStencilDescriptor alloc] init];
    dsd.depthCompareFunction = MTLCompareFunctionLessEqual;
    dsd.depthWriteEnabled = NO;
    _oitDepthState = [_device newDepthStencilStateWithDescriptor:dsd];
    [dsd release];
  }
  return _oitDepthState;
}

id<MTLDepthStencilState> RendererMetal::bezierDepthState()
{
  // Opaque bezier-tube draws: standard LessEqual + depth write. Cached once
  // (MRC: +1, released in the destructor).
  if (!_bezierDepthState) {
    MTLDepthStencilDescriptor* dsd = [[MTLDepthStencilDescriptor alloc] init];
    dsd.depthCompareFunction = MTLCompareFunctionLessEqual;
    dsd.depthWriteEnabled = YES;
    _bezierDepthState = [_device newDepthStencilStateWithDescriptor:dsd];
    [dsd release];
  }
  return _bezierDepthState;
}

void RendererMetal::beginTransparentOIT()
{
  // OIT requires its targets + pipelines; if any are missing, leave the scene
  // encoder active so transparent draws fall back to normal blending.
  if (!_cmdBuffer || !_oitPassDesc || !_vboOitPipelineUByte ||
      !_oitResolvePipeline)
    return;
  if (_encoder) { [_encoder endEncoding]; _encoder = nil; }

  _passDesc = _oitPassDesc;
  _encoder = [_cmdBuffer renderCommandEncoderWithDescriptor:_oitPassDesc];
  if (!_encoder) { _passDesc = _scenePassDesc; return; }
  [_encoder setViewport:_viewport];
  // Depth-test against opaque depth (LEQUAL), but DO NOT write depth, so
  // transparent fragments occlude/are-occluded by opaque geometry yet never
  // hide each other.
  [_encoder setDepthStencilState:oitDepthState()];
  [_encoder setCullMode:MTLCullModeNone];
  _oitActive = true;
  _oitHasContent = true;
}

void RendererMetal::endTransparentOIT()
{
  if (!_oitActive) return;
  if (_encoder) { [_encoder endEncoding]; _encoder = nil; }
  _oitActive = false;

  // Resume rendering into the scene color (LOAD, don't clear) so any
  // post-transparent draws (e.g. selection indicators) land on the opaque
  // image. The OIT resolve runs later in runPostChain.
  _passDesc = _scenePassDesc;
  _scenePassDesc.colorAttachments[0].loadAction = MTLLoadActionLoad;
  _scenePassDesc.depthAttachment.loadAction = MTLLoadActionLoad;
  _scenePassDesc.stencilAttachment.loadAction = MTLLoadActionLoad;
  _encoder = [_cmdBuffer renderCommandEncoderWithDescriptor:_scenePassDesc];
  if (_encoder) {
    [_encoder setViewport:_viewport];
    _depthTestEnabled = true;
    _depthWriteEnabled = true;
    _depthStencilDirty = true;
    applyDepthStencilState();
    [_encoder setCullMode:_cullFaceEnabled ? MTLCullModeBack : MTLCullModeNone];
  }
}

void RendererMetal::setLightViewProjEye(const float* m)
{
  if (m) std::memcpy(_lightViewProjEye, m, 16 * sizeof(float));
}

void RendererMetal::beginShadowPass()
{
  if (!_cmdBuffer || !_shadowPassDesc || !_vboShadowPipelineUByte) return;
  buildShadowPipelines();  // no-op if already built
  // End the scene encoder opened by beginFrame (it has only the pending clear;
  // no opaque geometry has drawn yet). Switch to the light-POV depth pass.
  if (_encoder) { [_encoder endEncoding]; _encoder = nil; }
  _passDesc = _shadowPassDesc;
  _shadowPassDesc.depthAttachment.loadAction = MTLLoadActionClear;
  _encoder = [_cmdBuffer renderCommandEncoderWithDescriptor:_shadowPassDesc];
  if (!_encoder) { _passDesc = _scenePassDesc; return; }
  MTLViewport vp = {0.0, 0.0, (double)kShadowDim, (double)kShadowDim, 0.0, 1.0};
  [_encoder setViewport:vp];
  if (!_shadowDepthState) {
    MTLDepthStencilDescriptor* d = [[MTLDepthStencilDescriptor alloc] init];
    d.depthCompareFunction = MTLCompareFunctionLess;
    d.depthWriteEnabled = YES;
    _shadowDepthState = [_device newDepthStencilStateWithDescriptor:d];
    [d release];  // MRC: descriptor (+1) consumed by state creation
  }
  [_encoder setDepthStencilState:_shadowDepthState];
  [_encoder setCullMode:MTLCullModeNone];
  _shadowMode = true;
}

void RendererMetal::endShadowPass()
{
  if (!_shadowMode) return;
  if (_encoder) { [_encoder endEncoding]; _encoder = nil; }
  _shadowMode = false;
  // Re-open the scene pass with a fresh CLEAR — the shadow pre-pass runs BEFORE
  // the opaque loop, so the scene starts empty (mirrors beginFrame's clear; the
  // earlier beginFrame encoder we ended above did a redundant, harmless clear).
  _passDesc = _scenePassDesc;
  _scenePassDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
  _scenePassDesc.colorAttachments[0].clearColor =
      MTLClearColorMake(_clearR, _clearG, _clearB, _clearA);
  _scenePassDesc.depthAttachment.loadAction = MTLLoadActionClear;
  _scenePassDesc.depthAttachment.clearDepth = 1.0;
  _scenePassDesc.stencilAttachment.loadAction = MTLLoadActionClear;
  _scenePassDesc.stencilAttachment.clearStencil = 0;
  _encoder = [_cmdBuffer renderCommandEncoderWithDescriptor:_scenePassDesc];
  if (_encoder) {
    [_encoder setViewport:_viewport];
    _depthTestEnabled = true;
    _depthWriteEnabled = true;
    _depthStencilDirty = true;
    applyDepthStencilState();
    [_encoder setCullMode:_cullFaceEnabled ? MTLCullModeBack : MTLCullModeNone];
  }
}

// ---------------------------------------------------------------------------
#pragma mark - Viewport and clear
// ---------------------------------------------------------------------------

void RendererMetal::viewport(int x, int y, int w, int h)
{
  // Scale incoming (native backing-pixel) rects to the reduced render resolution
  // when metal_upscale is on (matches the _renderScale-sized targets). s==1 (the
  // default) leaves coordinates unchanged. Aspect is preserved (uniform scale),
  // so the projection matrix from SceneRender still matches.
  const double s = _renderScale;
  const double vx = x * s, vy = y * s, vw = w * s, vh = h * s;
  _viewport = {vx, vy, vw, vh, 0.0, 1.0};

  // Also update scissor to match if scissor is not explicitly set
  _scissorRect = {
      static_cast<NSUInteger>(llround(vx)), static_cast<NSUInteger>(llround(vy)),
      static_cast<NSUInteger>(llround(vw)), static_cast<NSUInteger>(llround(vh))};

  if (_encoder) {
    [_encoder setViewport:_viewport];
    if (!_scissorEnabled) {
      [_encoder setScissorRect:_scissorRect];
    }
  }
}

bool RendererMetal::getViewportRect(int& x, int& y, int& w, int& h) const
{
  x = static_cast<int>(_viewport.originX);
  y = static_cast<int>(_viewport.originY);
  w = static_cast<int>(_viewport.width);
  h = static_cast<int>(_viewport.height);
  return true;
}

void RendererMetal::clear(bool color, bool depth, bool stencil)
{
  // In Metal, clears happen via the render pass descriptor's load actions.
  // If we already have an encoder, we need to end it and start a new pass.
  if (_encoder) {
    [_encoder endEncoding];
    _encoder = nil;
  }

  if (_passDesc) {
    if (color) {
      _passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
      _passDesc.colorAttachments[0].clearColor =
          MTLClearColorMake(_clearR, _clearG, _clearB, _clearA);
    } else {
      _passDesc.colorAttachments[0].loadAction = MTLLoadActionLoad;
    }

    if (depth) {
      _passDesc.depthAttachment.loadAction = MTLLoadActionClear;
      _passDesc.depthAttachment.clearDepth = 1.0;
    } else {
      _passDesc.depthAttachment.loadAction = MTLLoadActionLoad;
    }

    if (stencil) {
      _passDesc.stencilAttachment.loadAction = MTLLoadActionClear;
      _passDesc.stencilAttachment.clearStencil = 0;
    } else {
      _passDesc.stencilAttachment.loadAction = MTLLoadActionLoad;
    }
  }

  // The next ensureEncoder() call will create a new encoder with these
  // load actions, effectively performing the clear.
}

void RendererMetal::clearColor(float r, float g, float b, float a)
{
  _clearR = r;
  _clearG = g;
  _clearB = b;
  _clearA = a;
}

void RendererMetal::scissor(int x, int y, int w, int h)
{
  const double s = _renderScale;  // match the reduced render resolution (s==1 default)
  _scissorRect = {
      static_cast<NSUInteger>(llround(x * s)), static_cast<NSUInteger>(llround(y * s)),
      static_cast<NSUInteger>(llround(w * s)), static_cast<NSUInteger>(llround(h * s))};

  if (_encoder && _scissorEnabled) {
    [_encoder setScissorRect:_scissorRect];
  }
}

// ---------------------------------------------------------------------------
#pragma mark - State management
// ---------------------------------------------------------------------------

void RendererMetal::enable(Capability cap)
{
  switch (cap) {
  case Capability::DepthTest:
    _depthTestEnabled = true;
    _depthStencilDirty = true;
    applyDepthStencilState();
    break;
  case Capability::Blend:
    _blendEnabled = true;
    // Blend is baked into pipeline state — will apply on next draw
    break;
  case Capability::CullFace:
    _cullFaceEnabled = true;
    if (_encoder)
      [_encoder setCullMode:MTLCullModeBack];
    break;
  case Capability::ScissorTest:
    _scissorEnabled = true;
    if (_encoder)
      [_encoder setScissorRect:_scissorRect];
    break;
  case Capability::StencilTest:
    _stencilTestEnabled = true;
    break;
  case Capability::Lighting:
    _lightingEnabled = true;
    break;
  case Capability::Fog:
    _fogEnabled = true;
    break;
  // These have no direct Metal equivalent — tracked as flags for shaders
  case Capability::LineSmooth:
  case Capability::Normalize:
  case Capability::ColorMaterial:
  case Capability::AlphaTest:
  case Capability::PolygonOffset:
  case Capability::Texture2D:
    break;
  }
}

void RendererMetal::disable(Capability cap)
{
  switch (cap) {
  case Capability::DepthTest:
    _depthTestEnabled = false;
    _depthStencilDirty = true;
    applyDepthStencilState();
    break;
  case Capability::Blend:
    _blendEnabled = false;
    break;
  case Capability::CullFace:
    _cullFaceEnabled = false;
    if (_encoder)
      [_encoder setCullMode:MTLCullModeNone];
    break;
  case Capability::ScissorTest:
    _scissorEnabled = false;
    // Reset scissor to viewport
    if (_encoder) {
      MTLScissorRect fullRect = {
          static_cast<NSUInteger>(_viewport.originX),
          static_cast<NSUInteger>(_viewport.originY),
          static_cast<NSUInteger>(_viewport.width),
          static_cast<NSUInteger>(_viewport.height)};
      [_encoder setScissorRect:fullRect];
    }
    break;
  case Capability::StencilTest:
    _stencilTestEnabled = false;
    break;
  case Capability::Lighting:
    _lightingEnabled = false;
    break;
  case Capability::Fog:
    _fogEnabled = false;
    break;
  case Capability::LineSmooth:
  case Capability::Normalize:
  case Capability::ColorMaterial:
  case Capability::AlphaTest:
  case Capability::PolygonOffset:
  case Capability::Texture2D:
    break;
  }
}

void RendererMetal::blendFunc(BlendFunc src, BlendFunc dst)
{
  _blendSrcFactor = toMTLBlend(src);
  _blendDstFactor = toMTLBlend(dst);
}

void RendererMetal::depthFunc(DepthFunc func)
{
  _depthCompareFunc = toMTLCompare(func);
  _depthStencilDirty = true;
  applyDepthStencilState();
}

void RendererMetal::depthMask(bool write)
{
  _depthWriteEnabled = write;
  _depthStencilDirty = true;
  applyDepthStencilState();
}

void RendererMetal::colorMask(bool r, bool g, bool b, bool a)
{
  _colorWriteMask = MTLColorWriteMaskNone;
  if (r) _colorWriteMask |= MTLColorWriteMaskRed;
  if (g) _colorWriteMask |= MTLColorWriteMaskGreen;
  if (b) _colorWriteMask |= MTLColorWriteMaskBlue;
  if (a) _colorWriteMask |= MTLColorWriteMaskAlpha;
  // Color mask is baked into pipeline state
}

void RendererMetal::lineWidth(float w)
{
  _lineWidth = w;
  // Metal does not support variable line width — tracked for compatibility
}

void RendererMetal::pointSize(float s)
{
  _pointSize = s;
  // Point size is set via vertex shader in Metal
}

// ---------------------------------------------------------------------------
#pragma mark - Drawing
// ---------------------------------------------------------------------------

void RendererMetal::drawArrays(PrimitiveType mode, int first, int count)
{
  ensureEncoder();
  if (!_encoder) return;

  // Bind the current array buffer at index 0 if one is bound
  auto it = _buffers.find(_boundArrayBuffer);
  if (it != _buffers.end()) {
    [_encoder setVertexBuffer:it->second offset:0 atIndex:0];
  }

  // Set current pipeline if available
  if (_currentPipeline) {
    [_encoder setRenderPipelineState:_currentPipeline];
  }

  [_encoder drawPrimitives:toMTL(mode)
               vertexStart:static_cast<NSUInteger>(first)
               vertexCount:static_cast<NSUInteger>(count)];
}

void RendererMetal::drawElements(
    PrimitiveType mode, int count, const void* indices)
{
  ensureEncoder();
  if (!_encoder) return;

  // Bind vertex buffer
  auto vit = _buffers.find(_boundArrayBuffer);
  if (vit != _buffers.end()) {
    [_encoder setVertexBuffer:vit->second offset:0 atIndex:0];
  }

  if (_currentPipeline) {
    [_encoder setRenderPipelineState:_currentPipeline];
  }

  // If an element array buffer is bound, use it
  auto eit = _buffers.find(_boundElementBuffer);
  if (eit != _buffers.end()) {
    [_encoder drawIndexedPrimitives:toMTL(mode)
                         indexCount:static_cast<NSUInteger>(count)
                          indexType:MTLIndexTypeUInt32
                        indexBuffer:eit->second
                  indexBufferOffset:0];
  } else if (indices) {
    // Create a temporary index buffer from the provided pointer
    NSUInteger byteSize =
        static_cast<NSUInteger>(count) * sizeof(uint32_t);
    id<MTLBuffer> tmpIdx =
        [_device newBufferWithBytes:indices
                             length:byteSize
                            options:MTLResourceStorageModeShared];
    [_encoder drawIndexedPrimitives:toMTL(mode)
                         indexCount:static_cast<NSUInteger>(count)
                          indexType:MTLIndexTypeUInt32
                        indexBuffer:tmpIdx
                  indexBufferOffset:0];
    // MRC: the encoder retains the buffer until the command buffer completes, so
    // this +1 transient can be released now (no caching for this client path).
    [tmpIdx release];
  }
}

// ---------------------------------------------------------------------------
#pragma mark - Buffers
// ---------------------------------------------------------------------------

uint32_t RendererMetal::createBuffer()
{
  uint32_t id = _nextBufferId++;
  // No Metal buffer allocated yet — created on bufferData()
  return id;
}

void RendererMetal::deleteBuffer(uint32_t id)
{
  _buffers.erase(id);
  if (_boundArrayBuffer == id) _boundArrayBuffer = 0;
  if (_boundElementBuffer == id) _boundElementBuffer = 0;
}

void RendererMetal::bindBuffer(BufferTarget target, uint32_t id)
{
  switch (target) {
  case BufferTarget::Array:
    _boundArrayBuffer = id;
    break;
  case BufferTarget::ElementArray:
    _boundElementBuffer = id;
    break;
  }
}

void RendererMetal::bufferData(
    BufferTarget target, size_t size, const void* data, BufferUsage /*usage*/)
{
  uint32_t boundId = (target == BufferTarget::Array) ? _boundArrayBuffer
                                                     : _boundElementBuffer;
  if (boundId == 0 || size == 0) return;

  id<MTLBuffer> mtlBuf;
  if (data) {
    mtlBuf = [_device newBufferWithBytes:data
                                  length:size
                                 options:MTLResourceStorageModeShared];
  } else {
    mtlBuf = [_device newBufferWithLength:size
                                  options:MTLResourceStorageModeShared];
  }

  _buffers[boundId] = mtlBuf;
}

// ---------------------------------------------------------------------------
#pragma mark - Vertex attributes
// ---------------------------------------------------------------------------

void RendererMetal::vertexAttribPointer(
    int index, int size, int type, bool normalized, int stride,
    const void* offset)
{
  if (index < 0 || index >= kMaxVertexAttribs) return;

  auto& attr = _vertexAttribs[index];
  attr.size = size;
  attr.type = type;
  attr.normalized = normalized;
  attr.stride = stride;
  attr.offset = reinterpret_cast<uintptr_t>(offset);
}

void RendererMetal::enableVertexAttribArray(int index)
{
  if (index >= 0 && index < kMaxVertexAttribs) {
    _vertexAttribs[index].enabled = true;
  }
}

void RendererMetal::disableVertexAttribArray(int index)
{
  if (index >= 0 && index < kMaxVertexAttribs) {
    _vertexAttribs[index].enabled = false;
  }
}

// ---------------------------------------------------------------------------
#pragma mark - Shaders / Programs
// ---------------------------------------------------------------------------

void RendererMetal::useProgram(uint32_t programId)
{
  _currentProgram = programId;
  // Pipeline state lookup will be done by ShaderMgr or a future pipeline
  // cache that maps programId → MTLRenderPipelineState.
}

void RendererMetal::setUniform1i(int location, int v)
{
  if (location < 0 || location >= kMaxUniforms) return;
  _uniformData[location * 4] = static_cast<float>(v);
}

void RendererMetal::setUniform1f(int location, float v)
{
  if (location < 0 || location >= kMaxUniforms) return;
  _uniformData[location * 4] = v;
}

void RendererMetal::setUniform2f(int location, float v0, float v1)
{
  if (location < 0 || location >= kMaxUniforms) return;
  _uniformData[location * 4 + 0] = v0;
  _uniformData[location * 4 + 1] = v1;
}

void RendererMetal::setUniform3f(
    int location, float v0, float v1, float v2)
{
  if (location < 0 || location >= kMaxUniforms) return;
  _uniformData[location * 4 + 0] = v0;
  _uniformData[location * 4 + 1] = v1;
  _uniformData[location * 4 + 2] = v2;
}

void RendererMetal::setUniform4f(
    int location, float v0, float v1, float v2, float v3)
{
  if (location < 0 || location >= kMaxUniforms) return;
  _uniformData[location * 4 + 0] = v0;
  _uniformData[location * 4 + 1] = v1;
  _uniformData[location * 4 + 2] = v2;
  _uniformData[location * 4 + 3] = v3;
}

void RendererMetal::setUniformMatrix4fv(int location, const float* value)
{
  if (location < 0 || !value) return;
  // Store 16 floats starting at this location's slot
  // Each location occupies 4 float slots, a 4x4 matrix needs 4 locations
  if (location + 3 >= kMaxUniforms) return;
  std::memcpy(&_uniformData[location * 4], value, 16 * sizeof(float));
}

void RendererMetal::setUniformMatrix3fv(int location, const float* value)
{
  if (location < 0 || !value) return;
  // 3x3 matrix = 9 floats, stored in 3 vec4 slots (padded)
  if (location + 2 >= kMaxUniforms) return;
  for (int col = 0; col < 3; ++col) {
    _uniformData[(location + col) * 4 + 0] = value[col * 3 + 0];
    _uniformData[(location + col) * 4 + 1] = value[col * 3 + 1];
    _uniformData[(location + col) * 4 + 2] = value[col * 3 + 2];
    _uniformData[(location + col) * 4 + 3] = 0.0f;
  }
}

// ---------------------------------------------------------------------------
#pragma mark - Textures
// ---------------------------------------------------------------------------

uint32_t RendererMetal::createTexture()
{
  uint32_t id = _nextTextureId++;
  // Texture is allocated on first texImage call (not part of Renderer yet)
  return id;
}

void RendererMetal::deleteTexture(uint32_t id)
{
  _textures.erase(id);
  if (_boundTexture == id) _boundTexture = 0;
}

void RendererMetal::bindTexture(TextureTarget /*target*/, uint32_t id)
{
  _boundTexture = id;
}

void RendererMetal::activeTexture(int unit)
{
  _activeTextureUnit = unit;
}

void RendererMetal::texParameteri(
    TextureTarget /*target*/, int /*pname*/, int /*param*/)
{
  // Texture parameters are set via MTLSamplerDescriptor in Metal.
  // Will be handled when we build the sampler state cache.
}

// ---------------------------------------------------------------------------
#pragma mark - Framebuffers
// ---------------------------------------------------------------------------

uint32_t RendererMetal::createFramebuffer()
{
  uint32_t id = _nextFBOId++;
  // Actual textures created when attachments are configured
  return id;
}

void RendererMetal::deleteFramebuffer(uint32_t id)
{
  _fbColorAttachments.erase(id);
  _fbDepthAttachments.erase(id);
  if (_boundFBO == id) _boundFBO = 0;
}

void RendererMetal::bindFramebuffer(uint32_t id)
{
  _boundFBO = id;

  // When binding a non-default FBO, we need to end the current encoder
  // and start a new render pass targeting the FBO's textures.
  if (id != 0 && _encoder) {
    [_encoder endEncoding];
    _encoder = nil;
  }

  // For FBO 0, the pass descriptor points to the drawable (default).
  // For custom FBOs, we'd configure _passDesc to point to their textures.
  // Full implementation deferred to framebuffer attachment methods.
}

// ---------------------------------------------------------------------------
#pragma mark - Matrix stack
// ---------------------------------------------------------------------------

void RendererMetal::matrixMode(int mode)
{
  // GL_MODELVIEW = 0x1700, GL_PROJECTION = 0x1701
  _matrixMode = (mode == 0x1701) ? 1 : 0;
}

void RendererMetal::loadIdentity()
{
  if (_matrixMode == 0) {
    _modelviewMatrix = identityMatrix();
  } else {
    _projectionMatrix = identityMatrix();
  }
}

void RendererMetal::loadMatrixf(const float* m)
{
  if (!m) return;
  Mat4& mat = (_matrixMode == 0) ? _modelviewMatrix : _projectionMatrix;
  std::memcpy(mat.data(), m, 16 * sizeof(float));
  if (_matrixMode == 0) {
    // Keep the inverse modelview current for ray tracing (eye → model space).
    // Column-major layout matches simd_float4x4.
    simd_float4x4 mv;
    std::memcpy(&mv, _modelviewMatrix.data(), 16 * sizeof(float));
    simd_float4x4 inv = simd_inverse(mv);
    std::memcpy(_modelviewInv.data(), &inv, 16 * sizeof(float));
  }
}

void RendererMetal::pushMatrix()
{
  if (_matrixMode == 0) {
    _modelviewStack.push(_modelviewMatrix);
  } else {
    _projectionStack.push(_projectionMatrix);
  }
}

void RendererMetal::popMatrix()
{
  if (_matrixMode == 0) {
    if (!_modelviewStack.empty()) {
      _modelviewMatrix = _modelviewStack.top();
      _modelviewStack.pop();
    }
  } else {
    if (!_projectionStack.empty()) {
      _projectionMatrix = _projectionStack.top();
      _projectionStack.pop();
    }
  }
}

void RendererMetal::translatef(float x, float y, float z)
{
  Mat4& mat = (_matrixMode == 0) ? _modelviewMatrix : _projectionMatrix;
  mat = multiplyMatrices(mat, translationMatrix(x, y, z));
}

void RendererMetal::scalef(float x, float y, float z)
{
  Mat4& mat = (_matrixMode == 0) ? _modelviewMatrix : _projectionMatrix;
  mat = multiplyMatrices(mat, scaleMatrix(x, y, z));
}

void RendererMetal::multMatrixf(const float* m)
{
  if (!m) return;
  Mat4& mat = (_matrixMode == 0) ? _modelviewMatrix : _projectionMatrix;
  Mat4 other;
  std::memcpy(other.data(), m, 16 * sizeof(float));
  mat = multiplyMatrices(mat, other);
}

// ---------------------------------------------------------------------------
#pragma mark - Batch system (immediate mode replacement)
// ---------------------------------------------------------------------------

void RendererMetal::beginBatch(PrimitiveType mode)
{
  _batchMode = mode;
  _batchVertices.clear();
}

void RendererMetal::batchVertex3f(float x, float y, float z)
{
  _batchVertices.push_back(
      {x, y, z, _curR, _curG, _curB, _curA, _curNX, _curNY, _curNZ});
}

void RendererMetal::batchVertex3fv(const float* v)
{
  batchVertex3f(v[0], v[1], v[2]);
}

void RendererMetal::batchVertex2f(float x, float y)
{
  batchVertex3f(x, y, 0.0f);
}

void RendererMetal::batchVertex2i(int x, int y)
{
  batchVertex3f(static_cast<float>(x), static_cast<float>(y), 0.0f);
}

void RendererMetal::batchColor3f(float r, float g, float b)
{
  _curR = r;
  _curG = g;
  _curB = b;
  _curA = 1.0f;
}

void RendererMetal::batchColor3fv(const float* c)
{
  batchColor3f(c[0], c[1], c[2]);
}

void RendererMetal::batchColor4f(float r, float g, float b, float a)
{
  _curR = r;
  _curG = g;
  _curB = b;
  _curA = a;
}

void RendererMetal::batchColor4fv(const float* c)
{
  batchColor4f(c[0], c[1], c[2], c[3]);
}

void RendererMetal::batchColor4ub(
    unsigned char r, unsigned char g, unsigned char b, unsigned char a)
{
  batchColor4f(r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f);
}

void RendererMetal::batchNormal3fv(const float* n)
{
  _curNX = n[0];
  _curNY = n[1];
  _curNZ = n[2];
}

void RendererMetal::endBatch()
{
  if (_batchVertices.empty()) return;

  ensureEncoder();
  if (!_encoder || !_batchPipeline) return;

  // Handle triangle fan conversion: fan vertices [0,1,2,3,...,N] become
  // triangles [0,1,2], [0,2,3], [0,3,4], ..., [0,N-1,N]
  std::vector<BatchVertex>* drawVertices = &_batchVertices;
  std::vector<BatchVertex> converted;

  if (_batchMode == PrimitiveType::TriangleFan &&
      _batchVertices.size() >= 3) {
    converted.reserve((_batchVertices.size() - 2) * 3);
    for (size_t i = 1; i + 1 < _batchVertices.size(); ++i) {
      converted.push_back(_batchVertices[0]);
      converted.push_back(_batchVertices[i]);
      converted.push_back(_batchVertices[i + 1]);
    }
    drawVertices = &converted;
  } else if (_batchMode == PrimitiveType::Quads &&
             _batchVertices.size() >= 4) {
    // Convert quads to triangles: [0,1,2,3] → [0,1,2], [0,2,3]
    converted.reserve((_batchVertices.size() / 4) * 6);
    for (size_t i = 0; i + 3 < _batchVertices.size(); i += 4) {
      converted.push_back(_batchVertices[i + 0]);
      converted.push_back(_batchVertices[i + 1]);
      converted.push_back(_batchVertices[i + 2]);
      converted.push_back(_batchVertices[i + 0]);
      converted.push_back(_batchVertices[i + 2]);
      converted.push_back(_batchVertices[i + 3]);
    }
    drawVertices = &converted;
  }

  NSUInteger byteSize = drawVertices->size() * sizeof(BatchVertex);
  // Reuse a shared batch buffer, growing only when needed
  if (!_batchBuffer || _batchBuffer.length < byteSize) {
    [_batchBuffer release];  // MRC: release the smaller previous buffer (+1)
    _batchBuffer = [_device newBufferWithLength:std::max(byteSize, (NSUInteger)65536)
                                        options:MTLResourceStorageModeShared];
  }
  memcpy(_batchBuffer.contents, drawVertices->data(), byteSize);
  id<MTLBuffer> tmpVBO = _batchBuffer;

  // Bind batch VBO at buffer index 0
  [_encoder setVertexBuffer:tmpVBO offset:0 atIndex:0];

  // Upload modelview, projection matrices, and point size as uniforms
  struct {
    float modelview[16];
    float projection[16];
    float pointSize;
    float _pad[3];
  } uniforms;
  std::memcpy(uniforms.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(uniforms.projection, _projectionMatrix.data(), 64);
  uniforms.pointSize = _pointSize > 0.0f ? _pointSize : 1.0f;
  uniforms._pad[0] = uniforms._pad[1] = uniforms._pad[2] = 0.0f;
  [_encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
  // Lighting (Scene sliders) for the lit vbo_fragment / vbo_fragment_oit at
  // fragment buffer(0). Harmless for the unlit/flat pipelines (they don't read
  // it). Scoped so the local doesn't clash across multiple draw paths.
  { struct { float a, d, r, s, sh, w; } _lt = { _lightAmbient, _lightDirect,
      _lightReflect, _lightSpecular, _lightShininess, _sssWrap };
    [_encoder setFragmentBytes:&_lt length:sizeof(_lt) atIndex:0]; }

  // Always use the built-in batch pipeline for batch rendering.
  // _currentPipeline is for VBO draws with a different vertex layout.
  [_encoder setRenderPipelineState:_batchPipeline];

  MTLPrimitiveType mtlPrim =
      (_batchMode == PrimitiveType::TriangleFan ||
       _batchMode == PrimitiveType::Quads)
          ? MTLPrimitiveTypeTriangle
          : toMTL(_batchMode);

  [_encoder drawPrimitives:mtlPrim
               vertexStart:0
               vertexCount:static_cast<NSUInteger>(drawVertices->size())];

  _batchVertices.clear();
}

// ---------------------------------------------------------------------------
#pragma mark - Render readiness
// ---------------------------------------------------------------------------

bool RendererMetal::isRenderReady() const
{
  return _cmdBuffer && _passDesc && _batchPipeline;
}

bool RendererMetal::hasActiveEncoder() const
{
  // The encoder must exist AND the command buffer must not yet be committed.
  // After endFrame() commits the buffer, _cmdBuffer is nilled. But if
  // SceneRenderAll ends/restarts the encoder, _encoder may be nil while
  // _cmdBuffer is still valid — that's fine, ensureEncoder() can recreate it.
  // We only reject the case where _cmdBuffer itself is gone or committed.
  if (!_cmdBuffer) return false;
  MTLCommandBufferStatus status = [_cmdBuffer status];
  return status < MTLCommandBufferStatusCommitted;
}

// ---------------------------------------------------------------------------
#pragma mark - Queries
// ---------------------------------------------------------------------------

void RendererMetal::getIntegerv(int /*pname*/, int* params)
{
  // Stub — most GL queries don't map to Metal.
  // Specific queries will be added as needed.
  if (params) *params = 0;
}

const char* RendererMetal::getString(int /*name*/)
{
  return "Metal";
}

int RendererMetal::getError()
{
  return 0; // Metal uses NSError, not error codes
}

// ---------------------------------------------------------------------------
#pragma mark - Misc
// ---------------------------------------------------------------------------

void RendererMetal::flush()
{
  // Metal command buffers are committed in endFrame().
  // No equivalent of glFlush needed.
}

void RendererMetal::finish()
{
  if (_cmdBuffer) {
    [_cmdBuffer waitUntilCompleted];
  }
}

void RendererMetal::readPixels(
    int x, int y, int w, int h, int /*format*/, int /*type*/, void* pixels)
{
  if (!pixels || !_drawable) return;

  // Reading pixels from the drawable texture requires a blit encoder.
  // This is used for ray tracing output and screenshot capture.
  id<MTLTexture> tex = _drawable.texture;
  if (!tex) return;

  // End current render encoder if active
  if (_encoder) {
    [_encoder endEncoding];
    _encoder = nil;
  }

  MTLRegion region = MTLRegionMake2D(
      static_cast<NSUInteger>(x), static_cast<NSUInteger>(y),
      static_cast<NSUInteger>(w), static_cast<NSUInteger>(h));
  NSUInteger bytesPerRow = static_cast<NSUInteger>(w) * 4; // RGBA8

  [tex getBytes:pixels
      bytesPerRow:bytesPerRow
       fromRegion:region
      mipmapLevel:0];
}

void RendererMetal::pixelStorei(int /*pname*/, int /*param*/)
{
  // Metal doesn't have pixel store state — alignment is handled
  // explicitly when creating textures and reading pixels.
}

// ---------------------------------------------------------------------------
#pragma mark - VBO Pipeline
// ---------------------------------------------------------------------------

void RendererMetal::buildVBOPipelines()
{
  // MRC: release the previous build's owned objects before this call rebuilds
  // them (e.g. on an MSAA sample-count change via setSampleCount). On the first
  // call (from the ctor) every ivar is nil, so each release is a no-op. The
  // _vboShadowPipeline* are NOT included — buildShadowPipelines() guards against
  // a second build, so this function never overwrites them.
  [_vboVertexFunc release];           _vboVertexFunc = nil;
  [_vboFragmentFunc release];         _vboFragmentFunc = nil;
  [_vboVertexUnlitFunc release];      _vboVertexUnlitFunc = nil;
  [_vboFragmentUnlitFunc release];    _vboFragmentUnlitFunc = nil;
  [_vboVertexUnlitFlatFunc release];  _vboVertexUnlitFlatFunc = nil;
  [_vboFragmentShadowFunc release];   _vboFragmentShadowFunc = nil;
  [_capMarkVtxFunc release];          _capMarkVtxFunc = nil;
  [_capMarkFragFunc release];         _capMarkFragFunc = nil;
  [_capFillVtxFunc release];          _capFillVtxFunc = nil;
  [_capFillFragFunc release];         _capFillFragFunc = nil;
  [_lineAAVtxFunc release];           _lineAAVtxFunc = nil;
  [_lineAAFragFunc release];          _lineAAFragFunc = nil;
  [_vboFragmentOitFunc release];      _vboFragmentOitFunc = nil;
  [_capMarkDSS release];              _capMarkDSS = nil;
  [_capFillDSS release];              _capFillDSS = nil;
  [_capFillPipeline release];         _capFillPipeline = nil;
  [_vboPipelineUByte release];        _vboPipelineUByte = nil;
  [_vboPipelineFloat release];        _vboPipelineFloat = nil;
  [_vboOitPipelineUByte release];     _vboOitPipelineUByte = nil;
  [_vboOitPipelineFloat release];     _vboOitPipelineFloat = nil;

  // Metal shader for VBO-based molecular geometry (cartoons, surfaces, etc.)
  // Supports position + normal + color with basic Lambertian lighting.
  NSString* vboSrc = @R"(
#include <metal_stdlib>
using namespace metal;

struct VBOVertexIn {
  float3 position [[attribute(0)]];
  float3 normal   [[attribute(1)]];
  float4 color    [[attribute(2)]];
};

struct VBOUniforms {
  float4x4 modelview;
  float4x4 projection;
  float pointSize;
};

struct VBOVertexOut {
  float4 position [[position]];
  float4 color;
  float3 normalEye;   // eye-space normal, interpolated → per-fragment (Phong)
  float  eyeDist;     // distance from camera (-eyeZ), for per-rep clipping
};

// Per-representation clip planes (eye-space distances from the camera). Lets one
// rep (e.g. the surface) clip tighter than the global slab so the user can peek
// inside while cartoon/sticks stay whole. enabled<0.5 => no per-rep clip.
struct ClipU { float front; float back; float enabled; float _pad; };
static void apply_rep_clip(ClipU clip, float eyeDist) {
  if (clip.enabled > 0.5 && (eyeDist < clip.front || eyeDist > clip.back))
    discard_fragment();
}

// PyMOL two-light model. The ambient/direct/reflect/specular/shininess come
// from the live PyMOL settings (Scene lighting sliders) via LightU, instead of
// hard-coded constants, so the sliders take effect. Two-sided: the interpolated
// normal is flipped to face the viewer so cartoon undersides / surface
// interiors light up instead of going dark.
struct LightU { float ambient, direct, reflect, spec, shininess, wrap; };
// Wrapped diffuse: at w=0 this is saturate(n)=max(n,0) for unit-vector dots,
// i.e. pixel-identical to the old `n>0 ? n : 0` Lambert. w>0 lets light bleed
// past the terminator (soft subsurface/waxy look). Specular stays gated on the
// raw dot so highlights are unaffected.
static float wrap_diffuse(float ndl, float w) { return saturate((ndl + w) / (1.0 + w)); }
static float3 vbo_shade(float3 baseColor, float3 nEye, LightU lt) {
  float3 normal = normalize(nEye);
  if (normal.z < 0.0) normal = -normal;
  float ambient    = lt.ambient;
  float direct     = lt.direct;
  float reflect    = lt.reflect;
  float spec_value = lt.spec;
  float shininess  = max(lt.shininess, 1.0);
  const float3 L0 = float3(0.0, 0.0, 1.0);
  const float3 L1 = normalize(float3(0.4, 0.4, 1.0));
  float intensity = ambient;
  float specular = 0.0;
  float n0 = dot(normal, L0);
  intensity += direct * wrap_diffuse(n0, lt.wrap);
  float n1 = dot(normal, L1);
  intensity += reflect * wrap_diffuse(n1, lt.wrap);
  if (n1 > 0.0) {
    float3 H1 = normalize(L1 + float3(0.0, 0.0, 1.0));
    // Soften specular on the lit-VBO path (cartoon + molecular surface). The
    // fixed view half-vector makes a flat ribbon/sheet face light up uniformly
    // bright, which reads as harsh triangular facets once screen-space AO is
    // removed from cartoons (#79) — the geometry normals are smooth, but the
    // strong highlight on each flat facet exaggerates the low-poly faces. Scale
    // the specular toward the softer ray-tracer/desktop look. Sphere/cylinder
    // impostors have their own shaders and keep full specular (sticks/spheres
    // stay glossy).
    const float kLitVBOSpecScale = 0.4;
    specular += kLitVBOSpecScale * spec_value * pow(max(dot(normal, H1), 0.0), shininess);
  }
  return baseColor * min(intensity, 1.0) + specular;
}

// Unlit input has no normal attribute (lines/ribbon/dots disable lighting).
struct VBOVertexInUnlit {
  float3 position [[attribute(0)]];
  float4 color    [[attribute(2)]];
};

struct VBOVertexOutUnlit {
  float4 position [[position]];
  float4 color;
  float  pointSize [[point_size]];
};

vertex VBOVertexOut vbo_vertex(
    VBOVertexIn in [[stage_in]],
    constant VBOUniforms& uniforms [[buffer(1)]])
{
  VBOVertexOut out;
  float4 eyePos = uniforms.modelview * float4(in.position, 1.0);
  out.position = uniforms.projection * eyePos;
  // PyMOL's projection is GL-convention (clip Z in [-1,1]); the impostors write
  // window depth explicitly as 0.5+0.5*ndcz ([0,1]). Remap the rasterized VBO z
  // the same way so VBO geometry (cartoon/surface) and impostors (spheres/
  // cylinders) share one depth convention and occlude correctly. (Also un-clips
  // the GL near half.)
  out.position.z = 0.5 * (out.position.z + out.position.w);
  // Carry the eye-space normal + raw color; lighting is done PER-FRAGMENT
  // (Phong) in vbo_fragment. Per-vertex (Gouraud) lighting baked the shade
  // into the interpolated color, which faceted the coarse cartoon mesh
  // (visible triangle banding); per-pixel shading is smooth.
  out.normalEye = (uniforms.modelview * float4(in.normal, 0.0)).xyz;
  out.color = in.color;
  // Eye-space distance from the camera (eyePos.z is negative in front), used by
  // the fragment stage to discard fragments outside this rep's clip planes.
  out.eyeDist = -eyePos.z;
  return out;
}

fragment float4 vbo_fragment(VBOVertexOut in [[stage_in]],
    constant LightU& lt [[buffer(0)]],
    constant ClipU& clip [[buffer(1)]])
{
  apply_rep_clip(clip, in.eyeDist);
  return float4(vbo_shade(in.color.rgb, in.normalEye, lt), in.color.a);
}

// Unlit: flat color, no lighting. Used for lines/ribbon (GL_LINES) and dots
// (GL_POINTS), which disable lighting and carry no normal attribute. Emits
// point_size so dots render at the requested screen size.
vertex VBOVertexOutUnlit vbo_vertex_unlit(
    VBOVertexInUnlit in [[stage_in]],
    constant VBOUniforms& uniforms [[buffer(1)]])
{
  VBOVertexOutUnlit out;
  out.position = uniforms.projection * (uniforms.modelview * float4(in.position, 1.0));
  out.position.z = 0.5 * (out.position.z + out.position.w);  // GL z [-1,1] -> Metal [0,1]
  out.color = in.color;
  out.pointSize = max(uniforms.pointSize, 1.0);
  return out;
}

fragment float4 vbo_fragment_unlit(VBOVertexOutUnlit in [[stage_in]])
{
  return in.color;
}

// Unlit, position-only: for uniform-colored line geometry whose VBO carries NO
// per-vertex color (alignment objects, distance/angle dashes). The regular
// unlit shader declares a color attribute [[attribute(2)]]; binding it against
// a VBO layout that has no color attribute makes pipeline creation FAIL ("Vertex
// attribute 2 is not defined in the vertex descriptor"), which on device floods
// every frame and gets the app killed. This variant takes only position and
// reads the color from a uniform (buffer 2), so the pipeline always builds.
struct VBOVertexInPosOnly {
  float3 position [[attribute(0)]];
};
vertex VBOVertexOutUnlit vbo_vertex_unlit_flat(
    VBOVertexInPosOnly in [[stage_in]],
    constant VBOUniforms& uniforms [[buffer(1)]],
    constant float4& flatColor [[buffer(2)]])
{
  VBOVertexOutUnlit out;
  out.position = uniforms.projection * (uniforms.modelview * float4(in.position, 1.0));
  out.position.z = 0.5 * (out.position.z + out.position.w);  // GL z [-1,1] -> Metal [0,1]
  out.color = flatColor;
  out.pointSize = max(uniforms.pointSize, 1.0);
  return out;
}

// --- Interior cap for a clipped closed SURFACE (stencil capping) ---
// MARK: render the surface's NOT-clipped faces position-only (cull none, no
// color/depth write, stencil = INVERT). Each face toggles stencil bit 0, so odd
// parity == the near (slab) plane is inside the solid the surface encloses.
struct CapMarkIn { float3 position [[attribute(0)]]; };
struct CapMarkOut { float4 position [[position]]; float eyeDist; };
vertex CapMarkOut cap_mark_vertex(CapMarkIn in [[stage_in]],
    constant VBOUniforms& u [[buffer(1)]]) {
  CapMarkOut o;
  float4 eye = u.modelview * float4(in.position, 1.0);
  float4 p = u.projection * eye;
  p.z = 0.5 * (p.z + p.w);   // GL [-1,1] -> Metal [0,1] (match the VBO)
  o.position = p;
  o.eyeDist = -eye.z;        // per-rep clip parity (matches vbo_vertex)
  return o;
}
// Discard the per-rep-clipped-away faces so the stencil parity marks the cut at
// the per-rep FRONT plane (not just the global near plane). The bound ClipU has
// back left open so only the viewer-facing cut is capped; when per-rep clip is
// off (enabled=0) this is a no-op and the global-slab/impostor cap is unchanged.
fragment float4 cap_mark_fragment(CapMarkOut in [[stage_in]],
    constant ClipU& clip [[buffer(1)]]) {
  apply_rep_clip(clip, in.eyeDist);
  return float4(0.0);  // color masked off (writeMask none)
}
// FILL: a full-screen triangle at the cut-plane depth (capDepth; the global near
// sentinel 1e-5 when per-rep clip is off); a stencil EQUAL test keeps only the
// interior pixels, filled with a flat interior color (and the pass clears the
// stencil bit so multiple capped surfaces don't interfere).
struct CapFillOut { float4 position [[position]]; };
vertex CapFillOut cap_fill_vertex(uint vid [[vertex_id]],
    constant float& capDepth [[buffer(0)]]) {
  float2 p = float2(float((vid << 1) & 2), float(vid & 2));   // (0,0)(2,0)(0,2)
  CapFillOut o;
  o.position = float4(p * 2.0 - 1.0, capDepth, 1.0);  // cover screen at cut depth
  return o;
}
fragment float4 cap_fill_fragment(constant float4& interiorColor [[buffer(0)]]) {
  // The cut cross-section faces the viewer, so light it with a +Z normal
  // through the shared two-light model (matches desktop's interior_normal
  // {0,0,1}). Caps use the default lighting (a minor flat fill).
  LightU lt = {0.14, 0.45, 0.481, 0.5, 55.0, 0.0};
  return float4(vbo_shade(interiorColor.rgb, float3(0.0, 0.0, 1.0), lt), interiorColor.a);
}

// --- Surface coverage (for the outer-contour outline) ---
// Rendered AFTER the scene into an R8 mask: position-only, applies the per-rep
// clip (so coverage matches the displayed/clipped surface), writes 1 for every
// surviving fragment. post_surface_contour then outlines the mask boundary.
struct CovOut { float4 position [[position]]; float eyeDist; };
vertex CovOut coverage_vertex(CapMarkIn in [[stage_in]],
    constant VBOUniforms& u [[buffer(1)]]) {
  CovOut o;
  float4 eye = u.modelview * float4(in.position, 1.0);
  o.position = u.projection * eye;
  o.position.z = 0.5 * (o.position.z + o.position.w);
  o.eyeDist = -eye.z;
  return o;
}
fragment float4 coverage_fragment(CovOut in [[stage_in]],
    constant ClipU& clip [[buffer(1)]]) {
  apply_rep_clip(clip, in.eyeDist);
  return float4(1.0, 0.0, 0.0, 1.0); // R8 mask = 1 where the surface covers
}

// Weighted-blended OIT output (McGuire/Bavoil). Transparent geometry writes
// premultiplied color*weight to the accum target and its alpha to the reveal
// target; the weight de-emphasizes far/low-alpha fragments. z = window depth.
struct OITFragOut {
  float4 accum  [[color(0)]];
  float  reveal [[color(1)]];
};
static float oit_weight(float a, float z) {
  return clamp(pow(min(1.0, a * 10.0) + 0.01, 3.0) * 1e8 *
               pow(1.0 - z * 0.9, 3.0), 1e-2, 3e3);
}
fragment OITFragOut vbo_fragment_oit(VBOVertexOut in [[stage_in]],
    constant LightU& lt [[buffer(0)]],
    constant ClipU& clip [[buffer(1)]])
{
  apply_rep_clip(clip, in.eyeDist);
  float4 c = float4(vbo_shade(in.color.rgb, in.normalEye, lt), in.color.a);
  float w = oit_weight(c.a, in.position.z);
  OITFragOut o;
  o.accum = float4(c.rgb * c.a, c.a) * w;
  o.reveal = c.a;
  return o;
}

// Depth-only fragment for the shadow pre-pass: no color attachment, the
// rasterizer writes window depth implicitly from vbo_vertex's clip position
// (which in shadow mode is light-clip). Used by the depth-only VBO pipelines.
fragment void vbo_fragment_shadow(VBOVertexOut in [[stage_in]])
{
}

// --- Anti-aliased screen-space line quads ("trilines"). The CPU expands each
// line segment into a feathered quad in clip space (see drawLinesAA); these
// shaders just pass the pre-projected verts through and feather-fade the edges
// by signed distance from the segment center line. ---
struct LineAAIn {
  float4 posClip    [[attribute(0)]];
  float4 color      [[attribute(1)]];
  float  centerDist [[attribute(2)]];
};
struct LineAAOut {
  float4 position [[position]];
  float4 color;
  float  centerDist;
};
struct LineAAU { float halfWidth; float feather; };
// CPU emits pre-projected clip-space quad verts; pass through with the standard
// GL->Metal z remap (matches vbo_vertex) so lines occlude consistently.
vertex LineAAOut line_aa_vertex(LineAAIn in [[stage_in]]) {
  LineAAOut o;
  o.position = in.posClip;
  o.position.z = 0.5 * (o.position.z + o.position.w);
  o.color = in.color;
  o.centerDist = in.centerDist;
  return o;
}
fragment float4 line_aa_fragment(LineAAOut in [[stage_in]],
    constant LineAAU& u [[buffer(0)]]) {
  float cov = 1.0 - clamp((abs(in.centerDist) - u.halfWidth) / max(u.feather, 1e-3), 0.0, 1.0);
  if (cov <= 0.0) discard_fragment();
  return float4(in.color.rgb, in.color.a * cov);
}
)";

  NSError* error = nil;
  id<MTLLibrary> lib = [_device newLibraryWithSource:vboSrc
                                             options:nil
                                               error:&error];
  if (!lib) {
    NSLog(@"RendererMetal: failed to compile VBO shader: %@", error);
    return;
  }

  _vboVertexFunc = [lib newFunctionWithName:@"vbo_vertex"];
  _vboFragmentFunc = [lib newFunctionWithName:@"vbo_fragment"];
  _vboVertexUnlitFunc = [lib newFunctionWithName:@"vbo_vertex_unlit"];
  _vboFragmentUnlitFunc = [lib newFunctionWithName:@"vbo_fragment_unlit"];
  _vboVertexUnlitFlatFunc = [lib newFunctionWithName:@"vbo_vertex_unlit_flat"];
  _vboFragmentShadowFunc = [lib newFunctionWithName:@"vbo_fragment_shadow"];
  _capMarkVtxFunc = [lib newFunctionWithName:@"cap_mark_vertex"];
  _capMarkFragFunc = [lib newFunctionWithName:@"cap_mark_fragment"];
  _capFillVtxFunc = [lib newFunctionWithName:@"cap_fill_vertex"];
  _capFillFragFunc = [lib newFunctionWithName:@"cap_fill_fragment"];
  _coverageVtxFunc = [lib newFunctionWithName:@"coverage_vertex"];
  _coverageFragFunc = [lib newFunctionWithName:@"coverage_fragment"];
  _lineAAVtxFunc = [lib newFunctionWithName:@"line_aa_vertex"];
  _lineAAFragFunc = [lib newFunctionWithName:@"line_aa_fragment"];
  if (!_vboVertexFunc || !_vboFragmentFunc) {
    NSLog(@"RendererMetal: VBO shader functions not found");
    [lib release];  // MRC: library (+1) consumed
    return;
  }

  // Surface interior-cap states + fill pipeline (mark pipeline is stride-keyed,
  // built lazily in drawVBOIndexed). MARK: stencil INVERT on every not-clipped
  // face (depth ALWAYS, no depth write). FILL: stencil EQUAL 1 -> write cap +
  // clear the bit (ZERO) so multiple capped surfaces don't accumulate.
  {
    MTLStencilDescriptor* sm = [[MTLStencilDescriptor alloc] init];
    sm.stencilCompareFunction = MTLCompareFunctionAlways;
    sm.depthStencilPassOperation = MTLStencilOperationInvert;
    sm.depthFailureOperation = MTLStencilOperationInvert;
    sm.stencilFailureOperation = MTLStencilOperationKeep;
    sm.readMask = 0x1; sm.writeMask = 0x1;
    MTLDepthStencilDescriptor* md = [[MTLDepthStencilDescriptor alloc] init];
    md.depthCompareFunction = MTLCompareFunctionAlways;
    md.depthWriteEnabled = NO;
    md.frontFaceStencil = sm; md.backFaceStencil = sm;
    _capMarkDSS = [_device newDepthStencilStateWithDescriptor:md];

    MTLStencilDescriptor* sf = [[MTLStencilDescriptor alloc] init];
    sf.stencilCompareFunction = MTLCompareFunctionEqual;       // ref = 1
    sf.depthStencilPassOperation = MTLStencilOperationZero;    // clear the bit
    sf.depthFailureOperation = MTLStencilOperationZero;
    sf.stencilFailureOperation = MTLStencilOperationKeep;
    sf.readMask = 0x1; sf.writeMask = 0x1;
    MTLDepthStencilDescriptor* fd = [[MTLDepthStencilDescriptor alloc] init];
    fd.depthCompareFunction = MTLCompareFunctionAlways;
    fd.depthWriteEnabled = YES;
    fd.frontFaceStencil = sf; fd.backFaceStencil = sf;
    _capFillDSS = [_device newDepthStencilStateWithDescriptor:fd];
    // MRC: the stencil/depth descriptors (+1) are consumed by the states above.
    [sm release]; [md release]; [sf release]; [fd release];

    if (_capFillVtxFunc && _capFillFragFunc) {
      MTLRenderPipelineDescriptor* fp = [[MTLRenderPipelineDescriptor alloc] init];
      fp.vertexFunction = _capFillVtxFunc;
      fp.fragmentFunction = _capFillFragFunc;
      fp.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      fp.rasterSampleCount = _sampleCount;
      fp.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      fp.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      NSError* ce = nil;
      _capFillPipeline = [_device newRenderPipelineStateWithDescriptor:fp error:&ce];
      if (!_capFillPipeline) NSLog(@"RendererMetal: cap fill pipeline failed: %@", ce);
      [fp release];  // MRC: descriptor (+1) consumed by pipeline creation
    }
  }

  // Create pipeline for UByte4Norm color format:
  // position: Float3 @ offset 0, normal: Float3 @ offset 12, color: UChar4Norm @ offset 24
  // stride = 28
  {
    MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat3;
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat3;
    vd.attributes[1].offset = 12;
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatUChar4Normalized;
    vd.attributes[2].offset = 24;
    vd.attributes[2].bufferIndex = 0;
    vd.layouts[0].stride = 28;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    MTLRenderPipelineDescriptor* psd =
        [[MTLRenderPipelineDescriptor alloc] init];
    psd.vertexFunction = _vboVertexFunc;
    psd.fragmentFunction = _vboFragmentFunc;
    psd.vertexDescriptor = vd;
    psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    psd.colorAttachments[0].blendingEnabled = YES;
    psd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    psd.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    psd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    psd.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    psd.rasterSampleCount = _sampleCount;
    psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

    _vboPipelineUByte = [_device newRenderPipelineStateWithDescriptor:psd
                                                                error:&error];
    if (!_vboPipelineUByte) {
      NSLog(@"RendererMetal: failed to create VBO UByte pipeline: %@", error);
    }
    [psd release];  // MRC: descriptor (+1) consumed by pipeline creation
  }

  // Create pipeline for Float4 color format:
  // position: Float3 @ offset 0, normal: Float3 @ offset 12, color: Float4 @ offset 24
  // stride = 40
  {
    MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat3;
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat3;
    vd.attributes[1].offset = 12;
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatFloat4;
    vd.attributes[2].offset = 24;
    vd.attributes[2].bufferIndex = 0;
    vd.layouts[0].stride = 40;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    MTLRenderPipelineDescriptor* psd =
        [[MTLRenderPipelineDescriptor alloc] init];
    psd.vertexFunction = _vboVertexFunc;
    psd.fragmentFunction = _vboFragmentFunc;
    psd.vertexDescriptor = vd;
    psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    psd.colorAttachments[0].blendingEnabled = YES;
    psd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    psd.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    psd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    psd.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    psd.rasterSampleCount = _sampleCount;
    psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

    _vboPipelineFloat = [_device newRenderPipelineStateWithDescriptor:psd
                                                                error:&error];
    if (!_vboPipelineFloat) {
      NSLog(@"RendererMetal: failed to create VBO Float pipeline: %@", error);
    }
    [psd release];  // MRC: descriptor (+1) consumed by pipeline creation
  }

  // Weighted-blended OIT variants: same vertex shader + geometry, but the
  // fragment writes to MRT (accum RGBA16F additive, reveal R16F multiplicative)
  // for order-independent transparency. Prebuild the two common layouts; other
  // layouts (e.g. the surface's stride-44 layout) get a one-off via
  // oitPipelineForVD() at draw time.
  _vboFragmentOitFunc = [lib newFunctionWithName:@"vbo_fragment_oit"];
  if (_vboFragmentOitFunc) {
    auto mkvd = [](MTLVertexFormat colorFmt,
                   NSUInteger strideBytes) -> MTLVertexDescriptor* {
      MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
      vd.attributes[0].format = MTLVertexFormatFloat3;
      vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0;
      vd.attributes[1].format = MTLVertexFormatFloat3;
      vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0;
      vd.attributes[2].format = colorFmt;
      vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0;
      vd.layouts[0].stride = strideBytes;
      vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
      return vd;
    };
    _vboOitPipelineUByte =
        oitPipelineForVD(mkvd(MTLVertexFormatUChar4Normalized, 28));
    _vboOitPipelineFloat = oitPipelineForVD(mkvd(MTLVertexFormatFloat4, 40));
  }
  [lib release];  // MRC: library (+1) no longer needed once functions are created

  // Depth-only shadow pipelines (light-POV pre-pass) for the common layouts.
  buildShadowPipelines();
}

// Depth-only VBO pipeline for the shadow pre-pass: single-sample, Depth32Float,
// NO color attachment (the void fragment writes only rasterizer depth). Mirrors
// oitPipelineForVD but for the light-POV depth map.
id<MTLRenderPipelineState> RendererMetal::shadowPipelineForVD(
    MTLVertexDescriptor* vd)
{
  if (!_vboVertexFunc || !_vboFragmentShadowFunc) return nil;
  MTLRenderPipelineDescriptor* p = [[MTLRenderPipelineDescriptor alloc] init];
  p.vertexFunction = _vboVertexFunc;
  p.fragmentFunction = _vboFragmentShadowFunc;
  p.vertexDescriptor = vd;
  p.rasterSampleCount = 1;  // shadow pass is single-sample (scene is MSAA)
  p.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;  // NOT _Stencil8
  // No colorAttachments[0] pixel format: depth-only pass.
  NSError* e = nil;
  id<MTLRenderPipelineState> ps =
      [_device newRenderPipelineStateWithDescriptor:p error:&e];
  if (!ps) NSLog(@"RendererMetal: VBO shadow pipeline failed: %@", e);
  [p release];  // MRC: descriptor (+1) consumed by pipeline creation
  return ps;
}

void RendererMetal::buildShadowPipelines()
{
  if (_vboShadowPipelineUByte) return;
  if (!_vboVertexFunc || !_vboFragmentShadowFunc) return;
  auto mkvd = [](MTLVertexFormat colorFmt,
                 NSUInteger strideBytes) -> MTLVertexDescriptor* {
    MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat3;
    vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat3;
    vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = colorFmt;
    vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0;
    vd.layouts[0].stride = strideBytes;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    return vd;
  };
  _vboShadowPipelineUByte =
      shadowPipelineForVD(mkvd(MTLVertexFormatUChar4Normalized, 28));
  _vboShadowPipelineFloat = shadowPipelineForVD(mkvd(MTLVertexFormatFloat4, 40));
}

// ---------------------------------------------------------------------------
#pragma mark - Anti-aliased lines (CPU-expanded screen-space quads)
// ---------------------------------------------------------------------------

// Lazy, sample-count-aware (mirrors buildShadowPipelines). The CPU-expanded
// quad layout is: posClip Float4 @0, color Float4 @16, centerDist Float @32,
// stride 36, per-vertex. Src-alpha blending lets the feather alpha antialias.
void RendererMetal::buildLinePipeline()
{
  if (_vboLinePipeline) return;
  if (!_lineAAVtxFunc || !_lineAAFragFunc) return;

  MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
  vd.attributes[0].format = MTLVertexFormatFloat4;
  vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0;
  vd.attributes[1].format = MTLVertexFormatFloat4;
  vd.attributes[1].offset = 16; vd.attributes[1].bufferIndex = 0;
  vd.attributes[2].format = MTLVertexFormatFloat;
  vd.attributes[2].offset = 32; vd.attributes[2].bufferIndex = 0;
  vd.layouts[0].stride = 36;
  vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

  MTLRenderPipelineDescriptor* p = [[MTLRenderPipelineDescriptor alloc] init];
  p.vertexFunction = _lineAAVtxFunc;
  p.fragmentFunction = _lineAAFragFunc;
  p.vertexDescriptor = vd;
  p.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  p.colorAttachments[0].blendingEnabled = YES;
  p.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  p.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  p.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  p.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  p.rasterSampleCount = _sampleCount;
  p.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  p.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  NSError* e = nil;
  _vboLinePipeline = [_device newRenderPipelineStateWithDescriptor:p error:&e];
  if (!_vboLinePipeline)
    NSLog(@"RendererMetal: line AA pipeline failed: %@", e);
}

void RendererMetal::drawLinesAA(PrimitiveType mode, int vertexCount,
    const void* data, size_t stride, int posOffset, int colorOffset,
    int colorType, bool flat)
{
  int nSeg = (mode == PrimitiveType::LineStrip) ? (vertexCount - 1)
                                                : (vertexCount / 2);
  if (nSeg <= 0) return;
  buildLinePipeline();
  if (!_vboLinePipeline) return;

  // mvp = projection * modelview (both column-major GL). Small column-major
  // mat4*vec4 helper (multiplyMatrices already gives mat4*mat4).
  const Mat4 mvp = multiplyMatrices(_projectionMatrix, _modelviewMatrix);
  auto mulMV4 = [&mvp](float x, float y, float z, float out[4]) {
    for (int r = 0; r < 4; ++r) {
      out[r] = mvp[0 * 4 + r] * x + mvp[1 * 4 + r] * y +
               mvp[2 * 4 + r] * z + mvp[3 * 4 + r];
    }
  };

  const float lw = std::max(_lineWidth, 1.0f);
  const float feather = 1.5f;
  const float halfExtent = lw * 0.5f + feather;

  const float vpW = (float)_viewport.width;
  const float vpH = (float)_viewport.height;
  if (vpW <= 0.0f || vpH <= 0.0f) return;
  const float halfVpX = 0.5f * vpW;
  const float halfVpY = 0.5f * vpH;

  const auto* base = static_cast<const unsigned char*>(data);
  auto readPos = [&](int idx, float p[3]) {
    const float* fp = reinterpret_cast<const float*>(
        base + (size_t)idx * stride + posOffset);
    p[0] = fp[0]; p[1] = fp[1]; p[2] = fp[2];
  };
  auto readColor = [&](int idx, float c[4]) {
    if (flat || colorOffset < 0) {
      c[0] = c[1] = c[2] = c[3] = 1.0f;
      return;
    }
    const unsigned char* cp = base + (size_t)idx * stride + colorOffset;
    if (colorType == 0) {  // 4x uchar normalized
      c[0] = cp[0] / 255.0f; c[1] = cp[1] / 255.0f;
      c[2] = cp[2] / 255.0f; c[3] = cp[3] / 255.0f;
    } else {               // 4x float
      const float* fc = reinterpret_cast<const float*>(cp);
      c[0] = fc[0]; c[1] = fc[1]; c[2] = fc[2]; c[3] = fc[3];
    }
  };

  _lineExpand.clear();
  _lineExpand.reserve((size_t)nSeg * 6 * 9);

  // 2 triangles, 6 verts. corner endpoint index {0,0,1,1,0,1}, side {-1,1,-1,-1,1,1}.
  static const int kCornerEnd[6]  = {0, 0, 1, 1, 0, 1};
  static const float kCornerSide[6] = {-1.f, 1.f, -1.f, -1.f, 1.f, 1.f};

  for (int s = 0; s < nSeg; ++s) {
    int i0, i1;
    if (mode == PrimitiveType::LineStrip) { i0 = s; i1 = s + 1; }
    else { i0 = 2 * s; i1 = 2 * s + 1; }

    float p0[3], p1[3], c0[4], c1[4];
    readPos(i0, p0); readPos(i1, p1);
    readColor(i0, c0); readColor(i1, c1);

    float clip0[4], clip1[4];
    mulMV4(p0[0], p0[1], p0[2], clip0);
    mulMV4(p1[0], p1[1], p1[2], clip1);
    if (clip0[3] == 0.0f || clip1[3] == 0.0f) continue;

    const float ndc0x = clip0[0] / clip0[3], ndc0y = clip0[1] / clip0[3];
    const float ndc1x = clip1[0] / clip1[3], ndc1y = clip1[1] / clip1[3];
    // Screen-space positions (px) for direction; only the direction matters.
    const float sx0 = ndc0x * halfVpX, sy0 = ndc0y * halfVpY;
    const float sx1 = ndc1x * halfVpX, sy1 = ndc1y * halfVpY;
    float dx = sx1 - sx0, dy = sy1 - sy0;
    float len = std::sqrt(dx * dx + dy * dy);
    if (len < 1e-4f) { dx = 1.0f; dy = 0.0f; }
    else { dx /= len; dy /= len; }
    const float px = -dy, py = dx;  // perpendicular

    for (int v = 0; v < 6; ++v) {
      const int end = kCornerEnd[v];
      const float side = kCornerSide[v];
      const float* clip = end ? clip1 : clip0;
      const float* col = end ? c1 : c0;
      const float ndcx = end ? ndc1x : ndc0x;
      const float ndcy = end ? ndc1y : ndc0y;
      // perp offset (across) + dir cap extension (along, ± to fill joins)
      const float capSign = end ? 1.0f : -1.0f;
      const float soX = px * side * halfExtent + dx * capSign * halfExtent;
      const float soY = py * side * halfExtent + dy * capSign * halfExtent;
      const float ndcOX = soX / halfVpX;
      const float ndcOY = soY / halfVpY;
      const float w = clip[3];
      // out clip = ((ndc + ndcOffset) * w, clipz, w)
      _lineExpand.push_back((ndcx + ndcOX) * w);
      _lineExpand.push_back((ndcy + ndcOY) * w);
      _lineExpand.push_back(clip[2]);
      _lineExpand.push_back(w);
      _lineExpand.push_back(col[0]);
      _lineExpand.push_back(col[1]);
      _lineExpand.push_back(col[2]);
      _lineExpand.push_back(col[3]);
      _lineExpand.push_back(side * halfExtent);  // centerDist
    }
  }

  const NSUInteger emitVerts = (NSUInteger)(_lineExpand.size() / 9);
  if (emitVerts == 0) return;
  const size_t bytes = _lineExpand.size() * sizeof(float);
  if (!_lineBuffer || _lineBufferSize < bytes) {
    [_lineBuffer release];
    _lineBuffer = [_device newBufferWithLength:std::max(bytes, (size_t)65536)
                                       options:MTLResourceStorageModeShared];
    _lineBufferSize = _lineBuffer ? _lineBuffer.length : 0;
  }
  if (!_lineBuffer) return;
  std::memcpy(_lineBuffer.contents, _lineExpand.data(), bytes);

  [_encoder setRenderPipelineState:_vboLinePipeline];
  // Lines depth-test/write like normal scene geometry.
  applyDepthStencilState();
  if (_depthStencilState) [_encoder setDepthStencilState:_depthStencilState];
  [_encoder setVertexBuffer:_lineBuffer offset:0 atIndex:0];
  struct LineAAU { float halfWidth; float feather; } u = {lw * 0.5f, feather};
  [_encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
  [_encoder drawPrimitives:MTLPrimitiveTypeTriangle
               vertexStart:0
               vertexCount:emitVerts];
}

id<MTLRenderPipelineState> RendererMetal::oitPipelineForVD(
    MTLVertexDescriptor* vd)
{
  if (!_vboVertexFunc || !_vboFragmentOitFunc) return nil;
  MTLRenderPipelineDescriptor* p = [[MTLRenderPipelineDescriptor alloc] init];
  p.vertexFunction = _vboVertexFunc;
  p.fragmentFunction = _vboFragmentOitFunc;
  p.vertexDescriptor = vd;
  p.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
  p.colorAttachments[0].blendingEnabled = YES;
  p.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
  p.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
  p.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  p.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
  p.colorAttachments[1].pixelFormat = MTLPixelFormatR16Float;
  p.colorAttachments[1].blendingEnabled = YES;
  p.colorAttachments[1].sourceRGBBlendFactor = MTLBlendFactorZero;
  p.colorAttachments[1].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceColor;
  p.colorAttachments[1].sourceAlphaBlendFactor = MTLBlendFactorZero;
  p.colorAttachments[1].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceColor;
  p.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  p.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  NSError* e = nil;
  id<MTLRenderPipelineState> ps =
      [_device newRenderPipelineStateWithDescriptor:p error:&e];
  if (!ps) NSLog(@"RendererMetal: VBO OIT pipeline failed: %@", e);
  [p release];  // MRC: descriptor (+1) consumed by pipeline creation
  return ps;
}

// Build-once cache for one-off VBO pipelines (non-prebuilt vertex layouts, e.g.
// the molecular-surface stride-44). Returns a BORROWED pipeline owned by
// _vboPipelineCache; callers must NOT release it. Replaces the former per-draw
// oitPipelineForVD/shadowPipelineForVD/inline-fallback creations, which leaked a
// +1 pipeline every frame (and paid full pipeline compilation each time).
id<MTLRenderPipelineState> RendererMetal::cachedVBOPipeline(
    VBOPipelineVariant variant, size_t stride, int posOffset, int normalOffset,
    int colorOffset, int colorType, MTLVertexDescriptor* vd)
{
  // Stable FNV-1a key over the layout + variant + sample count.
  uint64_t key = 1469598103934665603ULL;
  auto mix = [&](uint64_t x) { key ^= x; key *= 1099511628211ULL; };
  mix((uint64_t)variant);
  mix((uint64_t)stride);
  mix((uint32_t)posOffset);
  mix((uint32_t)normalOffset);
  mix((uint32_t)colorOffset);
  mix((uint64_t)colorType);
  mix((uint64_t)_sampleCount);
  auto it = _vboPipelineCache.find(key);
  if (it != _vboPipelineCache.end()) return it->second;  // borrowed (cache-owned)

  id<MTLRenderPipelineState> ps = nil;
  if (variant == VBOPipelineVariant::Oit) {
    ps = oitPipelineForVD(vd);       // +1
  } else if (variant == VBOPipelineVariant::Shadow) {
    ps = shadowPipelineForVD(vd);    // +1
  } else {
    // Opaque pass fallback for a non-prebuilt layout (mirrors the former inline
    // fallback): Lit uses the per-fragment shader, Unlit/UnlitFlat the flat ones.
    id<MTLFunction> vfn = (variant == VBOPipelineVariant::UnlitFlat)
        ? _vboVertexUnlitFlatFunc
        : (variant == VBOPipelineVariant::Unlit ? _vboVertexUnlitFunc
                                                : _vboVertexFunc);
    id<MTLFunction> ffn = (variant == VBOPipelineVariant::Lit)
        ? _vboFragmentFunc : _vboFragmentUnlitFunc;
    if (vfn && ffn) {
      MTLRenderPipelineDescriptor* psd =
          [[MTLRenderPipelineDescriptor alloc] init];
      psd.vertexFunction = vfn;
      psd.fragmentFunction = ffn;
      psd.vertexDescriptor = vd;
      psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      psd.colorAttachments[0].blendingEnabled = YES;
      psd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
      psd.colorAttachments[0].destinationRGBBlendFactor =
          MTLBlendFactorOneMinusSourceAlpha;
      psd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
      psd.colorAttachments[0].destinationAlphaBlendFactor =
          MTLBlendFactorOneMinusSourceAlpha;
      psd.rasterSampleCount = _sampleCount;
      psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      NSError* error = nil;
      ps = [_device newRenderPipelineStateWithDescriptor:psd error:&error];
      if (!ps)
        NSLog(@"RendererMetal: fallback VBO pipeline failed: %@", error);
      [psd release];  // MRC: descriptor (+1) consumed by pipeline creation
    }
  }
  if (ps) _vboPipelineCache[key] = ps;  // cache takes ownership of the +1
  return ps;                            // borrowed
}

// ---------------------------------------------------------------------------
#pragma mark - VBO Drawing
// ---------------------------------------------------------------------------

// Window-space depth ([0,1], matching the VBO's 0.5*(z+w) convention) of the
// per-rep front cut plane, for placing the interior cap-fill at the cut instead
// of the global near plane. Returns the near sentinel (1e-5) when per-rep clip
// is off (repClipFront < 0), preserving the original global-slab/impostor cap.
// P is the column-major projection matrix; clip.z/clip.w of eye point (0,0,ez)
// use P[10],P[14] and P[11],P[15].
static float repCapDepth(const float* P, float repClipFront)
{
  if (repClipFront < 0.0f)
    return 1e-5f;
  float ez = -repClipFront; // eye-space z of the front cut plane (negative)
  float cz = P[10] * ez + P[14];
  float cw = P[11] * ez + P[15];
  if (std::fabs(cw) < 1e-6f)
    return 1e-5f;
  return 0.5f * (cz / cw + 1.0f); // GL NDC [-1,1] -> window [0,1]
}

void RendererMetal::drawVBO(PrimitiveType mode, int vertexCount,
    const void* data, size_t dataSize, size_t stride,
    int posOffset, int normalOffset, int colorOffset, int colorType,
    int interiorCap)
{
  if (!data || dataSize == 0 || vertexCount <= 0) return;
  ensureEncoder();
  if (!_encoder) return;

  // Ray tracing: capture solid triangle meshes (cartoon/surface) once per frame.
  if (_rtEnabled && !_shadowMode && !_oitActive)
    rtAppendVBOTris(_rtTris, mode, vertexCount, data, stride, posOffset, nullptr);

  // Reuse cached Metal buffer if same data pointer, otherwise create new
  id<MTLBuffer> vbo = nil;
  auto cacheIt = _vboCache.find(data);
  if (cacheIt != _vboCache.end()) {
    vbo = cacheIt->second;
  } else {
    vbo = [_device newBufferWithBytes:data
                              length:dataSize
                             options:MTLResourceStorageModeShared];
    if (!vbo) return;
    _vboCache[data] = vbo;
  }

  // Build a vertex descriptor matching the VBO layout
  MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];

  // Position (attribute 0) — always Float3
  if (posOffset >= 0) {
    vd.attributes[0].format = MTLVertexFormatFloat3;
    vd.attributes[0].offset = static_cast<NSUInteger>(posOffset);
    vd.attributes[0].bufferIndex = 0;
  }

  // Normal (attribute 1) — always Float3
  if (normalOffset >= 0) {
    vd.attributes[1].format = MTLVertexFormatFloat3;
    vd.attributes[1].offset = static_cast<NSUInteger>(normalOffset);
    vd.attributes[1].bufferIndex = 0;
  }

  // Color (attribute 2)
  if (colorOffset >= 0) {
    vd.attributes[2].format = (colorType == 0)
        ? MTLVertexFormatUChar4Normalized : MTLVertexFormatFloat4;
    vd.attributes[2].offset = static_cast<NSUInteger>(colorOffset);
    vd.attributes[2].bufferIndex = 0;
  }

  vd.layouts[0].stride = static_cast<NSUInteger>(stride);
  vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

  // Build a pipeline for this specific layout. For common layouts, reuse
  // pre-built pipelines. Lines/ribbon (no normal) and dots (Points) must use
  // the unlit flat-color + point-size shader, so they skip the prebuilt
  // (lit) pipelines even when their interleaved layout happens to match.
  bool unlit = (normalOffset < 0) || (mode == PrimitiveType::Points);
  // Uniform-colored geometry (no per-vertex color attribute): use the
  // position-only flat shader so the pipeline can be created (the normal unlit
  // shader needs attribute 2). Color comes from a uniform (buffer 2) below.
  bool flat = unlit && (colorOffset < 0);

  // Anti-aliased lines: in the normal (non-shadow, non-OIT) pass, expand line
  // segments on the CPU into feathered screen-space quads instead of drawing
  // 1px MTLPrimitiveTypeLine. Lines still cast no shadows (the shadow branch
  // below early-returns for `unlit`) and are skipped in the transparent pass.
  if ((mode == PrimitiveType::Lines || mode == PrimitiveType::LineStrip) &&
      !_shadowMode && !_oitActive) {
    bool flatLine = (colorOffset < 0);
    drawLinesAA(mode, vertexCount, data, stride, posOffset, colorOffset,
        colorType, flatLine);
    return;
  }

  id<MTLRenderPipelineState> pipeline = nil;

  // Shadow pre-pass: route lit geometry to the depth-only shadow pipelines
  // (light VP already loaded). Lines/ribbon/dots don't cast meaningful shadows.
  if (_shadowMode) {
    if (unlit) return;
    if (posOffset == 0 && normalOffset == 12 && colorOffset == 24) {
      if (colorType == 0 && stride == 28) pipeline = _vboShadowPipelineUByte;
      else if (colorType == 1 && stride == 40) pipeline = _vboShadowPipelineFloat;
    }
    if (!pipeline)  // e.g. surface stride 44 — build-once via the layout cache
      pipeline = cachedVBOPipeline(VBOPipelineVariant::Shadow, stride,
          posOffset, normalOffset, colorOffset, colorType, vd);
    if (!pipeline) return;
  }

  // Check if layout matches pre-built pipelines
  if (!_shadowMode && !unlit && posOffset == 0 && normalOffset == 12 &&
      colorOffset == 24) {
    if (_oitActive) {
      // Transparent pass: route lit common layouts to the OIT MRT pipelines.
      if (colorType == 0 && stride == 28) pipeline = _vboOitPipelineUByte;
      else if (colorType == 1 && stride == 40) pipeline = _vboOitPipelineFloat;
    } else if (colorType == 0 && stride == 28 && _vboPipelineUByte) {
      pipeline = _vboPipelineUByte;
    } else if (colorType == 1 && stride == 40 && _vboPipelineFloat) {
      pipeline = _vboPipelineFloat;
    }
  }
  // In the OIT pass only MRT pipelines can render; build a one-off OIT
  // pipeline for non-standard lit layouts (e.g. surface stride 44). Unlit
  // geometry (lines/dots) is skipped in the transparent pass.
  if (_oitActive && !pipeline) {
    if (unlit) return;
    pipeline = cachedVBOPipeline(VBOPipelineVariant::Oit, stride, posOffset,
                                 normalOffset, colorOffset, colorType, vd);
    if (!pipeline) return;
  }

  // Fallback for a non-prebuilt opaque layout: build-once via the layout cache.
  // `flat` (no per-vertex color) → position-only shader; `unlit` (no normal:
  // lines/ribbon/dots) → flat-color shader; else the lit per-fragment shader.
  if (!pipeline) {
    VBOPipelineVariant v = flat ? VBOPipelineVariant::UnlitFlat
                                : (unlit ? VBOPipelineVariant::Unlit
                                         : VBOPipelineVariant::Lit);
    pipeline = cachedVBOPipeline(v, stride, posOffset, normalOffset,
                                 colorOffset, colorType, vd);
  }

  if (!pipeline) return;

  [_encoder setRenderPipelineState:pipeline];

  // Apply depth/stencil
  if (_shadowMode) {
    [_encoder setDepthStencilState:_shadowDepthState]; // LESS + write (light POV)
    // Front-face cull: store the depth of faces pointing AWAY from the light so
    // a thin cartoon/surface slab cannot self-shadow its own light-facing side
    // (genuine fold occlusion is preserved). Restored to back/none after.
    [_encoder setCullMode:MTLCullModeFront];
  } else if (_oitActive) {
    [_encoder setDepthStencilState:oitDepthState()];
  } else {
    applyDepthStencilState();
    if (_depthStencilState) {
      [_encoder setDepthStencilState:_depthStencilState];
    }
  }

  // Bind vertex buffer
  [_encoder setVertexBuffer:vbo offset:0 atIndex:0];

  // Upload modelview, projection matrices, and point size as uniforms
  struct {
    float modelview[16];
    float projection[16];
    float pointSize;
    float _pad[3];
  } uniforms;
  std::memcpy(uniforms.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(uniforms.projection, _projectionMatrix.data(), 64);
  uniforms.pointSize = _pointSize > 0.0f ? _pointSize : 1.0f;
  uniforms._pad[0] = uniforms._pad[1] = uniforms._pad[2] = 0.0f;
  [_encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
  // Lighting (Scene sliders) for the lit vbo_fragment / vbo_fragment_oit at
  // fragment buffer(0). Harmless for the unlit/flat pipelines (they don't read
  // it). Scoped so the local doesn't clash across multiple draw paths.
  { struct { float a, d, r, s, sh, w; } _lt = { _lightAmbient, _lightDirect,
      _lightReflect, _lightSpecular, _lightShininess, _sssWrap };
    [_encoder setFragmentBytes:&_lt length:sizeof(_lt) atIndex:0]; }
  // Per-rep clip planes for the lit vbo_fragment / vbo_fragment_oit at fragment
  // buffer(1). enabled=0 (front<0) leaves the rep clipped only by the global slab.
  { struct { float front, back, enabled, pad; } _cl = { _repClipFront, _repClipBack,
      _repClipFront >= 0.0f ? 1.0f : 0.0f, 0.0f };
    [_encoder setFragmentBytes:&_cl length:sizeof(_cl) atIndex:1]; }

  // Flat (uniform-colored) geometry: supply the color the flat shader reads
  // from buffer 2. No per-vertex color is available here (the GL path would set
  // an a_Color uniform that the Metal backend drops), so render white — visible
  // and, crucially, non-crashing. TODO: thread the CGO's current color through.
  if (flat) {
    const float flatColor[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    [_encoder setVertexBytes:flatColor length:sizeof(flatColor) atIndex:2];
  }

  // Draw
  [_encoder drawPrimitives:toMTL(mode)
               vertexStart:0
               vertexCount:static_cast<NSUInteger>(vertexCount)];

  // --- Surface interior cap (stencil) — non-indexed (opaque surface) path.
  // MARK the slab's interior cross-section via stencil parity over the surface's
  // not-clipped faces, then FILL it flat at the near-plane sentinel depth.
  if (interiorCap && !_shadowMode && !_oitActive && _capFillPipeline &&
      _capMarkVtxFunc && _capMarkFragFunc) {
    if (!_capMarkPipeline || _capMarkStride != stride) {
      MTLVertexDescriptor* mvd = [[MTLVertexDescriptor alloc] init];
      mvd.attributes[0].format = MTLVertexFormatFloat3;
      mvd.attributes[0].offset = static_cast<NSUInteger>(posOffset < 0 ? 0 : posOffset);
      mvd.attributes[0].bufferIndex = 0;
      mvd.layouts[0].stride = static_cast<NSUInteger>(stride);
      mvd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
      MTLRenderPipelineDescriptor* mp = [[MTLRenderPipelineDescriptor alloc] init];
      mp.vertexFunction = _capMarkVtxFunc;
      mp.fragmentFunction = _capMarkFragFunc;
      mp.vertexDescriptor = mvd;
      mp.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      mp.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
      mp.rasterSampleCount = _sampleCount;
      mp.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      mp.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      NSError* me = nil;
      [_capMarkPipeline release];  // MRC: release the previous-stride pipeline (+1)
      _capMarkPipeline = [_device newRenderPipelineStateWithDescriptor:mp error:&me];
      _capMarkStride = stride;
      if (!_capMarkPipeline)
        NSLog(@"RendererMetal: cap mark pipeline failed: %@", me);
      [mvd release];  // MRC: descriptors (+1) consumed by pipeline creation
      [mp release];
    }
    if (_capMarkPipeline) {
      [_encoder setRenderPipelineState:_capMarkPipeline];
      [_encoder setDepthStencilState:_capMarkDSS];
      [_encoder setStencilReferenceValue:1];
      [_encoder setCullMode:MTLCullModeNone];
      [_encoder setVertexBuffer:vbo offset:0 atIndex:0];
      [_encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
  // Lighting (Scene sliders) for the lit vbo_fragment / vbo_fragment_oit at
  // fragment buffer(0). Harmless for the unlit/flat pipelines (they don't read
  // it). Scoped so the local doesn't clash across multiple draw paths.
  { struct { float a, d, r, s, sh, w; } _lt = { _lightAmbient, _lightDirect,
      _lightReflect, _lightSpecular, _lightShininess, _sssWrap };
    [_encoder setFragmentBytes:&_lt length:sizeof(_lt) atIndex:0]; }
      // MARK pass: per-rep clip (front-only) so stencil parity marks the cut at
      // the per-rep front plane; no-op (enabled=0) when per-rep clip is off.
      { struct { float front, back, enabled, pad; } _capcl = { _repClipFront, 1e6f,
          _repClipFront >= 0.0f ? 1.0f : 0.0f, 0.0f };
        [_encoder setFragmentBytes:&_capcl length:sizeof(_capcl) atIndex:1]; }
      [_encoder drawPrimitives:toMTL(mode)
                   vertexStart:0
                   vertexCount:static_cast<NSUInteger>(vertexCount)];
      [_encoder setRenderPipelineState:_capFillPipeline];
      [_encoder setDepthStencilState:_capFillDSS];
      { float capDepth = repCapDepth(_projectionMatrix.data(), _repClipFront);
        [_encoder setVertexBytes:&capDepth length:sizeof(capDepth) atIndex:0]; }
      const float interior[4] = {
          _capColorOverride ? _capColor[0] : 0.32f,
          _capColorOverride ? _capColor[1] : 0.32f,
          _capColorOverride ? _capColor[2] : 0.36f, 1.0f};
      [_encoder setFragmentBytes:interior length:sizeof(interior) atIndex:0];
      [_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [_encoder setCullMode:_cullFaceEnabled ? MTLCullModeBack : MTLCullModeNone];
      applyDepthStencilState();
      if (_depthStencilState) [_encoder setDepthStencilState:_depthStencilState];
    }
  }

  // Surface outer-contour: stash this (non-shadow) surface draw to be rendered
  // into the coverage mask after the scene (see runPostChain).
  if (_repContourEnabled && !_shadowMode) {
    CoverageDraw cd;
    cd.vbo = vbo; cd.ibo = nil; cd.count = vertexCount;
    cd.stride = stride; cd.posOffset = posOffset;
    std::memcpy(cd.modelview, _modelviewMatrix.data(), 64);
    std::memcpy(cd.projection, _projectionMatrix.data(), 64);
    cd.clipFront = _repClipFront; cd.clipBack = _repClipBack;
    _coverageDraws.push_back(cd);
    _contourActive = true;
  }

  // Per-rep AO/shadow exemption (#79): stash this cartoon/ribbon draw to be
  // rasterized into the AO-exempt mask after the scene (see renderAOExemptMask).
  if (_repAOExempt && !_shadowMode) {
    CoverageDraw cd;
    cd.vbo = vbo; cd.ibo = nil; cd.count = vertexCount;
    cd.stride = stride; cd.posOffset = posOffset;
    std::memcpy(cd.modelview, _modelviewMatrix.data(), 64);
    std::memcpy(cd.projection, _projectionMatrix.data(), 64);
    cd.clipFront = _repClipFront; cd.clipBack = _repClipBack;
    _aoExemptDraws.push_back(cd);
  }
}

void RendererMetal::drawVBOIndexed(PrimitiveType mode, int indexCount,
    const void* vertexData, size_t vertexDataSize, size_t stride,
    int posOffset, int normalOffset, int colorOffset, int colorType,
    const void* indexData, size_t indexDataSize, int interiorCap)
{
  if (!vertexData || !indexData || vertexDataSize == 0 ||
      indexDataSize == 0 || indexCount <= 0) return;
  ensureEncoder();
  if (!_encoder) return;

  // Ray tracing: capture solid triangle meshes (cartoon/surface) once per frame.
  if (_rtEnabled && !_shadowMode && !_oitActive)
    rtAppendVBOTris(_rtTris, mode, indexCount, vertexData, stride, posOffset, indexData);

  // Reuse cached Metal buffers
  id<MTLBuffer> vbo = nil;
  auto vboIt = _vboCache.find(vertexData);
  if (vboIt != _vboCache.end()) {
    vbo = vboIt->second;
  } else {
    vbo = [_device newBufferWithBytes:vertexData length:vertexDataSize options:MTLResourceStorageModeShared];
    if (vbo) _vboCache[vertexData] = vbo;
  }
  id<MTLBuffer> ibo = nil;
  auto iboIt = _vboCache.find(indexData);
  if (iboIt != _vboCache.end()) {
    ibo = iboIt->second;
  } else {
    ibo = [_device newBufferWithBytes:indexData length:indexDataSize options:MTLResourceStorageModeShared];
    if (ibo) _vboCache[indexData] = ibo;
  }
  if (!vbo || !ibo) return;

  // Build vertex descriptor
  MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
  if (posOffset >= 0) {
    vd.attributes[0].format = MTLVertexFormatFloat3;
    vd.attributes[0].offset = static_cast<NSUInteger>(posOffset);
    vd.attributes[0].bufferIndex = 0;
  }
  if (normalOffset >= 0) {
    vd.attributes[1].format = MTLVertexFormatFloat3;
    vd.attributes[1].offset = static_cast<NSUInteger>(normalOffset);
    vd.attributes[1].bufferIndex = 0;
  }
  if (colorOffset >= 0) {
    vd.attributes[2].format = (colorType == 0)
        ? MTLVertexFormatUChar4Normalized : MTLVertexFormatFloat4;
    vd.attributes[2].offset = static_cast<NSUInteger>(colorOffset);
    vd.attributes[2].bufferIndex = 0;
  }
  vd.layouts[0].stride = static_cast<NSUInteger>(stride);
  vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

  // Select or create pipeline (same logic as drawVBO)
  id<MTLRenderPipelineState> pipeline = nil;
  bool unlit = (normalOffset < 0);
  bool flat = unlit && (colorOffset < 0);  // uniform-colored: position-only shader
  // Shadow pre-pass: depth-only pipeline (e.g. surface stride 44 -> one-off).
  if (_shadowMode) {
    if (unlit) return;
    if (posOffset == 0 && normalOffset == 12 && colorOffset == 24) {
      if (colorType == 0 && stride == 28) pipeline = _vboShadowPipelineUByte;
      else if (colorType == 1 && stride == 40) pipeline = _vboShadowPipelineFloat;
    }
    if (!pipeline)
      pipeline = cachedVBOPipeline(VBOPipelineVariant::Shadow, stride,
          posOffset, normalOffset, colorOffset, colorType, vd);
    if (!pipeline) return;
  }
  if (!_shadowMode && !unlit && posOffset == 0 && normalOffset == 12 &&
      colorOffset == 24) {
    if (_oitActive) {
      if (colorType == 0 && stride == 28) pipeline = _vboOitPipelineUByte;
      else if (colorType == 1 && stride == 40) pipeline = _vboOitPipelineFloat;
    } else if (colorType == 0 && stride == 28 && _vboPipelineUByte) {
      pipeline = _vboPipelineUByte;
    } else if (colorType == 1 && stride == 40 && _vboPipelineFloat) {
      pipeline = _vboPipelineFloat;
    }
  }
  if (_oitActive && !pipeline) {
    if (unlit) return;
    pipeline = cachedVBOPipeline(VBOPipelineVariant::Oit, stride, posOffset,
                                 normalOffset, colorOffset, colorType, vd);
    if (!pipeline) return;
  }
  // Fallback for a non-prebuilt opaque layout: build-once via the layout cache.
  if (!pipeline) {
    VBOPipelineVariant v = flat ? VBOPipelineVariant::UnlitFlat
                                : (unlit ? VBOPipelineVariant::Unlit
                                         : VBOPipelineVariant::Lit);
    pipeline = cachedVBOPipeline(v, stride, posOffset, normalOffset,
                                 colorOffset, colorType, vd);
  }
  if (!pipeline) return;

  [_encoder setRenderPipelineState:pipeline];

  if (_shadowMode) {
    [_encoder setDepthStencilState:_shadowDepthState];
    // Front-face cull (mirrors drawVBO): store the depth of faces pointing AWAY
    // from the light so a closed surface (indexed triangles) can't self-shadow
    // its own light-facing front — without this the surface stored its near
    // faces and the front-center read as a dark "lit from below" band.
    [_encoder setCullMode:MTLCullModeFront];
  } else if (_oitActive) {
    [_encoder setDepthStencilState:oitDepthState()];
  } else {
    applyDepthStencilState();
    if (_depthStencilState) {
      [_encoder setDepthStencilState:_depthStencilState];
    }
  }

  [_encoder setVertexBuffer:vbo offset:0 atIndex:0];

  struct {
    float modelview[16];
    float projection[16];
    float pointSize;
    float _pad[3];
  } matrices;
  std::memcpy(matrices.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(matrices.projection, _projectionMatrix.data(), 64);
  matrices.pointSize = _pointSize > 0.0f ? _pointSize : 1.0f;
  matrices._pad[0] = matrices._pad[1] = matrices._pad[2] = 0.0f;
  [_encoder setVertexBytes:&matrices length:sizeof(matrices) atIndex:1];
  // Lighting (Scene sliders) for the lit vbo_fragment at fragment buffer(0).
  // Without this, indexed lit geometry (molecular surfaces) reads an unbound
  // LightU (ambient/direct = 0) and renders black. Mirrors drawVBO.
  { struct { float a, d, r, s, sh, w; } _lt = { _lightAmbient, _lightDirect,
      _lightReflect, _lightSpecular, _lightShininess, _sssWrap };
    [_encoder setFragmentBytes:&_lt length:sizeof(_lt) atIndex:0]; }
  // Per-rep clip planes for the lit vbo_fragment / vbo_fragment_oit at fragment
  // buffer(1). enabled=0 (front<0) leaves the rep clipped only by the global slab.
  { struct { float front, back, enabled, pad; } _cl = { _repClipFront, _repClipBack,
      _repClipFront >= 0.0f ? 1.0f : 0.0f, 0.0f };
    [_encoder setFragmentBytes:&_cl length:sizeof(_cl) atIndex:1]; }

  // Flat (uniform-colored) geometry reads its color from buffer 2 — see drawVBO.
  if (flat) {
    const float flatColor[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    [_encoder setVertexBytes:flatColor length:sizeof(flatColor) atIndex:2];
  }

  [_encoder drawIndexedPrimitives:toMTL(mode)
                       indexCount:static_cast<NSUInteger>(indexCount)
                        indexType:MTLIndexTypeUInt32
                      indexBuffer:ibo
                indexBufferOffset:0];

  // --- Surface interior cap (stencil) ---
  // For a clipped closed surface with metal_interior_cap on: MARK the slab's
  // interior cross-section (stencil parity over the not-clipped faces), then FILL
  // it with a flat darkened color at the near-plane sentinel depth (which the
  // post passes already exclude from SSAO/shadows). Opaque pass only.
  if (interiorCap && !_shadowMode && !_oitActive && _capFillPipeline &&
      _capMarkVtxFunc && _capMarkFragFunc) {
    if (!_capMarkPipeline || _capMarkStride != stride) {
      MTLVertexDescriptor* mvd = [[MTLVertexDescriptor alloc] init];
      mvd.attributes[0].format = MTLVertexFormatFloat3;
      mvd.attributes[0].offset = static_cast<NSUInteger>(posOffset < 0 ? 0 : posOffset);
      mvd.attributes[0].bufferIndex = 0;
      mvd.layouts[0].stride = static_cast<NSUInteger>(stride);
      mvd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
      MTLRenderPipelineDescriptor* mp = [[MTLRenderPipelineDescriptor alloc] init];
      mp.vertexFunction = _capMarkVtxFunc;
      mp.fragmentFunction = _capMarkFragFunc;
      mp.vertexDescriptor = mvd;
      mp.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      mp.colorAttachments[0].writeMask = MTLColorWriteMaskNone; // stencil only
      mp.rasterSampleCount = _sampleCount;
      mp.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      mp.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      NSError* me = nil;
      [_capMarkPipeline release];  // MRC: release the previous-stride pipeline (+1)
      _capMarkPipeline = [_device newRenderPipelineStateWithDescriptor:mp error:&me];
      _capMarkStride = stride;
      if (!_capMarkPipeline)
        NSLog(@"RendererMetal: cap mark pipeline failed: %@", me);
      [mvd release];  // MRC: descriptors (+1) consumed by pipeline creation
      [mp release];
    }
    if (_capMarkPipeline) {
      [_encoder setRenderPipelineState:_capMarkPipeline];
      [_encoder setDepthStencilState:_capMarkDSS];
      [_encoder setStencilReferenceValue:1];
      [_encoder setCullMode:MTLCullModeNone];
      [_encoder setVertexBuffer:vbo offset:0 atIndex:0];
      [_encoder setVertexBytes:&matrices length:sizeof(matrices) atIndex:1];
      // MARK pass: per-rep clip (front-only) so stencil parity marks the cut at
      // the per-rep front plane; no-op (enabled=0) when per-rep clip is off.
      { struct { float front, back, enabled, pad; } _capcl = { _repClipFront, 1e6f,
          _repClipFront >= 0.0f ? 1.0f : 0.0f, 0.0f };
        [_encoder setFragmentBytes:&_capcl length:sizeof(_capcl) atIndex:1]; }
      [_encoder drawIndexedPrimitives:toMTL(mode)
                           indexCount:static_cast<NSUInteger>(indexCount)
                            indexType:MTLIndexTypeUInt32
                          indexBuffer:ibo
                    indexBufferOffset:0];
      [_encoder setRenderPipelineState:_capFillPipeline];
      [_encoder setDepthStencilState:_capFillDSS];
      { float capDepth = repCapDepth(_projectionMatrix.data(), _repClipFront);
        [_encoder setVertexBytes:&capDepth length:sizeof(capDepth) atIndex:0]; }
      const float interior[4] = {
          _capColorOverride ? _capColor[0] : 0.32f,
          _capColorOverride ? _capColor[1] : 0.32f,
          _capColorOverride ? _capColor[2] : 0.36f, 1.0f}; // darkened interior
      [_encoder setFragmentBytes:interior length:sizeof(interior) atIndex:0];
      [_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      // Restore default state for subsequent geometry.
      [_encoder setCullMode:_cullFaceEnabled ? MTLCullModeBack : MTLCullModeNone];
      applyDepthStencilState();
      if (_depthStencilState) [_encoder setDepthStencilState:_depthStencilState];
    }
  }

  // Surface outer-contour: stash this (non-shadow) surface draw to be rendered
  // into the coverage mask after the scene (see runPostChain).
  if (_repContourEnabled && !_shadowMode) {
    CoverageDraw cd;
    cd.vbo = vbo; cd.ibo = ibo; cd.count = indexCount;
    cd.stride = stride; cd.posOffset = posOffset;
    std::memcpy(cd.modelview, _modelviewMatrix.data(), 64);
    std::memcpy(cd.projection, _projectionMatrix.data(), 64);
    cd.clipFront = _repClipFront; cd.clipBack = _repClipBack;
    _coverageDraws.push_back(cd);
    _contourActive = true;
  }

  // Per-rep AO/shadow exemption (#79): stash this cartoon/ribbon draw to be
  // rasterized into the AO-exempt mask after the scene (see renderAOExemptMask).
  if (_repAOExempt && !_shadowMode) {
    CoverageDraw cd;
    cd.vbo = vbo; cd.ibo = ibo; cd.count = indexCount;
    cd.stride = stride; cd.posOffset = posOffset;
    std::memcpy(cd.modelview, _modelviewMatrix.data(), 64);
    std::memcpy(cd.projection, _projectionMatrix.data(), 64);
    cd.clipFront = _repClipFront; cd.clipBack = _repClipBack;
    _aoExemptDraws.push_back(cd);
  }
}

void RendererMetal::invalidateVBOCache(uint64_t key)
{
  // Clear entire cache — key type changed to pointer-based.
  // MRC: the map holds +1 MTLBuffers (newBufferWithBytes); STL clear() does not
  // release them, so drop each ownership first. Any buffer still referenced by an
  // in-flight command buffer is kept alive by Metal's own retain until that
  // command buffer completes (same reasoning as ensurePostTargets).
  for (auto& kv : _vboCache) [kv.second release];
  _vboCache.clear();
}

// ---------------------------------------------------------------------------
#pragma mark - Impostor Ray-Casting (analytic spheres)
// ---------------------------------------------------------------------------

// Inline MSL port of data/shaders/sphere.vs + sphere.fs. Per-pixel ray-sphere
// intersection with [[depth(any)]] output and diffuse + Blinn-Phong specular.
static NSString* const kSphereImpostorSrc = @R"(
#include <metal_stdlib>
using namespace metal;

struct SphereIn {
  float4 vertex_radius [[attribute(0)]];  // center xyz + radius
  float4 color         [[attribute(1)]];  // UByte4Norm -> float4
  float  rightUpFlags  [[attribute(2)]];
};
struct SphereU {
  float4x4 modelview;
  float4x4 projection;
  float sphere_size_scale;
  float ortho;          // 1 = orthographic
  float depthZeroToOne; // 1 if clip Z already [0,1]; else apply 0.5+0.5 remap
  float interiorCap;    // 1 = cap the slab cross-section with a solid interior color
  float4 interiorColor; // rgb cap color; .a > 0.5 => use it (else atom*0.45)
  // PyMOL lighting model (Scene sliders): ambient/direct/reflect/spec/shininess.
  float lAmbient, lDirect, lReflect, lSpecular, lShininess, lSSSWrap;
};
struct SphereVOut {
  float4 position [[position]];
  float4 color;
  float3 sphere_center;  // eye space
  float  radius2;
  float3 point;          // eye-space impostor point
};
struct SphereFOut {
  float4 color [[color(0)]];
  float  depth [[depth(any)]];
};

static float2 outer_tangent_adjustment(float3 center, float radius_sq) {
  float2 xy_dist = float2(length(center.xz), length(center.yz));
  float2 cos_a = clamp(center.z / xy_dist, -1.0, 1.0);
  float2 cos_b = xy_dist / sqrt(radius_sq + (xy_dist * xy_dist));
  float2 cos_ab = cos_a * cos_b + sqrt((1.0 - cos_a*cos_a) * (1.0 - cos_b*cos_b));
  float2 cos_ab_sq = cos_ab * cos_ab;
  float2 tan_ab_sq = (1.0 - cos_ab_sq) / cos_ab_sq;
  return min(sqrt(tan_ab_sq + 1.0), 10.0);
}

vertex SphereVOut sphere_impostor_vertex(SphereIn in [[stage_in]],
    constant SphereU& u [[buffer(1)]]) {
  SphereVOut out;
  float radius = in.vertex_radius.w * u.sphere_size_scale;
  float3 mvcol0 = float3(u.modelview[0].x, u.modelview[0].y, u.modelview[0].z);
  radius /= max(length(mvcol0), 1e-6);
  float right = -1.0 + 2.0 * fmod(in.rightUpFlags, 2.0);
  float up    = -1.0 + 2.0 * floor(fmod(in.rightUpFlags / 2.0, 2.0));
  float4 tmppos = u.modelview * float4(in.vertex_radius.xyz, 1.0);
  out.color = in.color;
  out.radius2 = radius * radius;
  float2 corner = float2(right, up);
  if (u.ortho < 0.5)
    corner *= outer_tangent_adjustment(tmppos.xyz, out.radius2);
  float4 eyePos = tmppos;
  eyePos.xy += radius * corner;
  out.sphere_center = tmppos.xyz / tmppos.w;
  out.point = eyePos.xyz / eyePos.w;
  out.position = u.projection * eyePos;
  // GL->Metal clip-z remap (matches the VBO and the impostor fragment depth) so
  // the near half of the frustum (GL ndcz [-1,0)) isn't clipped — front atoms
  // stay visible instead of being sliced off by Metal's z>=0 clip volume.
  out.position.z = 0.5 * (out.position.z + out.position.w);
  return out;
}

// Weighted-blended OIT output for transparent spheres (accum + reveal + the
// ray-cast depth, so opaque geometry still occludes them).
struct SphereOITOut {
  float4 accum  [[color(0)]];
  float  reveal [[color(1)]];
  float  depth  [[depth(any)]];
};
static float sph_oit_weight(float a, float z) {
  return clamp(pow(min(1.0, a * 10.0) + 0.01, 3.0) * 1e8 *
               pow(1.0 - z * 0.9, 3.0), 1e-2, 3e3);
}

// Shared ray-sphere intersection + PyMOL two-light shading. Discards on miss /
// out-of-range depth. Returns lit rgb, alpha, and window depth.
static void sphere_shade(SphereVOut in, constant SphereU& u,
    thread float3& rgb, thread float& alpha, thread float& depth) {
  float3 ray_origin, ray_dir, sphere_dir;
  if (u.ortho >= 0.5) {
    ray_origin = in.point; ray_dir = float3(0.0,0.0,-1.0);
    sphere_dir = ray_origin - in.sphere_center;
  } else {
    ray_origin = float3(0.0); ray_dir = normalize(in.point);
    sphere_dir = in.sphere_center;
  }
  float b = dot(sphere_dir, ray_dir);
  float position = b*b + in.radius2 - dot(sphere_dir, sphere_dir);
  if (position < 0.0) discard_fragment();
  float nearest = b - sqrt(position);
  float3 ipoint = nearest * ray_dir + ray_origin;
  float4 clip = u.projection * float4(ipoint, 1.0);
  float ndcz = clip.z / clip.w;
  depth = (u.depthZeroToOne >= 0.5) ? ndcz : (0.5 + 0.5 * ndcz);

  if (depth >= 1.0) discard_fragment();   // behind the far plane
  if (depth <= 0.0) {
    // The near (slab) plane cuts in front of this surface point. If the BACK of
    // the sphere is still inside the slab, the plane slices through the sphere:
    // cap the cross-section with a flat interior color, else discard (=see-thru).
    if (u.interiorCap < 0.5) discard_fragment();
    float farthest = b + sqrt(position);
    float3 fpoint = farthest * ray_dir + ray_origin;
    float4 fclip = u.projection * float4(fpoint, 1.0);
    float fdepth = (u.depthZeroToOne >= 0.5) ? (fclip.z / fclip.w)
                                             : (0.5 + 0.5 * fclip.z / fclip.w);
    if (fdepth <= 0.0) discard_fragment();  // whole sphere in front of the slab
    depth = 1e-5;                           // flat disc at the slab plane (front)
    rgb = (u.interiorColor.a > 0.5) ? u.interiorColor.rgb  // ray_interior_color
                                    : in.color.rgb * 0.45; // else atom darkened
    alpha = in.color.a;
    return;
  }
  float3 normal = normalize(ipoint - in.sphere_center);

  // PyMOL two-light model, driven by the live ambient/direct/reflect/specular/
  // shininess settings (Scene sliders) uploaded in SphereU.
  float ambient    = u.lAmbient;
  float direct     = u.lDirect;
  float reflect    = u.lReflect;
  float spec_value = u.lSpecular;
  float shininess  = max(u.lShininess, 1.0);
  const float3 L0 = float3(0.0, 0.0, 1.0);
  const float3 L1 = normalize(float3(0.4, 0.4, 1.0));
  float intensity = ambient;
  float specular = 0.0;
  float n0 = dot(normal, L0);
  intensity += direct * saturate((n0 + u.lSSSWrap) / (1.0 + u.lSSSWrap));
  float n1 = dot(normal, L1);
  intensity += reflect * saturate((n1 + u.lSSSWrap) / (1.0 + u.lSSSWrap));
  if (n1 > 0.0) {
    float3 H1 = normalize(L1 + float3(0.0, 0.0, 1.0));
    specular += spec_value * pow(max(dot(normal, H1), 0.0), shininess);
  }
  rgb = in.color.rgb * min(intensity, 1.0) + specular;
  alpha = in.color.a;
}

fragment SphereFOut sphere_impostor_fragment(SphereVOut in [[stage_in]],
    constant SphereU& u [[buffer(1)]]) {
  float3 rgb; float a; float depth;
  sphere_shade(in, u, rgb, a, depth);
  SphereFOut out;
  out.color = float4(rgb, a);
  out.depth = depth;
  return out;
}

fragment SphereOITOut sphere_impostor_fragment_oit(SphereVOut in [[stage_in]],
    constant SphereU& u [[buffer(1)]]) {
  float3 rgb; float a; float depth;
  sphere_shade(in, u, rgb, a, depth);
  float w = sph_oit_weight(a, depth);
  SphereOITOut out;
  out.accum = float4(rgb * a, a) * w;
  out.reveal = a;
  out.depth = depth;
  return out;
}

// Shadow pre-pass: depth-only. u.projection is the light VP (eye space), so the
// ray-cast intersection's depth is the light-space window depth. Reusing the
// same ray-cast keeps the analytic round silhouette and self-consistency with
// the receiver (which reconstructs the same camera-near point).
struct SphereShadowOut { float depth [[depth(any)]]; };
fragment SphereShadowOut sphere_impostor_fragment_shadow(
    SphereVOut in [[stage_in]], constant SphereU& u [[buffer(1)]]) {
  float3 rgb; float a; float depth;
  sphere_shade(in, u, rgb, a, depth);  // discards on ray miss
  SphereShadowOut out; out.depth = depth; return out;
}
)";

void RendererMetal::buildImpostorPipelines()
{
  if (_sphereImpostorPipeline) return;
  NSError* err = nil;
  id<MTLLibrary> lib = [_device newLibraryWithSource:kSphereImpostorSrc
                                             options:nil error:&err];
  if (!lib) { NSLog(@"RendererMetal: sphere impostor compile failed: %@", err); return; }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"sphere_impostor_vertex"];
  id<MTLFunction> ffn = [lib newFunctionWithName:@"sphere_impostor_fragment"];
  if (!vfn || !ffn) { NSLog(@"RendererMetal: sphere impostor funcs missing"); return; }

  MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
  vd.attributes[0].format = MTLVertexFormatFloat4;           // a_vertex_radius
  vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0;
  vd.attributes[1].format = MTLVertexFormatUChar4Normalized; // a_Color
  vd.attributes[1].offset = 16; vd.attributes[1].bufferIndex = 0;
  vd.attributes[2].format = MTLVertexFormatFloat;            // a_rightUpFlags
  vd.attributes[2].offset = 20; vd.attributes[2].bufferIndex = 0;
  vd.layouts[0].stride = 24;
  vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

  MTLRenderPipelineDescriptor* psd = [[MTLRenderPipelineDescriptor alloc] init];
  psd.vertexFunction = vfn; psd.fragmentFunction = ffn; psd.vertexDescriptor = vd;
  psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  psd.colorAttachments[0].blendingEnabled = YES;
  psd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  psd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  psd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  psd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  psd.rasterSampleCount = _sampleCount;
  psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  _sphereImpostorPipeline = [_device newRenderPipelineStateWithDescriptor:psd error:&err];
  if (!_sphereImpostorPipeline)
    NSLog(@"RendererMetal: sphere impostor pipeline failed: %@", err);

  // Transparent sphere OIT variant: same vertex shader + geometry, MRT
  // accum/reveal output, ray-cast depth retained for occlusion.
  id<MTLFunction> offn = [lib newFunctionWithName:@"sphere_impostor_fragment_oit"];
  if (offn) {
    MTLRenderPipelineDescriptor* op = [[MTLRenderPipelineDescriptor alloc] init];
    op.vertexFunction = vfn; op.fragmentFunction = offn; op.vertexDescriptor = vd;
    op.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    op.colorAttachments[0].blendingEnabled = YES;
    op.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    op.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    op.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    op.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    op.colorAttachments[1].pixelFormat = MTLPixelFormatR16Float;
    op.colorAttachments[1].blendingEnabled = YES;
    op.colorAttachments[1].sourceRGBBlendFactor = MTLBlendFactorZero;
    op.colorAttachments[1].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceColor;
    op.colorAttachments[1].sourceAlphaBlendFactor = MTLBlendFactorZero;
    op.colorAttachments[1].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceColor;
    op.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    op.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    _sphereOitPipeline = [_device newRenderPipelineStateWithDescriptor:op error:&err];
    if (!_sphereOitPipeline)
      NSLog(@"RendererMetal: sphere OIT pipeline failed: %@", err);
  }

  // Shadow-map variant: depth-only, single-sample (no color, Depth32Float).
  id<MTLFunction> sfn = [lib newFunctionWithName:@"sphere_impostor_fragment_shadow"];
  if (sfn) {
    MTLRenderPipelineDescriptor* sp = [[MTLRenderPipelineDescriptor alloc] init];
    sp.vertexFunction = vfn; sp.fragmentFunction = sfn; sp.vertexDescriptor = vd;
    sp.rasterSampleCount = 1;
    sp.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    _sphereShadowPipeline = [_device newRenderPipelineStateWithDescriptor:sp error:&err];
    if (!_sphereShadowPipeline)
      NSLog(@"RendererMetal: sphere shadow pipeline failed: %@", err);
  }
}

void RendererMetal::drawSphereImpostors(const SphereImpostorDrawCall& call)
{
  if (!call.data || call.dataSize == 0 || call.sphereCount <= 0) return;
  ensureEncoder();
  if (!_encoder) return;
  buildImpostorPipelines();
  if (!_sphereImpostorPipeline) return;
  if (_oitActive && !_sphereOitPipeline) return; // no OIT variant: skip
  if (_shadowMode && !_sphereShadowPipeline) return; // can't cast: skip safely

  // Only the canonical packing (pos@0, color@16, rightUp@20 Float, stride 24)
  // is handled by the prebuilt pipeline. Log and bail otherwise (revisit if hit).
  bool common = (call.posRadiusOff == 0 && call.colorOff == 16 &&
                 call.rightUpOff == 20 && call.stride == 24 && call.rightUpIsFloat);
  if (!common) {
    NSLog(@"RendererMetal: sphere impostor non-standard packing pos=%d col=%d ru=%d(float=%d) stride=%zu",
          call.posRadiusOff, call.colorOff, call.rightUpOff, call.rightUpIsFloat, call.stride);
    return;
  }

  id<MTLBuffer> vbo = nil;
  auto it = _vboCache.find(call.data);
  if (it != _vboCache.end()) vbo = it->second;
  else {
    vbo = [_device newBufferWithBytes:call.data length:call.dataSize
                              options:MTLResourceStorageModeShared];
    if (!vbo) return;
    _vboCache[call.data] = vbo;
  }

  // The impostor VBO is a plain triangle list (our build emits 6 verts/sphere
  // with corner flags {0,1,3,3,2,0}); draw all verts directly, no index buffer.
  NSUInteger vertexCount = call.stride ? (call.dataSize / call.stride) : 0;
  if (vertexCount < 3) return;

  // Ray tracing: accumulate model-space sphere centers + radii once per frame
  // (only the main opaque pass, not the shadow/OIT replays). Each sphere is 6
  // consecutive verts sharing the same a_vertex_radius (float4 @ offset 0).
  if (_rtEnabled && !_shadowMode && !_oitActive) {
    const uint8_t* base = static_cast<const uint8_t*>(call.data);
    NSUInteger nSph = vertexCount / 6;
    _rtSpheres.reserve(_rtSpheres.size() + nSph * 4);
    for (NSUInteger k = 0; k < nSph; ++k) {
      const float* c = reinterpret_cast<const float*>(base + (6 * k) * call.stride + call.posRadiusOff);
      _rtSpheres.push_back(c[0]);
      _rtSpheres.push_back(c[1]);
      _rtSpheres.push_back(c[2]);
      _rtSpheres.push_back(c[3] * call.sphereSizeScale);
    }
  }

  if (_shadowMode) {
    [_encoder setRenderPipelineState:_sphereShadowPipeline];
    [_encoder setDepthStencilState:_shadowDepthState]; // LESS + write (light POV)
    [_encoder setCullMode:MTLCullModeNone]; // billboards: don't inherit VBO cull-front
  } else if (_oitActive) {
    [_encoder setRenderPipelineState:_sphereOitPipeline];
    [_encoder setDepthStencilState:oitDepthState()];
  } else {
    [_encoder setRenderPipelineState:_sphereImpostorPipeline];
    applyDepthStencilState();
    if (_depthStencilState) [_encoder setDepthStencilState:_depthStencilState];
  }
  [_encoder setVertexBuffer:vbo offset:0 atIndex:0];

  struct {
    float modelview[16];
    float projection[16];
    float sphere_size_scale;
    float ortho;
    float depthZeroToOne;
    float interiorCap;
    float interiorColor[4];
    float lAmbient, lDirect, lReflect, lSpecular, lShininess, lSSSWrap;
  } u;
  std::memcpy(u.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(u.projection, _projectionMatrix.data(), 64);
  u.lAmbient = _lightAmbient; u.lDirect = _lightDirect;
  u.lReflect = _lightReflect; u.lSpecular = _lightSpecular;
  u.lShininess = _lightShininess;
  u.lSSSWrap = _sssWrap;
  u.sphere_size_scale = call.sphereSizeScale;
  u.ortho = (float)call.ortho;
  // Projection is GL-convention ([-1,1] clip Z): remap to [0,1] for Metal's
  // fragment depth (matches the GL sphere.fs `0.5 + 0.5 * clipZ/clipW`).
  u.depthZeroToOne = 0.0f;
  // Cap the slab cross-section only in the opaque pass (not shadow/OIT).
  u.interiorCap = (call.interiorCap && !_shadowMode && !_oitActive) ? 1.0f : 0.0f;
  // ray_interior_color: .a>0.5 => use this rgb for the cap (else atom*0.45).
  u.interiorColor[0] = _capColor[0]; u.interiorColor[1] = _capColor[1];
  u.interiorColor[2] = _capColor[2]; u.interiorColor[3] = _capColorOverride ? 1.0f : 0.0f;
  [_encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
  // The fragment shader also reads `u` (projection for depth, ortho flag) at
  // buffer index 1 — it must be bound to the fragment stage too, otherwise it
  // reads zero and clip.z/clip.w = 0/0 = NaN (all fragments fail the depth
  // range test / produce garbage depth).
  [_encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];

  [_encoder drawPrimitives:MTLPrimitiveTypeTriangle
               vertexStart:0
               vertexCount:vertexCount];
}

// ---------------------------------------------------------------------------
#pragma mark - Impostor Ray-Casting (analytic cylinders)
// ---------------------------------------------------------------------------

// Inline MSL port of data/shaders/cylinder.vs + cylinder.fs. An 8-vertex box
// impostor (36 indices) with per-pixel ray-cylinder intersection, flat/round
// caps, two-color interpolation along the bond, [[depth(any)]] output, and the
// same PyMOL two-light shading as the sphere impostor. `a_cap` is supplied as a
// uniform constant (cap_const), not a vertex attribute.
static NSString* const kCylinderImpostorSrc = @R"(
#include <metal_stdlib>
using namespace metal;

struct CylIn {
  float3 vertex1 [[attribute(0)]];
  float3 vertex2 [[attribute(1)]];
  float4 color   [[attribute(2)]];
  float4 color2  [[attribute(3)]];
  float  radius  [[attribute(4)]];
  uchar  flags   [[attribute(5)]];
};
struct CylU {
  float4x4 modelview;
  float4x4 projection;
  float uni_radius;
  float ortho;
  float depthZeroToOne;
  float no_flat_caps;
  float cap_const;
  float half_bond;
  float inv_height;
  float interiorCap;    // 1 = cap the slab cross-section with a solid interior color
  float4 interiorColor; // rgb cap color; .a > 0.5 => use it (else bond*0.45)
  // PyMOL lighting model (Scene sliders): ambient/direct/reflect/spec/shininess.
  float lAmbient, lDirect, lReflect, lSpecular, lShininess, lSSSWrap;
};
struct CylVOut {
  float4 position [[position]];
  float3 surface_point;
  float3 axis;
  float3 base;
  float3 end_cyl;
  float3 U;
  float3 V;
  float radius;
  float inv_sqr_height;
  float4 color1;
  float4 color2;
};
struct CylFOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };

static float cyl_bit(thread float& bits) {
  float bit = fmod(bits, 2.0);
  bits = (bits - bit) / 2.0;
  return step(0.5, bit);
}

vertex CylVOut cyl_impostor_vertex(CylIn in [[stage_in]],
    constant CylU& u [[buffer(1)]]) {
  CylVOut o;
  // Normal matrix == upper-left 3x3 of the (rotation+uniform-scale) modelview.
  float3x3 N = float3x3(u.modelview[0].xyz, u.modelview[1].xyz, u.modelview[2].xyz);
  float uniformglscale = length(N[0]);
  float radius = (u.uni_radius != 0.0) ? (u.uni_radius * in.radius) : in.radius;
  o.color1 = in.color;
  o.color2 = in.color2;
  float3 attr_axis = in.vertex2 - in.vertex1;
  float ish = length(attr_axis) / uniformglscale;
  ish *= ish;
  o.inv_sqr_height = 1.0 / ish;
  float3 h = normalize(attr_axis);
  o.axis = normalize(N * h);
  float3 uu = cross(h, float3(1.0, 0.0, 0.0));
  if (dot(uu, uu) < 0.001) uu = cross(h, float3(0.0, 1.0, 0.0));
  uu = normalize(uu);
  float3 vv = normalize(cross(uu, h));
  o.U = normalize(N * uu);
  o.V = normalize(N * vv);
  float4 base4 = u.modelview * float4(in.vertex1, 1.0); o.base = base4.xyz;
  float4 end4  = u.modelview * float4(in.vertex2, 1.0); o.end_cyl = end4.xyz;

  float4 vert = float4(in.vertex1, 1.0);
  float packed = float(in.flags);
  float out_v   = cyl_bit(packed);
  float up_v    = cyl_bit(packed);
  float right_v = cyl_bit(packed);
  vert.xyz += up_v * attr_axis;
  vert.xyz += (2.0 * right_v - 1.0) * radius * uu;
  vert.xyz += (2.0 * out_v   - 1.0) * radius * vv;
  vert.xyz += (2.0 * up_v    - 1.0) * radius * h;

  float4 tvertex = u.modelview * vert;
  o.surface_point = tvertex.xyz;
  float4 pos = u.projection * tvertex;

  // Clamp z on the front clipping plane if the impostor box would be clipped
  // (we want to clip on the per-pixel depth, not the box face). See cylinder.vs.
  if (pos.z / pos.w < -1.0) {
    float diff = abs(base4.z - end4.z) + radius * 3.5;
    float4 inset = u.modelview * vert;
    inset.z -= diff;
    inset = u.projection * inset;
    if (inset.z / inset.w > -1.0) pos.z = -pos.w;
  }
  // GL->Metal clip-z remap, AFTER the GL-convention near clamp above: the GL
  // near plane (ndcz -1) maps to Metal z 0, so the near half of the box isn't
  // clipped away (front sticks stay visible). Matches the VBO + fragment depth.
  pos.z = 0.5 * (pos.z + pos.w);
  o.position = pos;
  o.radius = radius / uniformglscale;
  return o;
}

struct CylOITOut {
  float4 accum  [[color(0)]];
  float  reveal [[color(1)]];
  float  depth  [[depth(any)]];
};
static float cyl_oit_weight(float a, float z) {
  return clamp(pow(min(1.0, a * 10.0) + 0.01, 3.0) * 1e8 *
               pow(1.0 - z * 0.9, 3.0), 1e-2, 3e3);
}

// Shared ray-cylinder intersection (caps + two-color interp) + PyMOL shading.
// Discards on miss; returns lit rgb, alpha, window depth.
static void cyl_shade(CylVOut in, constant CylU& u,
    thread float3& rgb, thread float& alpha, thread float& depth) {
  float3 ray_target = in.surface_point;
  float3 ray_origin, ray_dir;
  if (u.ortho >= 0.5) { ray_origin = in.surface_point; ray_dir = float3(0.0,0.0,1.0); }
  else { ray_origin = float3(0.0); ray_dir = normalize(-ray_target); }

  float3x3 basis = float3x3(in.U, in.V, in.axis);
  float2 P = ((ray_target - in.base) * basis).xy;
  float2 D = (ray_dir * basis).xy;
  float radius2 = in.radius * in.radius;
  float a0 = P.x*P.x + P.y*P.y - radius2;
  float a1 = P.x*D.x + P.y*D.y;
  float a2 = D.x*D.x + D.y*D.y;
  float d = a1*a1 - a0*a2;
  if (d < 0.0) discard_fragment();
  float dist = (-a1 + sqrt(d)) / a2;
  float3 new_point = ray_target + dist * ray_dir;
  float3 tmp_point = new_point - in.base;
  float3 normal = normalize(tmp_point - in.axis * dot(tmp_point, in.axis));

  // cap bits: 0 frontcap, 1 endcap, 2 frontcapround, 3 endcapround, 4 interp
  float fcap = u.cap_const + 0.001;
  bool frontcap      = cyl_bit(fcap) > 0.5;
  bool endcap        = cyl_bit(fcap) > 0.5;
  bool frontcapround = (cyl_bit(fcap) > 0.5) && (u.no_flat_caps > 0.5);
  bool endcapround   = (cyl_bit(fcap) > 0.5) && (u.no_flat_caps > 0.5);
  bool nocolorinterp = !(cyl_bit(fcap) > 0.5);

  float ratio = dot(new_point - in.base, in.end_cyl - in.base) * in.inv_sqr_height;
  if (nocolorinterp) {
    float dp = clamp(-u.half_bond * new_point.z * u.inv_height, 0.0, 0.5);
    ratio = smoothstep(0.5 - dp, 0.5 + dp, ratio);
  } else {
    ratio = clamp(ratio, 0.0, 1.0);
  }
  float4 color = mix(in.color1, in.color2, ratio);

  bool cap_test_base = 0.0 > dot(new_point - in.base, in.axis);
  bool cap_test_end  = 0.0 < dot(new_point - in.end_cyl, in.axis);
  if (cap_test_base || cap_test_end) {
    float3 thisaxis = -in.axis;
    float3 thisbase = in.base;
    if (cap_test_end) {
      thisaxis = in.axis; thisbase = in.end_cyl;
      frontcap = endcap; frontcapround = endcapround;
    }
    if (!frontcap) discard_fragment();
    if (frontcapround) {
      float3 sd = thisbase - ray_origin;
      float b = dot(sd, ray_dir);
      float pos = b*b + radius2 - dot(sd, sd);
      if (pos < 0.0) discard_fragment();
      float nr = sqrt(pos) + b;
      new_point = nr * ray_dir + ray_origin;
      normal = normalize(new_point - thisbase);
    } else {
      float dNV = dot(thisaxis, ray_dir);
      if (dNV < 0.0) discard_fragment();
      float nr = dot(thisaxis, thisbase - ray_origin) / dNV;
      new_point = ray_dir * nr + ray_origin;
      if (dot(new_point - thisbase, new_point - thisbase) > radius2) discard_fragment();
      normal = thisaxis;
    }
  }

  float4 clip = u.projection * float4(new_point, 1.0);
  float ndcz = clip.z / clip.w;
  depth = (u.depthZeroToOne >= 0.5) ? ndcz : (0.5 + 0.5 * ndcz);
  if (depth <= 0.0) {
    // Surface point is in front of the slab. If the cylinder body still straddles
    // the slab (its far wall is inside), cap the cross-section with a flat
    // interior color instead of discarding (= see-through). Else discard.
    if (u.interiorCap < 0.5) discard_fragment();
    float dist2 = (-a1 - sqrt(d)) / a2;            // far body intersection
    float3 p2 = ray_target + dist2 * ray_dir;
    float4 c2 = u.projection * float4(p2, 1.0);
    float d2 = (u.depthZeroToOne >= 0.5) ? (c2.z / c2.w) : (0.5 + 0.5 * c2.z / c2.w);
    if (d2 <= 0.0) discard_fragment();             // whole stick in front of slab
    depth = 1e-5;                                  // flat disc at the slab plane
    rgb = (u.interiorColor.a > 0.5) ? u.interiorColor.rgb  // ray_interior_color
                                    : color.rgb * 0.45;    // else bond darkened
    alpha = color.a;
    return;
  }

  // PyMOL two-light model, driven by the live lighting settings in CylU.
  float ambient    = u.lAmbient;
  float direct     = u.lDirect;
  float reflect    = u.lReflect;
  float spec_value = u.lSpecular;
  float shininess  = max(u.lShininess, 1.0);
  const float3 L0 = float3(0.0, 0.0, 1.0);
  const float3 L1 = normalize(float3(0.4, 0.4, 1.0));
  float intensity = ambient;
  float specular = 0.0;
  float n0 = dot(normal, L0);
  intensity += direct * saturate((n0 + u.lSSSWrap) / (1.0 + u.lSSSWrap));
  float n1 = dot(normal, L1);
  intensity += reflect * saturate((n1 + u.lSSSWrap) / (1.0 + u.lSSSWrap));
  if (n1 > 0.0) {
    float3 H1 = normalize(L1 + float3(0.0, 0.0, 1.0));
    specular += spec_value * pow(max(dot(normal, H1), 0.0), shininess);
  }
  rgb = color.rgb * min(intensity, 1.0) + specular;
  alpha = color.a;
}

fragment CylFOut cyl_impostor_fragment(CylVOut in [[stage_in]],
    constant CylU& u [[buffer(1)]]) {
  float3 rgb; float a; float depth;
  cyl_shade(in, u, rgb, a, depth);
  CylFOut o;
  o.color = float4(rgb, a);
  o.depth = depth;
  return o;
}

fragment CylOITOut cyl_impostor_fragment_oit(CylVOut in [[stage_in]],
    constant CylU& u [[buffer(1)]]) {
  float3 rgb; float a; float depth;
  cyl_shade(in, u, rgb, a, depth);
  float w = cyl_oit_weight(a, depth);
  CylOITOut o;
  o.accum = float4(rgb * a, a) * w;
  o.reveal = a;
  o.depth = depth;
  return o;
}

// Shadow pre-pass: depth-only. u.projection is the light VP, so the ray-cast
// intersection writes light-space window depth (cap geometry preserved).
struct CylShadowOut { float depth [[depth(any)]]; };
fragment CylShadowOut cyl_impostor_fragment_shadow(CylVOut in [[stage_in]],
    constant CylU& u [[buffer(1)]]) {
  float3 rgb; float a; float depth;
  cyl_shade(in, u, rgb, a, depth);  // discards on ray miss
  CylShadowOut o; o.depth = depth; return o;
}
)";

void RendererMetal::buildCylinderImpostorPipeline(
    const CylinderImpostorDrawCall& call)
{
  if (_cylinderImpostorPipeline && _cylinderPipelineStride == call.stride)
    return; // already built for this layout
  _cylinderImpostorPipeline = nil;

  NSError* err = nil;
  id<MTLLibrary> lib = [_device newLibraryWithSource:kCylinderImpostorSrc
                                             options:nil error:&err];
  if (!lib) { NSLog(@"RendererMetal: cyl impostor compile failed: %@", err); return; }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"cyl_impostor_vertex"];
  id<MTLFunction> ffn = [lib newFunctionWithName:@"cyl_impostor_fragment"];
  if (!vfn || !ffn) { NSLog(@"RendererMetal: cyl impostor funcs missing"); return; }

  MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
  vd.attributes[0].format = MTLVertexFormatFloat3;       // attr_vertex1
  vd.attributes[0].offset = call.v1Off;     vd.attributes[0].bufferIndex = 0;
  vd.attributes[1].format = MTLVertexFormatFloat3;       // attr_vertex2
  vd.attributes[1].offset = call.v2Off;     vd.attributes[1].bufferIndex = 0;
  MTLVertexFormat colFmt = call.colorIsFloat ? MTLVertexFormatFloat4
                                             : MTLVertexFormatUChar4Normalized;
  vd.attributes[2].format = colFmt;                      // a_Color
  vd.attributes[2].offset = call.colorOff;  vd.attributes[2].bufferIndex = 0;
  vd.attributes[3].format = colFmt;                      // a_Color2
  vd.attributes[3].offset = call.color2Off; vd.attributes[3].bufferIndex = 0;
  vd.attributes[4].format = MTLVertexFormatFloat;        // attr_radius
  vd.attributes[4].offset = call.radiusOff; vd.attributes[4].bufferIndex = 0;
  vd.attributes[5].format = MTLVertexFormatUChar;        // attr_flags (UByte)
  vd.attributes[5].offset = call.flagsOff;  vd.attributes[5].bufferIndex = 0;
  vd.layouts[0].stride = call.stride;
  vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

  MTLRenderPipelineDescriptor* psd = [[MTLRenderPipelineDescriptor alloc] init];
  psd.vertexFunction = vfn; psd.fragmentFunction = ffn; psd.vertexDescriptor = vd;
  psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  psd.colorAttachments[0].blendingEnabled = YES;
  psd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  psd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  psd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  psd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  psd.rasterSampleCount = _sampleCount;
  psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  _cylinderImpostorPipeline = [_device newRenderPipelineStateWithDescriptor:psd error:&err];
  if (!_cylinderImpostorPipeline)
    NSLog(@"RendererMetal: cyl impostor pipeline failed: %@", err);
  else
    _cylinderPipelineStride = call.stride;

  // Transparent cylinder OIT variant (MRT accum/reveal, ray-cast depth kept).
  id<MTLFunction> offn = [lib newFunctionWithName:@"cyl_impostor_fragment_oit"];
  if (offn) {
    MTLRenderPipelineDescriptor* op = [[MTLRenderPipelineDescriptor alloc] init];
    op.vertexFunction = vfn; op.fragmentFunction = offn; op.vertexDescriptor = vd;
    op.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    op.colorAttachments[0].blendingEnabled = YES;
    op.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    op.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    op.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    op.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    op.colorAttachments[1].pixelFormat = MTLPixelFormatR16Float;
    op.colorAttachments[1].blendingEnabled = YES;
    op.colorAttachments[1].sourceRGBBlendFactor = MTLBlendFactorZero;
    op.colorAttachments[1].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceColor;
    op.colorAttachments[1].sourceAlphaBlendFactor = MTLBlendFactorZero;
    op.colorAttachments[1].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceColor;
    op.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    op.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    _cylinderOitPipeline = [_device newRenderPipelineStateWithDescriptor:op error:&err];
    if (!_cylinderOitPipeline)
      NSLog(@"RendererMetal: cyl OIT pipeline failed: %@", err);
  }

  // Shadow-map variant: depth-only, single-sample.
  id<MTLFunction> sfn = [lib newFunctionWithName:@"cyl_impostor_fragment_shadow"];
  if (sfn) {
    MTLRenderPipelineDescriptor* sp = [[MTLRenderPipelineDescriptor alloc] init];
    sp.vertexFunction = vfn; sp.fragmentFunction = sfn; sp.vertexDescriptor = vd;
    sp.rasterSampleCount = 1;
    sp.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    _cylinderShadowPipeline = [_device newRenderPipelineStateWithDescriptor:sp error:&err];
    if (_cylinderShadowPipeline) _cylinderShadowStride = call.stride;
    else NSLog(@"RendererMetal: cyl shadow pipeline failed: %@", err);
  }
}

void RendererMetal::drawCylinderImpostors(const CylinderImpostorDrawCall& call)
{
  if (!call.vdata || !call.idata || call.indexCount <= 0) return;
  if (call.v1Off < 0 || call.v2Off < 0 || call.radiusOff < 0 ||
      call.flagsOff < 0 || call.colorOff < 0 || call.color2Off < 0)
    return;
  if (call.flagsIsFloat) {
    // The MSL declares attr_flags as `uchar`; a Float-format flags VBO would
    // mismatch. This layout isn't produced by the current rep; bail loudly.
    NSLog(@"RendererMetal: cyl impostor unexpected Float attr_flags; skipping");
    return;
  }
  ensureEncoder();
  if (!_encoder) return;
  buildCylinderImpostorPipeline(call);
  if (!_cylinderImpostorPipeline) return;
  if (_oitActive && !_cylinderOitPipeline) return; // no OIT variant: skip
  if (_shadowMode && !_cylinderShadowPipeline) return; // can't cast: skip safely

  id<MTLBuffer> vbo = nil, ibo = nil;
  { auto it = _vboCache.find(call.vdata);
    if (it != _vboCache.end()) vbo = it->second;
    else { vbo = [_device newBufferWithBytes:call.vdata length:call.vdataSize
                                     options:MTLResourceStorageModeShared];
           if (vbo) _vboCache[call.vdata] = vbo; } }
  { auto it = _vboCache.find(call.idata);
    if (it != _vboCache.end()) ibo = it->second;
    else { ibo = [_device newBufferWithBytes:call.idata length:call.idataSize
                                     options:MTLResourceStorageModeShared];
           if (ibo) _vboCache[call.idata] = ibo; } }
  if (!vbo || !ibo) return;

  // Ray tracing: tessellate cylinders (sticks) into the world-triangle set,
  // once per frame (opaque pass only). 8 verts/cylinder share v1/v2/radius.
  if (_rtEnabled && !_shadowMode && !_oitActive && call.cylinderCount > 0) {
    const uint8_t* vb = static_cast<const uint8_t*>(call.vdata);
    for (int k = 0; k < call.cylinderCount; ++k) {
      size_t bptr = (size_t)(8 * k) * call.stride;
      const float* p1 = reinterpret_cast<const float*>(vb + bptr + call.v1Off);
      const float* p2 = reinterpret_cast<const float*>(vb + bptr + call.v2Off);
      float r = call.uniRadius > 0.0f
                    ? call.uniRadius
                    : *reinterpret_cast<const float*>(vb + bptr + call.radiusOff);
      rtAppendCylinder(_rtTris, simd_make_float3(p1[0], p1[1], p1[2]),
                       simd_make_float3(p2[0], p2[1], p2[2]), r);
    }
  }

  if (_shadowMode) {
    [_encoder setRenderPipelineState:_cylinderShadowPipeline];
    [_encoder setDepthStencilState:_shadowDepthState]; // LESS + write (light POV)
    [_encoder setCullMode:MTLCullModeNone]; // boxes: don't inherit VBO cull-front
  } else if (_oitActive) {
    [_encoder setRenderPipelineState:_cylinderOitPipeline];
    [_encoder setDepthStencilState:oitDepthState()];
  } else {
    [_encoder setRenderPipelineState:_cylinderImpostorPipeline];
    applyDepthStencilState();
    if (_depthStencilState) [_encoder setDepthStencilState:_depthStencilState];
  }
  [_encoder setVertexBuffer:vbo offset:0 atIndex:0];

  struct {
    float modelview[16];
    float projection[16];
    float uni_radius;
    float ortho;
    float depthZeroToOne;
    float no_flat_caps;
    float cap_const;
    float half_bond;
    float inv_height;
    float interiorCap;
    float interiorColor[4];
    float lAmbient, lDirect, lReflect, lSpecular, lShininess, lSSSWrap;
  } u;
  std::memcpy(u.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(u.projection, _projectionMatrix.data(), 64);
  u.lAmbient = _lightAmbient; u.lDirect = _lightDirect;
  u.lReflect = _lightReflect; u.lSpecular = _lightSpecular;
  u.lShininess = _lightShininess;
  u.lSSSWrap = _sssWrap;
  u.uni_radius = call.uniRadius;
  u.ortho = (float)call.ortho;
  u.depthZeroToOne = 0.0f; // GL-convention clip Z (matches the sphere path)
  u.no_flat_caps = (float)call.noFlatCaps;
  u.cap_const = call.capConst;
  u.half_bond = 0.0f;      // smooth_half_bonds default off
  u.inv_height = 1.0f;     // only used when half_bond != 0
  // Cap the slab cross-section only in the opaque pass (not shadow/OIT).
  u.interiorCap = (call.interiorCap && !_shadowMode && !_oitActive) ? 1.0f : 0.0f;
  // ray_interior_color: .a>0.5 => use this rgb for the cap (else bond*0.45).
  u.interiorColor[0] = _capColor[0]; u.interiorColor[1] = _capColor[1];
  u.interiorColor[2] = _capColor[2]; u.interiorColor[3] = _capColorOverride ? 1.0f : 0.0f;
  [_encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
  [_encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];

  [_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                       indexCount:call.indexCount
                        indexType:MTLIndexTypeUInt32
                      indexBuffer:ibo
                indexBufferOffset:0];
}

// ---------------------------------------------------------------------------
#pragma mark - GPU-tessellated Bezier tubes ("tube cartoon")
// ---------------------------------------------------------------------------

// Metal tessellation pipeline: each cubic Bezier patch (4 control points) is
// tessellated over a QUAD domain — u runs along the curve, v around a ring —
// to extrude a smooth tube. (Metal has no isoline tessellation, so a tube via
// quad tessellation is both the natural fit and the showcase.)
static NSString* const kBezierTubeSrc = @R"(
#include <metal_stdlib>
using namespace metal;

struct CP { float3 pos [[attribute(0)]]; };
struct TubeU {
  float4x4 modelview;
  float4x4 projection;
  float radius;
  float _p0, _p1, _p2;
  float4 color;
};
struct TubeOut {
  float4 position [[position]];
  float3 eyeNormal;
  float4 color;
};

[[patch(quad, 4)]]
vertex TubeOut bezier_tube_vertex(
    patch_control_point<CP> cp [[stage_in]],
    float2 uv [[position_in_patch]],
    constant TubeU& U [[buffer(1)]]) {
  float t = uv.x;
  float omt = 1.0 - t;
  float3 p0 = cp[0].pos, p1 = cp[1].pos, p2 = cp[2].pos, p3 = cp[3].pos;
  // cubic Bezier position + tangent (derivative)
  float3 P = omt*omt*omt*p0 + 3.0*omt*omt*t*p1 + 3.0*omt*t*t*p2 + t*t*t*p3;
  float3 T = 3.0*omt*omt*(p1-p0) + 6.0*omt*t*(p2-p1) + 3.0*t*t*(p3-p2);
  // Robust tangent: fall back to the chord if the derivative degenerates
  // (coincident control points at sharp turns) to avoid collapsed/flipped
  // rings and gaps at joints.
  if (dot(T, T) < 1e-6) T = p3 - p0;
  T = normalize(T);
  // a stable frame around the tangent
  float3 up = (abs(T.y) < 0.99) ? float3(0.0,1.0,0.0) : float3(1.0,0.0,0.0);
  float3 N = normalize(cross(up, T));
  float3 B = normalize(cross(T, N));
  float ang = uv.y * 6.28318530718;
  float3 radial = cos(ang) * N + sin(ang) * B;
  float3 world = P + radial * U.radius;
  float4 eye = U.modelview * float4(world, 1.0);
  TubeOut o;
  o.position = U.projection * eye;
  o.position.z = 0.5 * (o.position.z + o.position.w);  // GL z [-1,1] -> Metal [0,1]
  o.eyeNormal = normalize((U.modelview * float4(radial, 0.0)).xyz);
  o.color = U.color;
  return o;
}

struct LightU { float ambient, direct, reflect, spec, shininess, wrap; };
fragment float4 bezier_tube_fragment(TubeOut in [[stage_in]],
    constant LightU& lt [[buffer(0)]]) {
  // PyMOL two-light model driven by the live lighting settings (Scene sliders).
  // Two-sided via the view vector: orient the normal toward the camera
  // (eye-space +z) so both the outer surface and the open tube ends/interior
  // are lit, never black.
  float3 nrm = normalize(in.eyeNormal);
  if (nrm.z < 0.0) nrm = -nrm;
  float ambient = lt.ambient, direct = lt.direct, reflectv = lt.reflect;
  float spec_value = lt.spec, shininess = max(lt.shininess, 1.0);
  const float3 L0 = float3(0.0,0.0,1.0);
  const float3 L1 = normalize(float3(0.4,0.4,1.0));
  float intensity = ambient, specular = 0.0;
  float n0 = dot(nrm, L0);
  intensity += direct * saturate((n0 + lt.wrap) / (1.0 + lt.wrap));
  float n1 = dot(nrm, L1);
  intensity += reflectv * saturate((n1 + lt.wrap) / (1.0 + lt.wrap));
  if (n1 > 0.0) {
    float3 H1 = normalize(L1 + float3(0.0,0.0,1.0));
    specular += spec_value * pow(max(dot(nrm, H1), 0.0), shininess);
  }
  float3 rgb = in.color.rgb * min(intensity, 1.0) + specular;
  return float4(rgb, in.color.a);
}
)";

void RendererMetal::buildBezierTubePipeline()
{
  if (_bezierTubePipeline) return;
  NSError* err = nil;
  id<MTLLibrary> lib = [_device newLibraryWithSource:kBezierTubeSrc
                                             options:nil error:&err];
  if (!lib) { NSLog(@"RendererMetal: bezier tube compile failed: %@", err); return; }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"bezier_tube_vertex"];
  id<MTLFunction> ffn = [lib newFunctionWithName:@"bezier_tube_fragment"];
  if (!vfn || !ffn) { NSLog(@"RendererMetal: bezier tube funcs missing"); return; }

  MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
  vd.attributes[0].format = MTLVertexFormatFloat3;  // control point position
  vd.attributes[0].offset = 0;
  vd.attributes[0].bufferIndex = 0;
  vd.layouts[0].stride = 12;
  vd.layouts[0].stepFunction = MTLVertexStepFunctionPerPatchControlPoint;

  MTLRenderPipelineDescriptor* psd = [[MTLRenderPipelineDescriptor alloc] init];
  psd.vertexFunction = vfn;
  psd.fragmentFunction = ffn;
  psd.vertexDescriptor = vd;
  psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  psd.rasterSampleCount = _sampleCount;
  psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  psd.maxTessellationFactor = 64;
  psd.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionConstant;
  psd.tessellationFactorFormat = MTLTessellationFactorFormatHalf;
  psd.tessellationOutputWindingOrder = MTLWindingClockwise;
  psd.tessellationPartitionMode = MTLTessellationPartitionModeInteger;
  _bezierTubePipeline = [_device newRenderPipelineStateWithDescriptor:psd error:&err];
  if (!_bezierTubePipeline)
    NSLog(@"RendererMetal: bezier tube pipeline failed: %@", err);
}

// half-float bit pattern for a tessellation factor
static inline uint16_t f16(float v) {
  _Float16 h = (_Float16) v;
  uint16_t bits;
  std::memcpy(&bits, &h, sizeof(bits));
  return bits;
}

void RendererMetal::drawBezierTubes(const void* cp, size_t dataSize,
    float radius, float r, float g, float b)
{
  if (!cp || dataSize < 48) return;       // need at least one 4-point patch
  // The tube has no depth-only shadow pipeline yet; skip casting in shadow mode
  // (it still receives shadows). Avoids a pipeline/attachment mismatch crash.
  if (_shadowMode) return;
  ensureEncoder();
  if (!_encoder) return;
  buildBezierTubePipeline();
  if (!_bezierTubePipeline) return;

  NSUInteger numPatches = dataSize / 48;  // 4 control points * 3 floats * 4 B
  if (numPatches == 0) return;

  // Control-point buffer (cache by pointer like the other VBOs).
  id<MTLBuffer> cpBuf = nil;
  auto it = _vboCache.find(cp);
  if (it != _vboCache.end()) cpBuf = it->second;
  else {
    cpBuf = [_device newBufferWithBytes:cp length:dataSize
                                options:MTLResourceStorageModeShared];
    if (!cpBuf) return;
    _vboCache[cp] = cpBuf;
  }

  // Constant per-patch tessellation factors (u = along curve, v = around ring).
  const float segF = 24.0f;  // subdivisions along the curve
  const float ringF = 14.0f; // subdivisions around the tube
  struct QuadFactors { uint16_t edge[4]; uint16_t inside[2]; };
  if (!_bezierTessFactors || _bezierTessPatchCap < numPatches) {
    _bezierTessFactors = [_device newBufferWithLength:numPatches * sizeof(QuadFactors)
                                              options:MTLResourceStorageModeShared];
    if (!_bezierTessFactors) return;
    QuadFactors qf;
    qf.edge[0] = f16(ringF); qf.edge[1] = f16(segF);
    qf.edge[2] = f16(ringF); qf.edge[3] = f16(segF);
    qf.inside[0] = f16(segF); qf.inside[1] = f16(ringF);
    QuadFactors* dst = (QuadFactors*) _bezierTessFactors.contents;
    for (NSUInteger i = 0; i < numPatches; ++i) dst[i] = qf;
    _bezierTessPatchCap = numPatches;
  }

  [_encoder setRenderPipelineState:_bezierTubePipeline];
  // Opaque geometry: standard depth test + write.
  [_encoder setDepthStencilState:bezierDepthState()];
  [_encoder setCullMode:MTLCullModeNone];
  [_encoder setVertexBuffer:cpBuf offset:0 atIndex:0];

  struct {
    float modelview[16];
    float projection[16];
    float radius;
    float _p0, _p1, _p2;
    float color[4];
  } u;
  std::memcpy(u.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(u.projection, _projectionMatrix.data(), 64);
  u.radius = radius;
  u._p0 = u._p1 = u._p2 = 0.0f;
  u.color[0] = r; u.color[1] = g; u.color[2] = b; u.color[3] = 1.0f;
  [_encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
  // Lighting (Scene sliders) for bezier_tube_fragment at fragment buffer(0).
  { struct { float a, d, r, s, sh, w; } _lt = { _lightAmbient, _lightDirect,
      _lightReflect, _lightSpecular, _lightShininess, _sssWrap };
    [_encoder setFragmentBytes:&_lt length:sizeof(_lt) atIndex:0]; }

  [_encoder setTessellationFactorBuffer:_bezierTessFactors offset:0 instanceStride:0];
  [_encoder drawPatches:4
             patchStart:0
             patchCount:numPatches
       patchIndexBuffer:nil
 patchIndexBufferOffset:0
          instanceCount:1
           baseInstance:0];
}

// ---------------------------------------------------------------------------
#pragma mark - Label / Text Drawing
// ---------------------------------------------------------------------------

// Self-contained MSL port of data/shaders/label.vs + label.fs. Screen-aligned
// textured glyph quads; the atlas RGBA already carries the baked label color
// (RGB = color, A = glyph coverage). Picking/fog/background-color effects from
// the full GL label shader are intentionally omitted here.
static NSString* const kLabelShaderSrc = @R"(
#include <metal_stdlib>
using namespace metal;

struct LabelVtxIn {
  float3 worldpos          [[attribute(0)]];
  float3 targetpos         [[attribute(1)]];
  float3 screenoffset      [[attribute(2)]];
  float2 texcoords         [[attribute(3)]];
  float3 screenworldoffset [[attribute(4)]];
  float  relative_mode     [[attribute(5)]];
};

struct LabelVtxOut {
  float4 position [[position]];
  float2 texcoords;
};

struct LabelUniforms {
  float4x4 modelview;
  float4x4 projection;
  float2 screenSize;
  float screenOriginVertexScale;
  float scaleByVertexScale;
  float labelTextureSize;
  float front;
  float clipRange;
};

static float convertNormalZToScreenZ(float normalz, float front,
                                     float clipRange, float4x4 proj) {
  float a_centerN = (normalz + 1.0) / 2.0;
  float z = -(front + clipRange * a_centerN);
  float4 p = proj * float4(0.0, 0.0, z, 1.0);
  return p.z / p.w;
}

vertex LabelVtxOut label_vertex(LabelVtxIn in [[stage_in]],
    constant LabelUniforms& U [[buffer(1)]]) {
  LabelVtxOut out;
  float isScreenCoord = step(2.0, fmod(in.relative_mode, 4.0));
  float isPixelCoord  = step(4.0, fmod(in.relative_mode, 8.0));
  float zTarget       = step(8.0, fmod(in.relative_mode, 16.0));
  float isProjected   = step(isScreenCoord + isPixelCoord, 0.5);

  float3 viewVector = (float4(0.0, 0.0, -1.0, 0.0) * U.modelview).xyz;
  float sovx = U.screenOriginVertexScale;
  float screenVertexScale =
      U.scaleByVertexScale * sovx * U.labelTextureSize +
      (1.0 - U.scaleByVertexScale);

  float4 wpos = float4(in.worldpos, 1.0);
  float4 tpos = float4(in.targetpos, 1.0);
  float4 transformedPosition = U.projection * U.modelview * wpos;
  float4 targetPosition = U.projection * U.modelview * tpos;
  targetPosition.xyz /= targetPosition.w; targetPosition.w = 1.0;
  transformedPosition.xyz /= transformedPosition.w;
  transformedPosition.xy =
      (floor(transformedPosition.xy * U.screenSize + 0.5) + 0.5) / U.screenSize;

  float4 a_center = wpos + in.screenworldoffset.z * float4(viewVector, 0.0);
  float4 tposZ = U.projection * U.modelview * a_center;
  tposZ.xyz /= tposZ.w; tposZ.w = 1.0;
  float2 pixOffset = (2.0 * in.worldpos.xy / U.screenSize) - 1.0;
  transformedPosition = isProjected * transformedPosition +
      isScreenCoord * wpos +
      isPixelCoord * float4(pixOffset.x, pixOffset.y, -0.5, 0.0);
  transformedPosition.xy += in.screenworldoffset.xy / (U.screenSize * sovx);
  transformedPosition.z = (1.0 - zTarget) *
          ((isProjected * tposZ.z) + (1.0 - isProjected) *
              convertNormalZToScreenZ(in.worldpos.z, U.front, U.clipRange,
                  U.projection)) +
      zTarget * targetPosition.z;
  transformedPosition.xy +=
      in.screenoffset.xy * 2.0 / (U.screenSize * screenVertexScale);
  transformedPosition.w = 1.0;

  out.position = transformedPosition;
  out.texcoords = in.texcoords;
  return out;
}

fragment float4 label_fragment(LabelVtxOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler smp [[sampler(0)]]) {
  float4 c = atlas.sample(smp, in.texcoords);
  if (c.a < 0.05)
    discard_fragment();
  return c;
}
)";

void RendererMetal::buildLabelPipeline()
{
  if (_labelPipeline)
    return;

  NSError* error = nil;
  id<MTLLibrary> lib = [_device newLibraryWithSource:kLabelShaderSrc
                                             options:nil
                                               error:&error];
  if (!lib) {
    NSLog(@"RendererMetal: failed to compile label shader: %@", error);
    return;
  }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"label_vertex"];
  id<MTLFunction> ffn = [lib newFunctionWithName:@"label_fragment"];
  if (!vfn || !ffn) {
    NSLog(@"RendererMetal: label shader functions not found");
    return;
  }

  // Vertex descriptor matching the interleaved label VBO. Offsets are filled
  // in per-draw via a stored layout; here we build for the canonical packing
  // (worldpos F3, targetpos F3, screenoffset F3, texcoords F2,
  //  screenworldoffset F3, relative_mode F1) with 4-byte alignment, which is
  // how CGOConvertToLabelShader lays it out.
  MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
  vd.attributes[0].format = MTLVertexFormatFloat3; vd.attributes[0].offset = 0;
  vd.attributes[1].format = MTLVertexFormatFloat3; vd.attributes[1].offset = 12;
  vd.attributes[2].format = MTLVertexFormatFloat3; vd.attributes[2].offset = 24;
  vd.attributes[3].format = MTLVertexFormatFloat2; vd.attributes[3].offset = 36;
  vd.attributes[4].format = MTLVertexFormatFloat3; vd.attributes[4].offset = 44;
  vd.attributes[5].format = MTLVertexFormatFloat;  vd.attributes[5].offset = 56;
  for (int i = 0; i < 6; ++i) vd.attributes[i].bufferIndex = 0;
  vd.layouts[0].stride = 60;
  vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

  MTLRenderPipelineDescriptor* psd =
      [[MTLRenderPipelineDescriptor alloc] init];
  psd.vertexFunction = vfn;
  psd.fragmentFunction = ffn;
  psd.vertexDescriptor = vd;
  psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  psd.colorAttachments[0].blendingEnabled = YES;
  psd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  psd.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  psd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  psd.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  psd.rasterSampleCount = _sampleCount;
  psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

  _labelPipeline = [_device newRenderPipelineStateWithDescriptor:psd
                                                           error:&error];
  if (!_labelPipeline) {
    NSLog(@"RendererMetal: failed to create label pipeline: %@", error);
    return;
  }

  MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
  sd.minFilter = MTLSamplerMinMagFilterNearest;
  sd.magFilter = MTLSamplerMinMagFilterNearest;
  sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
  _labelSampler = [_device newSamplerStateWithDescriptor:sd];
}

void RendererMetal::ensureLabelAtlas(const unsigned char* pixels, int w, int h,
    uint64_t generation)
{
  if (!pixels || w <= 0 || h <= 0)
    return;
  if (_labelAtlas && _labelAtlasGen == generation &&
      (int)_labelAtlas.width == w && (int)_labelAtlas.height == h)
    return;

  if (!_labelAtlas || (int)_labelAtlas.width != w ||
      (int)_labelAtlas.height != h) {
    MTLTextureDescriptor* td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    _labelAtlas = [_device newTextureWithDescriptor:td];
  }
  if (!_labelAtlas)
    return;
  [_labelAtlas replaceRegion:MTLRegionMake2D(0, 0, w, h)
                 mipmapLevel:0
                   withBytes:pixels
                 bytesPerRow:static_cast<NSUInteger>(w) * 4];
  _labelAtlasGen = generation;
}

void RendererMetal::drawLabels(const LabelDrawCall& call)
{
  if (!call.data || call.dataSize == 0 || call.vertexCount <= 0)
    return;
  ensureEncoder();
  if (!_encoder)
    return;
  buildLabelPipeline();
  if (!_labelPipeline || !_labelSampler)
    return;
  ensureLabelAtlas(call.atlasPixels, call.atlasW, call.atlasH, call.atlasGen);
  if (!_labelAtlas)
    return;

  // Upload (or reuse cached) the interleaved label vertex data.
  id<MTLBuffer> vbo = nil;
  auto it = _vboCache.find(call.data);
  if (it != _vboCache.end()) {
    vbo = it->second;
  } else {
    vbo = [_device newBufferWithBytes:call.data
                               length:call.dataSize
                              options:MTLResourceStorageModeShared];
    if (!vbo)
      return;
    _vboCache[call.data] = vbo;
  }

  [_encoder setRenderPipelineState:_labelPipeline];
  applyDepthStencilState();
  if (_depthStencilState)
    [_encoder setDepthStencilState:_depthStencilState];

  [_encoder setVertexBuffer:vbo offset:0 atIndex:0];

  struct {
    float modelview[16];
    float projection[16];
    float screenSize[2];
    float screenOriginVertexScale;
    float scaleByVertexScale;
    float labelTextureSize;
    float front;
    float clipRange;
    float _pad;
  } U;
  std::memcpy(U.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(U.projection, _projectionMatrix.data(), 64);
  U.screenSize[0] = call.screenW;
  U.screenSize[1] = call.screenH;
  U.screenOriginVertexScale = call.screenOriginVertexScale;
  U.scaleByVertexScale = call.scaleByVertexScale;
  U.labelTextureSize = call.labelTextureSize;
  U.front = call.front;
  U.clipRange = call.clipRange;
  U._pad = 0.f;
  [_encoder setVertexBytes:&U length:sizeof(U) atIndex:1];

  [_encoder setFragmentTexture:_labelAtlas atIndex:0];
  [_encoder setFragmentSamplerState:_labelSampler atIndex:0];

  [_encoder drawPrimitives:MTLPrimitiveTypeTriangle
               vertexStart:0
               vertexCount:static_cast<NSUInteger>(call.vertexCount)];
}

} // namespace pymol
