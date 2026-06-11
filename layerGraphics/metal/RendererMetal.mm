#include "RendererMetal.h"

#import <simd/simd.h>

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
    , _batchBuffer(nil)
    , _sphereImpostorPipeline(nil)
    , _cylinderImpostorPipeline(nil)
    , _depthStencilState(nil)
{
  _modelviewMatrix = identityMatrix();
  _projectionMatrix = identityMatrix();
  std::memset(_uniformData, 0, sizeof(_uniformData));

  // Create initial depth stencil state
  applyDepthStencilState();

  // Build the built-in batch pipeline from embedded MSL source.
  // This pipeline is used by beginBatch/endBatch for immediate-mode drawing.
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
      MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
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
      psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
      psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

      _batchPipeline = [_device newRenderPipelineStateWithDescriptor:psd
                                                               error:&error];
      if (!_batchPipeline) {
        NSLog(@"RendererMetal: failed to create batch pipeline: %@", error);
      }
    }
  } else {
    NSLog(@"RendererMetal: failed to compile batch shader: %@", error);
  }

  // Build VBO pipelines for molecular geometry rendering
  buildVBOPipelines();
}

RendererMetal::~RendererMetal()
{
  _buffers.clear();
  _textures.clear();
  _fbColorAttachments.clear();
  _fbDepthAttachments.clear();
}

// ---------------------------------------------------------------------------
#pragma mark - Drawable setup
// ---------------------------------------------------------------------------

void RendererMetal::setDrawable(
    id<CAMetalDrawable> drawable, MTLRenderPassDescriptor* passDesc)
{
  _drawable = drawable;
  _screenPassDesc = passDesc;       // the drawable target (final composite pass)
  // Render the scene into offscreen targets sized to the drawable; the existing
  // scene-draw code keys off _passDesc, so point it at the offscreen descriptor.
  id<MTLTexture> tex = drawable.texture;
  ensurePostTargets(tex.width, tex.height);
  _passDesc = _scenePassDesc;
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
  _depthStencilState = [_device newDepthStencilStateWithDescriptor:desc];
  _depthStencilDirty = false;

  if (_encoder) {
    [_encoder setDepthStencilState:_depthStencilState];
  }
}

// ---------------------------------------------------------------------------
#pragma mark - Frame lifecycle
// ---------------------------------------------------------------------------

void RendererMetal::beginFrame()
{
  _cmdBuffer = [_queue commandBuffer];
  _encoder = nil;
  _oitActive = false;
  _oitHasContent = false;

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
  float _pad;
};

// Linear eye distance (positive, toward the scene) from window depth [0,1].
static float post_linear_depth(float d, float projA, float projB) {
  float ndcz = 2.0 * d - 1.0;
  float ez = -projB / (ndcz + projA); // eye z (negative, in front of camera)
  return -ez;                         // distance from camera (positive)
}

fragment float4 post_ssao_fog(PostVOut in [[stage_in]],
    texture2d<float> colorTex [[texture(0)]],
    depth2d<float> depthTex [[texture(1)]],
    sampler s [[sampler(0)]],
    constant PostU& u [[buffer(0)]]) {
  float3 color = colorTex.sample(s, in.uv).rgb;
  float d = depthTex.sample(s, in.uv);

  float ao = 1.0;
  if (u.aoEnabled > 0.5 && d < 0.99999) {
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

  // Screen-space directional shadows: march from the surface point toward the
  // key light through the depth buffer; if a closer surface lies along the
  // ray, the point is shadowed. Real directional cast shadows for the dense
  // (mostly on-screen) molecular scenes PyMOL renders.
  if (u.shadowEnabled > 0.5 && d < 0.99999) {
    float ez = -u.projB / ((2.0 * d - 1.0) + u.projA);  // eye z (negative)
    float ndcx = 2.0 * in.uv.x - 1.0;
    float ndcy = 1.0 - 2.0 * in.uv.y;
    float3 p = float3(ndcx * (-ez) / u.projX, ndcy * (-ez) / u.projY, ez);
    float3 Ldir = normalize(float3(0.4, 0.4, 1.0)); // toward light (eye space)
    float stepv = (-ez) * 0.010;
    float occluded = 0.0;
    const int KS = 24;
    for (int i = 1; i <= KS; i++) {
      float3 q = p + Ldir * (stepv * float(i));
      if (q.z > -1e-4) break;                 // crossed in front of camera
      float2 nq = float2(u.projX * q.x / (-q.z), u.projY * q.y / (-q.z));
      float2 uvq = float2(0.5 * nq.x + 0.5, 0.5 - 0.5 * nq.y);
      if (uvq.x < 0.0 || uvq.x > 1.0 || uvq.y < 0.0 || uvq.y > 1.0) break;
      float dq = depthTex.sample(s, uvq);
      if (dq >= 0.99999) continue;            // background: not an occluder
      float zq = -u.projB / ((2.0 * dq - 1.0) + u.projA);
      float diff = zq - q.z; // > 0 when scene surface is closer than ray point
      if (diff > stepv * 0.6 && diff < stepv * 6.0) { occluded = 1.0; break; }
    }
    color *= (1.0 - occluded * u.shadowIntensity);
  }

  if (u.fogEnabled > 0.5 && d < 0.99999) {
    float dist = post_linear_depth(d, u.projA, u.projB);
    float fog = clamp((u.fogEnd - dist) / max(u.fogEnd - u.fogStart, 1e-4),
                      0.0, 1.0);
    color = mix(float3(u.bgR, u.bgG, u.bgB), color, fog);
  }
  return float4(color, 1.0);
}
)";

void RendererMetal::ensurePostTargets(NSUInteger w, NSUInteger h)
{
  if (w == 0 || h == 0) return;
  buildPostPipelines();
  if (_sceneColor && _rtW == w && _rtH == h) return;
  _rtW = w; _rtH = h;

  MTLTextureDescriptor* cd = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w height:h mipmapped:NO];
  cd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  cd.storageMode = MTLStorageModePrivate;
  _sceneColor = [_device newTextureWithDescriptor:cd];
  _postColor = [_device newTextureWithDescriptor:cd];

  MTLTextureDescriptor* dd = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                   width:w height:h mipmapped:NO];
  dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  dd.storageMode = MTLStorageModePrivate;
  _sceneDepth = [_device newTextureWithDescriptor:dd];

  if (!_scenePassDesc)
    _scenePassDesc = [[MTLRenderPassDescriptor alloc] init];
  _scenePassDesc.colorAttachments[0].texture = _sceneColor;
  _scenePassDesc.depthAttachment.texture = _sceneDepth;
  _scenePassDesc.stencilAttachment.texture = _sceneDepth;

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
  }

  id<MTLFunction> vfn = [lib newFunctionWithName:@"post_vertex"];
  auto mkpipe = [&](NSString* name) -> id<MTLRenderPipelineState> {
    id<MTLFunction> ffn = [lib newFunctionWithName:name];
    if (!vfn || !ffn) return nil;
    MTLRenderPipelineDescriptor* psd = [[MTLRenderPipelineDescriptor alloc] init];
    psd.vertexFunction = vfn; psd.fragmentFunction = ffn;
    psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    NSError* e = nil;
    id<MTLRenderPipelineState> p =
        [_device newRenderPipelineStateWithDescriptor:psd error:&e];
    if (!p) NSLog(@"RendererMetal: post pipeline %@ failed: %@", name, e);
    return p;
  };
  _blitPipeline = mkpipe(@"post_blit");
  _fxaaPipeline = mkpipe(@"post_fxaa");
  _ssaoPipeline = mkpipe(@"post_ssao_fog");
  _oitResolvePipeline = mkpipe(@"oit_resolve");
}

void RendererMetal::setPostParams(int fogEnabled, float fogStart, float fogEnd,
    float bgR, float bgG, float bgB, int aoEnabled, int shadowEnabled,
    int aaEnabled, float projA, float projB, float projX, float projY)
{
  _postFogEnabled = fogEnabled;
  _fogStart = fogStart;
  _fogEnd = fogEnd;
  _bgR = bgR; _bgG = bgG; _bgB = bgB;
  _aoEnabled = aoEnabled;
  _shadowEnabled = shadowEnabled;
  _aaEnabled = aaEnabled;
  _projA = projA;
  _projB = projB;
  _projX = projX;
  _projY = projY;
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
  id<MTLTexture> sceneSrc = _sceneColor;

  // Pass 1: SSAO + screen-space shadows + depth-cue/fog (color+depth -> post).
  if ((doAO || doFog || doShadow) && _postColor) {
    struct {
      float projA, projB, fogStart, fogEnd;
      float bgR, bgG, bgB, fogEnabled;
      float aoEnabled, aoIntensity, aoRadiusPx, projX;
      float projY, shadowEnabled, shadowIntensity, _pad;
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
    u._pad = 0.0f;

    MTLRenderPassDescriptor* pd = [[MTLRenderPassDescriptor alloc] init];
    pd.colorAttachments[0].texture = _postColor;
    pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e1 =
        [_cmdBuffer renderCommandEncoderWithDescriptor:pd];
    [e1 setRenderPipelineState:_ssaoPipeline];
    [e1 setFragmentTexture:_sceneColor atIndex:0];
    [e1 setFragmentTexture:_sceneDepth atIndex:1];
    [e1 setFragmentSamplerState:_postSampler atIndex:0];
    [e1 setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [e1 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e1 endEncoding];
    sceneSrc = _postColor;
  }

  // Pass 2: OIT resolve — composite accumulated transparency over the opaque
  // (post-processed) color. Ping-pongs to whichever target isn't the source.
  if (_oitHasContent && _oitResolvePipeline && _oitAccum) {
    id<MTLTexture> dst = (sceneSrc == _sceneColor) ? _postColor : _sceneColor;
    MTLRenderPassDescriptor* pd = [[MTLRenderPassDescriptor alloc] init];
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

  // Final pass → drawable: FXAA if available, else a 1:1 blit.
  // PYMOL_NO_AA forces the blit (A/B testing + user escape hatch).
  _screenPassDesc.depthAttachment.texture = nil;
  _screenPassDesc.stencilAttachment.texture = nil;
  _screenPassDesc.colorAttachments[0].loadAction = MTLLoadActionDontCare;
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
  MTLDepthStencilDescriptor* dsd = [[MTLDepthStencilDescriptor alloc] init];
  dsd.depthCompareFunction = MTLCompareFunctionLessEqual;
  dsd.depthWriteEnabled = NO;
  [_encoder setDepthStencilState:[_device newDepthStencilStateWithDescriptor:dsd]];
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

// ---------------------------------------------------------------------------
#pragma mark - Viewport and clear
// ---------------------------------------------------------------------------

void RendererMetal::viewport(int x, int y, int w, int h)
{
  _viewport = {
      static_cast<double>(x), static_cast<double>(y),
      static_cast<double>(w), static_cast<double>(h), 0.0, 1.0};

  // Also update scissor to match if scissor is not explicitly set
  _scissorRect = {
      static_cast<NSUInteger>(x), static_cast<NSUInteger>(y),
      static_cast<NSUInteger>(w), static_cast<NSUInteger>(h)};

  if (_encoder) {
    [_encoder setViewport:_viewport];
    if (!_scissorEnabled) {
      [_encoder setScissorRect:_scissorRect];
    }
  }
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
  _scissorRect = {
      static_cast<NSUInteger>(x), static_cast<NSUInteger>(y),
      static_cast<NSUInteger>(w), static_cast<NSUInteger>(h)};

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
};

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

  // Two-sided directional lighting in eye space: abs(N·L) lights back faces
  // (surface interiors, cartoon undersides) instead of leaving them black,
  // matching desktop PyMOL's two_sided_lighting behavior for closed geometry.
  float3 eyeNormal = normalize((uniforms.modelview * float4(in.normal, 0.0)).xyz);
  float3 lightDir = float3(0.0, 0.0, 1.0);
  float NdotL = abs(dot(eyeNormal, lightDir));
  float ambient = 0.25;
  float lighting = ambient + (1.0 - ambient) * NdotL;

  out.color = float4(in.color.rgb * lighting, in.color.a);
  return out;
}

fragment float4 vbo_fragment(VBOVertexOut in [[stage_in]])
{
  return in.color;
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
  out.color = in.color;
  out.pointSize = max(uniforms.pointSize, 1.0);
  return out;
}

fragment float4 vbo_fragment_unlit(VBOVertexOutUnlit in [[stage_in]])
{
  return in.color;
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
fragment OITFragOut vbo_fragment_oit(VBOVertexOut in [[stage_in]])
{
  float4 c = in.color;
  float w = oit_weight(c.a, in.position.z);
  OITFragOut o;
  o.accum = float4(c.rgb * c.a, c.a) * w;
  o.reveal = c.a;
  return o;
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
  if (!_vboVertexFunc || !_vboFragmentFunc) {
    NSLog(@"RendererMetal: VBO shader functions not found");
    return;
  }

  // Create pipeline for UByte4Norm color format:
  // position: Float3 @ offset 0, normal: Float3 @ offset 12, color: UChar4Norm @ offset 24
  // stride = 28
  {
    MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
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
    psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

    _vboPipelineUByte = [_device newRenderPipelineStateWithDescriptor:psd
                                                                error:&error];
    if (!_vboPipelineUByte) {
      NSLog(@"RendererMetal: failed to create VBO UByte pipeline: %@", error);
    }
  }

  // Create pipeline for Float4 color format:
  // position: Float3 @ offset 0, normal: Float3 @ offset 12, color: Float4 @ offset 24
  // stride = 40
  {
    MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
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
    psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

    _vboPipelineFloat = [_device newRenderPipelineStateWithDescriptor:psd
                                                                error:&error];
    if (!_vboPipelineFloat) {
      NSLog(@"RendererMetal: failed to create VBO Float pipeline: %@", error);
    }
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
      MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
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
  return ps;
}

// ---------------------------------------------------------------------------
#pragma mark - VBO Drawing
// ---------------------------------------------------------------------------

void RendererMetal::drawVBO(PrimitiveType mode, int vertexCount,
    const void* data, size_t dataSize, size_t stride,
    int posOffset, int normalOffset, int colorOffset, int colorType)
{
  if (!data || dataSize == 0 || vertexCount <= 0) return;
  ensureEncoder();
  if (!_encoder) return;

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
  MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];

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
  id<MTLRenderPipelineState> pipeline = nil;

  // Check if layout matches pre-built pipelines
  if (!unlit && posOffset == 0 && normalOffset == 12 && colorOffset == 24) {
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
    pipeline = oitPipelineForVD(vd);
    if (!pipeline) return;
  }

  // Fallback: create pipeline on-the-fly (cached by Metal driver). `unlit`
  // (lines/ribbon without a normal, or Points/dots) uses the flat-color +
  // point-size shader.
  id<MTLFunction> vfn = unlit ? _vboVertexUnlitFunc : _vboVertexFunc;
  id<MTLFunction> ffn = unlit ? _vboFragmentUnlitFunc : _vboFragmentFunc;
  if (!pipeline && vfn && ffn) {
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
    psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

    NSError* error = nil;
    pipeline = [_device newRenderPipelineStateWithDescriptor:psd error:&error];
    if (!pipeline) {
      NSLog(@"RendererMetal: VBO drawVBO pipeline creation failed: %@", error);
      return;
    }
  }

  if (!pipeline) return;

  [_encoder setRenderPipelineState:pipeline];

  // Apply depth/stencil
  if (_oitActive) {
    MTLDepthStencilDescriptor* d = [[MTLDepthStencilDescriptor alloc] init];
    d.depthCompareFunction = MTLCompareFunctionLessEqual; // test vs opaque, no write
    d.depthWriteEnabled = NO;
    [_encoder setDepthStencilState:[_device newDepthStencilStateWithDescriptor:d]];
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

  // Draw
  [_encoder drawPrimitives:toMTL(mode)
               vertexStart:0
               vertexCount:static_cast<NSUInteger>(vertexCount)];
}

void RendererMetal::drawVBOIndexed(PrimitiveType mode, int indexCount,
    const void* vertexData, size_t vertexDataSize, size_t stride,
    int posOffset, int normalOffset, int colorOffset, int colorType,
    const void* indexData, size_t indexDataSize)
{
  if (!vertexData || !indexData || vertexDataSize == 0 ||
      indexDataSize == 0 || indexCount <= 0) return;
  ensureEncoder();
  if (!_encoder) return;

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
  MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
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
  if (!unlit && posOffset == 0 && normalOffset == 12 && colorOffset == 24) {
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
    pipeline = oitPipelineForVD(vd);
    if (!pipeline) return;
  }
  id<MTLFunction> vfn = unlit ? _vboVertexUnlitFunc : _vboVertexFunc;
  id<MTLFunction> ffn = unlit ? _vboFragmentUnlitFunc : _vboFragmentFunc;
  if (!pipeline && vfn && ffn) {
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
    psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

    NSError* error = nil;
    pipeline = [_device newRenderPipelineStateWithDescriptor:psd error:&error];
    if (!pipeline) {
      NSLog(@"RendererMetal: VBO drawVBOIndexed pipeline failed: %@", error);
      return;
    }
  }
  if (!pipeline) return;

  [_encoder setRenderPipelineState:pipeline];

  if (_oitActive) {
    MTLDepthStencilDescriptor* d = [[MTLDepthStencilDescriptor alloc] init];
    d.depthCompareFunction = MTLCompareFunctionLessEqual; // test vs opaque, no write
    d.depthWriteEnabled = NO;
    [_encoder setDepthStencilState:[_device newDepthStencilStateWithDescriptor:d]];
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

  [_encoder drawIndexedPrimitives:toMTL(mode)
                       indexCount:static_cast<NSUInteger>(indexCount)
                        indexType:MTLIndexTypeUInt32
                      indexBuffer:ibo
                indexBufferOffset:0];
}

void RendererMetal::invalidateVBOCache(uint64_t key)
{
  // Clear entire cache — key type changed to pointer-based
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
  float _pad;
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
  float3 normal = normalize(ipoint - in.sphere_center);
  float4 clip = u.projection * float4(ipoint, 1.0);
  float ndcz = clip.z / clip.w;
  depth = (u.depthZeroToOne >= 0.5) ? ndcz : (0.5 + 0.5 * ndcz);
  if (depth <= 0.0 || depth >= 1.0) discard_fragment();

  // PyMOL default two-light model (see data/shaders/compute_color_for_light.fs):
  // ambient .14, headlight direct .45, key reflect .481, specular .5, shine 55.
  const float ambient    = 0.14;
  const float direct     = 0.45;
  const float reflect    = 0.481;
  const float spec_value = 0.5;
  const float shininess  = 55.0;
  const float3 L0 = float3(0.0, 0.0, 1.0);
  const float3 L1 = normalize(float3(0.4, 0.4, 1.0));
  float intensity = ambient;
  float specular = 0.0;
  float n0 = dot(normal, L0);
  if (n0 > 0.0) intensity += direct * n0;
  float n1 = dot(normal, L1);
  if (n1 > 0.0) {
    intensity += reflect * n1;
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

  MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
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
}

void RendererMetal::drawSphereImpostors(const SphereImpostorDrawCall& call)
{
  if (!call.data || call.dataSize == 0 || call.sphereCount <= 0) return;
  ensureEncoder();
  if (!_encoder) return;
  buildImpostorPipelines();
  if (!_sphereImpostorPipeline) return;
  if (_oitActive && !_sphereOitPipeline) return; // no OIT variant: skip

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

  if (_oitActive) {
    [_encoder setRenderPipelineState:_sphereOitPipeline];
    MTLDepthStencilDescriptor* d = [[MTLDepthStencilDescriptor alloc] init];
    d.depthCompareFunction = MTLCompareFunctionLessEqual; // test vs opaque
    d.depthWriteEnabled = NO;
    [_encoder setDepthStencilState:[_device newDepthStencilStateWithDescriptor:d]];
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
    float _pad;
  } u;
  std::memcpy(u.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(u.projection, _projectionMatrix.data(), 64);
  u.sphere_size_scale = call.sphereSizeScale;
  u.ortho = (float)call.ortho;
  // Projection is GL-convention ([-1,1] clip Z): remap to [0,1] for Metal's
  // fragment depth (matches the GL sphere.fs `0.5 + 0.5 * clipZ/clipW`).
  u.depthZeroToOne = 0.0f;
  u._pad = 0.0f;
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
  float _pad;
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
  if (depth <= 0.0) discard_fragment();

  // PyMOL default two-light model (identical to the sphere impostor).
  const float ambient    = 0.14;
  const float direct     = 0.45;
  const float reflect    = 0.481;
  const float spec_value = 0.5;
  const float shininess  = 55.0;
  const float3 L0 = float3(0.0, 0.0, 1.0);
  const float3 L1 = normalize(float3(0.4, 0.4, 1.0));
  float intensity = ambient;
  float specular = 0.0;
  float n0 = dot(normal, L0);
  if (n0 > 0.0) intensity += direct * n0;
  float n1 = dot(normal, L1);
  if (n1 > 0.0) {
    intensity += reflect * n1;
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

  MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
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

  if (_oitActive) {
    [_encoder setRenderPipelineState:_cylinderOitPipeline];
    MTLDepthStencilDescriptor* dd = [[MTLDepthStencilDescriptor alloc] init];
    dd.depthCompareFunction = MTLCompareFunctionLessEqual; // test vs opaque
    dd.depthWriteEnabled = NO;
    [_encoder setDepthStencilState:[_device newDepthStencilStateWithDescriptor:dd]];
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
    float _pad;
  } u;
  std::memcpy(u.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(u.projection, _projectionMatrix.data(), 64);
  u.uni_radius = call.uniRadius;
  u.ortho = (float)call.ortho;
  u.depthZeroToOne = 0.0f; // GL-convention clip Z (matches the sphere path)
  u.no_flat_caps = (float)call.noFlatCaps;
  u.cap_const = call.capConst;
  u.half_bond = 0.0f;      // smooth_half_bonds default off
  u.inv_height = 1.0f;     // only used when half_bond != 0
  u._pad = 0.0f;
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
  o.eyeNormal = normalize((U.modelview * float4(radial, 0.0)).xyz);
  o.color = U.color;
  return o;
}

fragment float4 bezier_tube_fragment(TubeOut in [[stage_in]]) {
  // PyMOL default two-light model (same as the impostors).
  float3 nrm = normalize(in.eyeNormal);
  const float ambient = 0.14, direct = 0.45, reflectv = 0.481;
  const float spec_value = 0.5, shininess = 55.0;
  const float3 L0 = float3(0.0,0.0,1.0);
  const float3 L1 = normalize(float3(0.4,0.4,1.0));
  float intensity = ambient, specular = 0.0;
  float n0 = dot(nrm, L0);
  if (n0 > 0.0) intensity += direct * n0;
  float n1 = dot(nrm, L1);
  if (n1 > 0.0) {
    intensity += reflectv * n1;
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

  MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
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

void RendererMetal::drawBezierTubes(const void* cp, size_t dataSize)
{
  if (!cp || dataSize < 48) return;       // need at least one 4-point patch
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
  MTLDepthStencilDescriptor* dsd = [[MTLDepthStencilDescriptor alloc] init];
  dsd.depthCompareFunction = MTLCompareFunctionLessEqual;
  dsd.depthWriteEnabled = YES;
  [_encoder setDepthStencilState:[_device newDepthStencilStateWithDescriptor:dsd]];
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
  u.radius = 0.4f;
  u._p0 = u._p1 = u._p2 = 0.0f;
  u.color[0] = 0.30f; u.color[1] = 0.75f; u.color[2] = 0.95f; u.color[3] = 1.0f;
  [_encoder setVertexBytes:&u length:sizeof(u) atIndex:1];

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
  MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
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
