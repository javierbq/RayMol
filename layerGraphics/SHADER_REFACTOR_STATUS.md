# Shader Pipeline GL Refactor Status

Status of direct OpenGL calls remaining in the shader/buffer pipeline files,
categorized by migration difficulty to the Renderer interface.

**Immediate mode (glBegin/glEnd)**: NONE remaining — all eliminated in Phase 2 Pass 1.

---

## layer0/ShaderMgr.cpp (~75 direct GL calls)

### Tightly coupled — shader compilation internals
These are core GL shader API calls. Migrating them requires a full shader
compilation abstraction in the Renderer (e.g. `createShader`, `compileShader`,
`attachShader`, `linkProgram`). Low priority — these are inherently GL-specific.

| Call | Count | Context |
|------|-------|---------|
| `glCreateProgram` | 1 | `CShaderPrg::reload()` |
| `glCreateShader` | 5 | vertex, fragment, geometry, tessellation shaders |
| `glShaderSource` | 5 | via `glShaderSource1String` helper |
| `glCompileShader` | 5 | shader compilation |
| `glGetShaderiv` | 5 | compile status check |
| `glAttachShader` | 5 | attach to program |
| `glDetachShader` | 5 | cleanup in reload/invalidate |
| `glDeleteShader` | 5 | cleanup in reload/invalidate |
| `glBindAttribLocation` | 8 | attribute binding during reload |
| `glProgramParameteriEXT` | 3 | geometry shader parameters |
| `glGetShaderInfoLog` | 1 | error reporting |

### Tightly coupled — FBO/framebuffer internals
These manage framebuffer read/draw targets for stereo, offscreen, and OIT
rendering. They use GL-specific enums (GL_READ_FRAMEBUFFER, GL_DRAW_FRAMEBUFFER,
GL_COLOR_ATTACHMENT0) not yet in the Renderer interface.

| Call | Count | Context |
|------|-------|---------|
| `glBindFramebuffer` | 7 | `setDrawBuffer`, `readPixelsFrom`, `drawPixelsTo` |
| `glGetIntegerv` | 6 | save/restore FBO bindings |
| `glDrawBuffer` | 2 | `setDrawBuffer`, `drawPixelsTo` |
| `glReadBuffer` | 3 | `readPixelsFrom`, restore state |

### Needs Renderer extension — state management
These could be routed through the Renderer but need new methods or enum values.

| Call | Count | Context |
|------|-------|---------|
| `glEnable(GL_BLEND)` | 3 | OIT, copy, offscreen shaders |
| `glDisable(GL_BLEND)` | 1 | copy shader |
| `glEnable(GL_CULL_FACE)` | 1 | cylinder shader setup |
| `glCullFace(GL_BACK)` | 1 | cylinder shader setup |
| `glDisable(GL_DEPTH_TEST)` | 3 | background, OIT, copy shaders |
| `glEnable(GL_DEPTH_TEST)` | 0 | — |
| `glDisable(GL_ALPHA_TEST)` | 2 | OIT, copy shaders |
| `glBlendFuncSeparate` | 1 | OIT shader |
| `glBlendFunc` | 1 | stereo blend |
| `glEnable(GL_TEXTURE_CUBE_MAP_SEAMLESS)` | 1 | lighting texture |
| `glEnable(GL_BLEND)` (offscreen) | 1 | `bindOffscreen` |

**Renderer changes needed**: Add `Capability::CullFace` (already present),
add `blendFuncSeparate()`, add `cullFace()`.

### Needs Renderer extension — texture management
These are cube map and texture operations not covered by current Renderer.

| Call | Count | Context |
|------|-------|---------|
| `glGenTextures` | 1 | lighting texture |
| `glBindTexture(GL_TEXTURE_CUBE_MAP)` | 1 | lighting texture |
| `glTexParameteri(GL_TEXTURE_CUBE_MAP)` | 4 | lighting texture filtering |
| `glTexImage2D(GL_TEXTURE_CUBE_MAP_*)` | 6 (loop) | lighting texture faces |
| `glActiveTexture` | 3 | label, indicator, offscreen shaders |

**Renderer changes needed**: Add `TextureTarget::CubeMap`, extend `texImage2D()`.

### Can replace now — queries and VBO cleanup

| Call | Count | Context |
|------|-------|---------|
| `glGetFloatv(GL_ALIASED_LINE_WIDTH_RANGE)` | 1 | `Config()` |
| `glGetString(GL_VERSION)` | 1 | `getGLVersion()` |
| `glGetString(GL_EXTENSIONS)` | 1 | `getGLSLVersion()` |
| `glGetString(GL_SHADING_LANGUAGE_VERSION)` | 1 | `getGLSLVersion()` |
| `glGetError` | 3 | `WARNING_IF_GLERROR` macro, shader creation |
| `glDeleteBuffers` | 2 | `FreeAllVBOs`, `AddVBOToFree` |
| `glIsBuffer` | 1 | `AddVBOToFree` (WebGL path) |
| `glPatchParameteri` | 1 | tessellation setup |

**Renderer changes needed**: Add `getFloatv()`, `getString()`, `isBuffer()`,
`patchParameteri()`. Or keep these as GL-specific utilities.

---

## layer0/ShaderPrg.cpp (~36 direct GL calls)

### Tightly coupled — shader program lifecycle
| Call | Count | Context |
|------|-------|---------|
| `glUseProgram` | 2 | `Enable()`, `Disable()` |
| `glLinkProgram` | 1 | `Link()` |
| `glGetProgramiv` | 2 | link status, info log length |
| `glGetProgramInfoLog` | 1 | error reporting |
| `glGetError` | 1 | error check during link |
| `glGetIntegerv(GL_MAX_VARYING_FLOATS)` | 1 | diagnostics |
| `glDeleteProgram` | 1 | `Invalidate()` |
| `glDetachShader` | 5 | `Invalidate()` |
| `glDeleteShader` | 5 | `Invalidate()` |

### Tightly coupled — uniform/attribute setters
| Call | Count | Context |
|------|-------|---------|
| `glGetUniformLocation` | 1 | `GetUniformLocation()` (cached) |
| `glUniform1i` | 1 | `Set1i()` |
| `glUniform1f` | 1 | `Set1f()` |
| `glUniform2f` | 1 | `Set2f()` |
| `glUniform3f` | 1 | `Set3f()` |
| `glUniform4f` | 1 | `Set4f()` |
| `glUniformMatrix3fv` | 1 | `SetMat3fc()` |
| `glUniformMatrix4fv` | 1 | `SetMat4fc()` |
| `glGetAttribLocation` | 1 | `GetAttribLocation()` |
| `glVertexAttrib4f` | 1 | `SetAttrib4fLocation()` |
| `glVertexAttrib1f` | 1 | `SetAttrib1fLocation()` |

### Needs Renderer extension — texture state in shader setup
| Call | Count | Context |
|------|-------|---------|
| `glActiveTexture` | 2 | `Set_Specular_Values()`, `SetBgUniforms()` |
| `glBindTexture(GL_TEXTURE_CUBE_MAP)` | 1 | `Set_Specular_Values()` |
| `glBindTexture(GL_TEXTURE_2D, 0)` | 1 | `Disable()` |
| `glActiveTexture(GL_TEXTURE0)` | 1 | `Disable()` — reset active unit |

---

## layer0/GenericBuffer.cpp (~42 direct GL calls)

### Tightly coupled — renderbuffer management
| Call | Count | Context |
|------|-------|---------|
| `glGenRenderbuffers` | 1 | `RenderbufferGL` constructor |
| `glDeleteRenderbuffers` | 1 | `freeBuffer()` |
| `glBindRenderbuffer` | 4 | `bind()`, `unbind()`, static `rbo::unbind()` |
| `glRenderbufferStorage` | 1 | constructor |

### Tightly coupled — texture creation and upload
| Call | Count | Context |
|------|-------|---------|
| `glGenTextures` | 1 | `TextureGL` constructor |
| `glDeleteTextures` | 1 | `freeBuffer()` |
| `glBindTexture` | 3 | `bind()`, `unbind()`, constructor |
| `glTexParameteri` | 5 | filtering, wrapping |
| `glTexImage1D` | 3 | 1D texture upload (half-float, float, byte) |
| `glTexImage2D` | 3 | 2D texture upload |
| `glTexImage3D` | 3 | 3D texture upload |
| `glTexSubImage2D` | 2 | partial 2D update |
| `glActiveTexture` | 1 | `bindToTextureUnit()` |
| `glTexEnvf` | 1 | legacy texture environment |

### Tightly coupled — FBO management
| Call | Count | Context |
|------|-------|---------|
| `glGenFramebuffers` | 1 | `FramebufferGL::genBuffer()` |
| `glDeleteFramebuffers` | 1 | `freeBuffer()` |
| `glBindFramebuffer` | 3 | `bind()`, blit read/draw |
| `glFramebufferTexture2D` | 1 | attach texture |
| `glFramebufferRenderbuffer` | 1 | attach RBO |
| `glCheckFramebufferStatus` | 1 | validation |
| `glBlitFramebuffer` | 1 | blit operation |

### Can replace now — clear operations
| Call | Count | Context |
|------|-------|---------|
| `glClearColor` | 1 | RT bind with clear |
| `glClear` | 1 | RT bind with clear |

---

## layer0/PostProcess.cpp (~10 direct GL calls)

### Needs Renderer extension — state for OIT compositing
| Call | Count | Context |
|------|-------|---------|
| `glActiveTexture` | 3 | `activateRTAsTexture`, `activateTexture`, OIT |
| `glDrawBuffers` | 1 | OIT MRT setup |
| `glClearColor` | 1 | OIT clear |
| `glClear` | 1 | OIT clear |
| `glDepthMask` | 1 | OIT setup |
| `glEnable(GL_DEPTH_TEST)` | 1 | OIT setup |
| `glEnable(GL_BLEND)` | 1 | OIT setup |
| `glBlendFuncSeparate` | 1 | OIT blend mode |

**Renderer changes needed**: Add `drawBuffers()`, `blendFuncSeparate()`.

---

## layer0/GraphicsUtil.cpp (~3 direct GL calls)

### Can replace now — error checking utilities
| Call | Count | Context |
|------|-------|---------|
| `glGetError` | 2 | `glCheckOkay()`, `CheckGLErrorOK()` |

These are diagnostic utilities. Could use `Renderer::getError()` but they're
called from contexts that may not have a Renderer pointer readily available.

---

## layer1/CGORenderer.h — 0 direct GL calls

Only contains comments referencing GL function names (`glEnableVertexAttribArray`,
`glEnableClientState`). No actual GL calls to convert.

---

## Summary

| Category | Count | Action |
|----------|-------|--------|
| No immediate mode (glBegin/glEnd) | 0 | Already done |
| Tightly coupled (shader compilation) | ~50 | Defer — needs Renderer shader abstraction |
| Tightly coupled (FBO/RBO/texture internals) | ~35 | Defer — needs Renderer FBO/texture abstraction |
| Tightly coupled (uniform/attribute setters) | ~15 | Defer — these ARE the shader API |
| Needs Renderer extension (state) | ~15 | Next pass — add blendFuncSeparate, cullFace, drawBuffers |
| Needs Renderer extension (textures) | ~10 | Next pass — add CubeMap target, texImage2D |
| Can replace now | ~10 | Low priority — queries, error checks, clear ops |

### Recommended Renderer Interface Extensions (for next pass)

1. **`blendFuncSeparate(BlendFunc srcRGB, BlendFunc dstRGB, BlendFunc srcA, BlendFunc dstA)`**
2. **`cullFace(int face)`** — or enum CullFace { Front, Back, FrontAndBack }
3. **`drawBuffers(int count, const int* bufs)`** — for MRT
4. **`TextureTarget::CubeMap`** + cube map face parameter on texImage2D
5. **`texImage2D(target, level, internalFormat, w, h, border, format, type, data)`**
6. **`bindFramebuffer(target, id)`** — separate read/draw targets
7. **`readBuffer(int buf)`** / **`drawBuffer(int buf)`**
