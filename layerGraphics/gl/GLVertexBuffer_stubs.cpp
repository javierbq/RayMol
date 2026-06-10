/*
 * GLVertexBuffer_stubs.cpp — Stub implementations of VertexBufferGL and
 * IndexBufferGL for iOS builds where OpenGL is not available.
 *
 * These classes are referenced by CGO.cpp and CGOGL.cpp even on Metal-only
 * builds. The stubs provide linkable symbols without actual GL calls.
 */

#ifdef _PYMOL_NO_OPENGL

#include "GLVertexBuffer.h"
#include "VertexFormat.h"
#include <cstring>
#include <cstdint>
#include <vector>

// VertexBufferGL stubs

VertexBufferGL::VertexBufferGL(VertexBufferLayout layout,
    MemoryUsageProperty property)
    : m_layout(layout), m_memProperty(property) {}

void VertexBufferGL::bind() const {}
void VertexBufferGL::bind(GLuint, int) {}
void VertexBufferGL::unbind() {}
void VertexBufferGL::maskAttributes(std::vector<GLint>) {}
void VertexBufferGL::maskAttribute(GLint) {}

std::vector<std::uint64_t> VertexBufferGL::getBufferIDs() const { return {}; }
std::vector<BufferAndOffsets> VertexBufferGL::getBufferOffsets() const { return {}; }

void VertexBufferGL::copyFrom(const BufferAndOffsets&, pymol::span<const std::byte>) {}

bool VertexBufferGL::bufferData(BufferDataDesc&& desc) {
  // Per-attribute (non-interleaved) data, e.g. CGOOptimizeToVBONotIndexed used
  // by cartoon/lines. Interleave into a CPU copy for the Metal renderer, exactly
  // as GLVertexBuffer.cpp::evaluate() -> retainInterleavedCPUCopy() does on macOS.
  m_desc = std::move(desc);
  retainInterleavedCPUCopy();
  return true;
}

// Copy of GLVertexBuffer.cpp::retainInterleavedCPUCopy (that TU is excluded on
// iOS). Builds m_cpuData/m_cpuStride/m_cpuDesc from the per-attribute data_ptrs
// so RendererMetal::drawVBO has interleaved vertex data to upload.
void VertexBufferGL::retainInterleavedCPUCopy()
{
  auto& descs = m_desc.descs;
  const std::size_t bufferCount = descs.size();
  if (bufferCount == 0) return;

  std::size_t count = 0;
  for (std::size_t i = 0; i < bufferCount; ++i) {
    if (descs[i].data_size > 0 && descs[i].data_ptr) {
      count = descs[i].data_size / GetSizeOfVertexFormat(descs[i].m_format);
      break;
    }
  }
  if (count == 0) return;

  std::size_t stride = 0;
  std::vector<std::size_t> size_table(bufferCount);
  std::vector<std::size_t> offsets(bufferCount);
  std::vector<const std::uint8_t*> ptr_table(bufferCount);

  m_cpuDesc.descs.clear();
  m_cpuDesc.descs.reserve(bufferCount);

  for (std::size_t i = 0; i < bufferCount; ++i) {
    size_table[i] = GetSizeOfVertexFormat(descs[i].m_format);
    offsets[i] = stride;
    stride += size_table[i];
    int m = stride % 4;
    stride = (m ? (stride + (4 - m)) : stride);
    ptr_table[i] = static_cast<const std::uint8_t*>(descs[i].data_ptr);

    BufferDesc cpuD(descs[i].attr_name, descs[i].m_format,
        count * size_table[i], nullptr, static_cast<std::uint32_t>(offsets[i]));
    m_cpuDesc.descs.push_back(cpuD);
  }
  m_cpuDesc.stride = stride;
  m_cpuStride = stride;

  std::size_t totalSize = count * stride;
  m_cpuData.resize(totalSize, std::byte{0});

  for (std::size_t v = 0; v < count; ++v) {
    for (std::size_t i = 0; i < bufferCount; ++i) {
      if (ptr_table[i]) {
        auto dest = m_cpuData.data() + v * stride + offsets[i];
        std::memcpy(dest, ptr_table[i] + v * size_table[i], size_table[i]);
      }
    }
  }
}

bool VertexBufferGL::bufferData(BufferDataDesc&& desc, const void* data, size_t len) {
  // Retain interleaved CPU copy + stride for the Metal renderer
  // (mirrors the CPU-retain path in GLVertexBuffer.cpp:328-345).
  m_layout = VertexBufferLayout::Interleaved;
  m_cpuDesc = std::move(desc);
  m_cpuStride = m_cpuDesc.stride.value_or(0);
  if (data && len > 0) {
    m_cpuData.assign(static_cast<const std::byte*>(data),
                     static_cast<const std::byte*>(data) + len);
  }
  // data_ptrs are not valid after this call
  for (auto& d : m_cpuDesc.descs) {
    d.data_ptr = nullptr;
  }
  return true;
}

void VertexBufferGL::bufferSubData(size_t, size_t, void*, size_t) {}
void VertexBufferGL::bufferReplaceData(std::size_t, pymol::span<const std::byte>) {}

// IndexBufferGL stubs

void IndexBufferGL::bind() const {}
void IndexBufferGL::unbind() {}
GLenum IndexBufferGL::bufferType() const { return 0; }

void IndexBufferGL::copyFrom(pymol::span<const std::uint32_t> data) {
  // Retain CPU copy for Metal renderer
  m_cpuData.assign(
      reinterpret_cast<const std::byte*>(data.data()),
      reinterpret_cast<const std::byte*>(data.data()) + data.size() * sizeof(std::uint32_t));
}

std::uint64_t IndexBufferGL::getBufferID() const { return 0; }

void IndexBufferGL::bufferSubData(std::size_t, pymol::span<const std::byte>) {}

#endif /* _PYMOL_NO_OPENGL */
