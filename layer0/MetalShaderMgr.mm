/*
 * MetalShaderMgr.mm — Metal shader loading and pipeline state management
 */

#import "MetalShaderMgr.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <functional>

namespace pymol {

MetalShaderMgr::MetalShaderMgr(id<MTLDevice> device) : _device(device) {}

// ============================================================
// Library loading
// ============================================================

bool MetalShaderMgr::loadDefaultLibrary()
{
  if (loadMetallibFromBundle()) {
    return true;
  }
  NSLog(@"MetalShaderMgr: no metallib in bundle, compiling from source");
  return compileFromSourceFiles();
}

bool MetalShaderMgr::loadMetallibFromBundle()
{
  NSBundle* bundle = [NSBundle mainBundle];
  NSString* libPath =
      [bundle pathForResource:@"pymol" ofType:@"metallib"];
  if (!libPath) {
    // Also check Resources/ directly
    NSString* resourceDir =
        [bundle.resourcePath stringByAppendingPathComponent:@"pymol.metallib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:resourceDir]) {
      libPath = resourceDir;
    }
  }

  if (!libPath) {
    return false;
  }

  NSError* error = nil;
  NSURL* url = [NSURL fileURLWithPath:libPath];
  _library = [_device newLibraryWithURL:url error:&error];
  if (error) {
    NSLog(@"MetalShaderMgr: failed to load metallib: %@",
        error.localizedDescription);
    _library = nil;
    return false;
  }

  NSLog(@"MetalShaderMgr: loaded metallib from %@", libPath);
  return true;
}

bool MetalShaderMgr::compileFromSourceFiles()
{
  NSBundle* bundle = [NSBundle mainBundle];

  // Look for shaders_metal directory in bundle resources
  NSString* shaderDir = [bundle.resourcePath
      stringByAppendingPathComponent:@"data/shaders_metal"];

  if (![[NSFileManager defaultManager] fileExistsAtPath:shaderDir]) {
    NSLog(@"MetalShaderMgr: shader source directory not found at %@",
        shaderDir);
    return false;
  }

  // Gather all .metal files and concatenate their source
  // (the common header is #included by each file, so we compile individually
  //  via the library-from-source path which supports #include)
  NSError* error = nil;
  NSArray<NSString*>* files = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:shaderDir
                          error:&error];
  if (error) {
    NSLog(@"MetalShaderMgr: cannot list shader dir: %@",
        error.localizedDescription);
    return false;
  }

  // Read and concatenate all .metal source files
  // Metal's newLibraryWithSource handles #include when we set the
  // include path via MTLCompileOptions.
  NSMutableString* combinedSource = [NSMutableString string];

  // First, read the common header inline so it's available
  NSString* commonPath =
      [shaderDir stringByAppendingPathComponent:@"pymol_metal_common.h"];
  NSString* commonSrc =
      [NSString stringWithContentsOfFile:commonPath
                                encoding:NSUTF8StringEncoding
                                   error:&error];
  if (!commonSrc) {
    NSLog(@"MetalShaderMgr: cannot read common header: %@",
        error.localizedDescription);
    return false;
  }

  // Replace #include directives with the common header content inline
  for (NSString* file in files) {
    if (![file.pathExtension isEqualToString:@"metal"]) {
      continue;
    }
    NSString* path =
        [shaderDir stringByAppendingPathComponent:file];
    NSString* src =
        [NSString stringWithContentsOfFile:path
                                  encoding:NSUTF8StringEncoding
                                     error:&error];
    if (!src) {
      NSLog(@"MetalShaderMgr: cannot read %@: %@", file,
          error.localizedDescription);
      continue;
    }
    // Strip #include "pymol_metal_common.h" — we prepend it once
    src = [src stringByReplacingOccurrencesOfString:
                   @"#include \"pymol_metal_common.h\""
                                         withString:@""];
    [combinedSource appendFormat:@"// --- %@ ---\n%@\n", file, src];
  }

  // Prepend the common header (without include guard issues — it uses
  // #ifndef so double-inclusion is harmless, but we stripped includes above)
  NSString* fullSource =
      [NSString stringWithFormat:@"%@\n%@", commonSrc, combinedSource];

  MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
  options.languageVersion = MTLLanguageVersion2_0;

  _library = [_device newLibraryWithSource:fullSource
                                   options:options
                                     error:&error];
  if (error) {
    // Metal reports warnings via error even on success
    if (!_library) {
      NSLog(@"MetalShaderMgr: compile failed: %@",
          error.localizedDescription);
      return false;
    }
    NSLog(@"MetalShaderMgr: compile warnings: %@",
        error.localizedDescription);
  }

  NSLog(@"MetalShaderMgr: compiled %lu shader functions from source",
      (unsigned long)_library.functionNames.count);
  return true;
}

// ============================================================
// Function retrieval
// ============================================================

id<MTLFunction> MetalShaderMgr::getVertexFunction(const std::string& name)
{
  auto it = _vertexFunctions.find(name);
  if (it != _vertexFunctions.end()) {
    return it->second;
  }

  NSString* funcName =
      [NSString stringWithFormat:@"%s_vertex", name.c_str()];
  id<MTLFunction> func = [_library newFunctionWithName:funcName];
  if (!func) {
    NSLog(@"MetalShaderMgr: vertex function '%@' not found", funcName);
    return nil;
  }

  _vertexFunctions[name] = func;
  return func;
}

id<MTLFunction> MetalShaderMgr::getFragmentFunction(const std::string& name)
{
  auto it = _fragmentFunctions.find(name);
  if (it != _fragmentFunctions.end()) {
    return it->second;
  }

  NSString* funcName =
      [NSString stringWithFormat:@"%s_fragment", name.c_str()];
  id<MTLFunction> func = [_library newFunctionWithName:funcName];
  if (!func) {
    NSLog(@"MetalShaderMgr: fragment function '%@' not found", funcName);
    return nil;
  }

  _fragmentFunctions[name] = func;
  return func;
}

// ============================================================
// Pipeline state management
// ============================================================

/// Hash for pipeline cache key: combines shader name, formats, and blend flag.
static uint64_t makePipelineKey(const std::string& shaderName,
    MTLPixelFormat colorFormat, MTLPixelFormat depthFormat, bool blendEnabled)
{
  std::size_t h = std::hash<std::string>{}(shaderName);
  h ^= std::hash<uint64_t>{}(static_cast<uint64_t>(colorFormat)) + 0x9e3779b9 +
       (h << 6) + (h >> 2);
  h ^= std::hash<uint64_t>{}(static_cast<uint64_t>(depthFormat)) + 0x9e3779b9 +
       (h << 6) + (h >> 2);
  h ^= std::hash<bool>{}(blendEnabled) + 0x9e3779b9 + (h << 6) + (h >> 2);
  return static_cast<uint64_t>(h);
}

id<MTLRenderPipelineState> MetalShaderMgr::getPipelineState(
    const std::string& shaderName, MTLPixelFormat colorFormat,
    MTLPixelFormat depthFormat, bool blendEnabled)
{
  uint64_t key = makePipelineKey(shaderName, colorFormat, depthFormat,
      blendEnabled);

  auto it = _pipelineCache.find(key);
  if (it != _pipelineCache.end()) {
    return it->second;
  }

  id<MTLFunction> vertFunc = getVertexFunction(shaderName);
  id<MTLFunction> fragFunc = getFragmentFunction(shaderName);
  if (!vertFunc || !fragFunc) {
    return nil;
  }

  MTLRenderPipelineDescriptor* desc =
      [[MTLRenderPipelineDescriptor alloc] init];
  desc.label = [NSString stringWithUTF8String:shaderName.c_str()];
  desc.vertexFunction = vertFunc;
  desc.fragmentFunction = fragFunc;
  desc.colorAttachments[0].pixelFormat = colorFormat;
  desc.depthAttachmentPixelFormat = depthFormat;

  if (blendEnabled) {
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor =
        MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
  }

  NSError* error = nil;
  id<MTLRenderPipelineState> pso =
      [_device newRenderPipelineStateWithDescriptor:desc error:&error];
  if (error) {
    NSLog(@"MetalShaderMgr: pipeline state error for '%s': %@",
        shaderName.c_str(), error.localizedDescription);
    return nil;
  }

  _pipelineCache[key] = pso;
  return pso;
}

} // namespace pymol
