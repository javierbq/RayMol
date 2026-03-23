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
};

struct BatchVertexOut {
  float4 position [[position]];
  float4 color;
};

vertex BatchVertexOut batch_vertex(
    BatchVertexIn in [[stage_in]],
    constant BatchUniforms& uniforms [[buffer(1)]])
{
  BatchVertexOut out;
  out.position = uniforms.projection * uniforms.modelview * float4(in.position, 1.0);
  out.color = in.color;
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
  _passDesc = passDesc;
}

// ---------------------------------------------------------------------------
#pragma mark - Encoder management
// ---------------------------------------------------------------------------

void RendererMetal::ensureEncoder()
{
  if (_encoder) return;
  if (!_cmdBuffer || !_passDesc) return;

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

  // Configure clear values on the render pass descriptor
  if (_passDesc) {
    _passDesc.colorAttachments[0].clearColor =
        MTLClearColorMake(_clearR, _clearG, _clearB, _clearA);
    _passDesc.depthAttachment.clearDepth = 1.0;
    _passDesc.stencilAttachment.clearStencil = 0;
  }
}

void RendererMetal::endFrame()
{
  if (_encoder) {
    [_encoder endEncoding];
    _encoder = nil;
  }

  if (_drawable && _cmdBuffer) {
    [_cmdBuffer presentDrawable:_drawable];
  }

  if (_cmdBuffer) {
    [_cmdBuffer commit];
    _cmdBuffer = nil;
  }

  _drawable = nil;
  _passDesc = nil;
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
  if (!_encoder) return;

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
  id<MTLBuffer> tmpVBO =
      [_device newBufferWithBytes:drawVertices->data()
                           length:byteSize
                          options:MTLResourceStorageModeShared];

  // Bind batch VBO at buffer index 0
  [_encoder setVertexBuffer:tmpVBO offset:0 atIndex:0];

  // Upload modelview and projection matrices as uniforms at buffer index 1
  struct {
    float modelview[16];
    float projection[16];
  } matrices;
  std::memcpy(matrices.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(matrices.projection, _projectionMatrix.data(), 64);
  [_encoder setVertexBytes:&matrices length:sizeof(matrices) atIndex:1];

  // Use the current pipeline if set, otherwise fall back to the built-in
  // batch pipeline (simple position+color, no lighting).
  id<MTLRenderPipelineState> pipeline =
      _currentPipeline ? _currentPipeline : _batchPipeline;
  if (pipeline) {
    [_encoder setRenderPipelineState:pipeline];
  }

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

} // namespace pymol
