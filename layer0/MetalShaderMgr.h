/*
 * MetalShaderMgr.h — Metal shader loading and pipeline state management
 *
 * Loads a pre-compiled .metallib (or falls back to runtime compilation
 * from .metal source files) and caches MTLRenderPipelineState objects
 * keyed on (shader name, pixel format, blend mode).
 */
#pragma once

#include <string>
#include <unordered_map>

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

namespace pymol {

class MetalShaderMgr {
public:
#ifdef __OBJC__
  MetalShaderMgr(id<MTLDevice> device);

  /// Load the pre-compiled metallib from the app bundle.
  /// Falls back to runtime compilation from .metal source if not found.
  bool loadDefaultLibrary();

  /// Get a cached (or newly created) render pipeline state for a shader pair.
  id<MTLRenderPipelineState> getPipelineState(
      const std::string& shaderName, MTLPixelFormat colorFormat,
      MTLPixelFormat depthFormat, bool blendEnabled = false);

  /// Get individual shader functions by name.
  id<MTLFunction> getVertexFunction(const std::string& name);
  id<MTLFunction> getFragmentFunction(const std::string& name);

  bool isReady() const { return _library != nil; }

private:
  bool loadMetallibFromBundle();
  bool compileFromSourceFiles();

  id<MTLDevice> _device;
  id<MTLLibrary> _library;
  std::unordered_map<std::string, id<MTLFunction>> _vertexFunctions;
  std::unordered_map<std::string, id<MTLFunction>> _fragmentFunctions;
  std::unordered_map<uint64_t, id<MTLRenderPipelineState>> _pipelineCache;
#else
  // C++ translation units see only the interface shape
  MetalShaderMgr() = default;
  bool isReady() const { return false; }
#endif
};

} // namespace pymol
