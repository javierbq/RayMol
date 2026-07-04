#pragma once

#include "GPUEnums.h"
#include "IndexBuffer.h"
#include "VertexBuffer.h"

// #include <span>
#include "pymol/span.h"
#include <vector>

// -----------------------------------------------------------------------------
/* Vertexbuffer rules:
 * -----------------------------------------------------------------------------
 * - If the buffer data is interleaved then buffer sub data functionality cannot
 *   be used.
 * - The same order of buffer data must be maintained when uploading and binding
 *
 *-----------------------------------------------------------------------
 * USAGE_PATTERN:
 * SEPARATE:
 *   vbo1 [ data1 ]
 *   vbo2 [ data2 ]
 *   ...
 *   vboN [ dataN ]
 * SEQUENTIAL:
 *   vbo [ data1 | data2 | ... | dataN ]
 * INTERLEAVED:
 *   vbo [ data1[0], data2[0], ..., dataN[0] | ... | data1[M], data2[M], ..., dataN[M] ]
 */
class VertexBufferGL : public VertexBuffer
{
public:

  /**
   * @brief Constructs a Vertex Buffer
   * @param layout The vertex buffer layout
   * @param memProperty The memory usage property
   */
  VertexBufferGL(VertexBufferLayout layout = VertexBufferLayout::Separate,
      MemoryUsageProperty property = MemoryUsageProperty::GpuOnly);

  /**
   * @brief Binds this Vertex Buffer
   */
  void bind() const override;

  /**
   * @brief Binds a specific buffer in the Vertex Buffer
   */
  void bind(GLuint prg, int index = -1);

  /**
   * @brief Unbinds this Vertex Buffer
   */
  void unbind();

  /**
   * @brief Masks the attributes to be used in the shader
   * @param attrib_locs The attribute locations
   */
  void maskAttributes(std::vector<GLint> attrib_locs);

  /**
   * @brief Masks a specific attribute to be used in the shader
   * @param attrib_loc The attribute location
   */
  void maskAttribute(GLint attrib_loc);

  /**
   * @return Underlying buffers Image IDs
   */
  std::vector<std::uint64_t> getBufferIDs() const override;

  /**
   * @return Underlying buffers and offsets
   */
  std::vector<BufferAndOffsets> getBufferOffsets() const override;

  /**
   * @brief Copies data from external source to this buffer
   * @param bufferAndOffets Buffer index and offset
   * @param data The data to copy to the buffer
   */
  void copyFrom(const BufferAndOffsets& bufferAndOffsets,
      pymol::span<const std::byte> data) override;

  /**
   * Conditionally generates a GPU buffer for the given data descriptor
   * @param desc The buffer data descriptor
   * @return Whether the buffer data was successfully buffered
   * @note The supplied data ptr in the struct can
   * be zero, in which case if the default usage is STATIC_DRAW then no
   * opengl buffer will be generated for that, else it is assumed that the
   * data will be supplied at a later point because it's dynamic draw.
   */
  bool bufferData(BufferDataDesc&& desc);

  /**
   * Generates a GPU buffer for the given data descriptor
   * @param desc The buffer data descriptor
   * @param data The data to buffer
   * @param len The length of the data
   * @note assumes the data is interleaved
   */
  bool bufferData(
      BufferDataDesc&& desc, const void* data, size_t len);

  // -----------------------------------------------------------------------------

  /**
   * Updates (a portion of) the buffer data
   * @param offset The offset to start updating the buffer data
   * @param size The size of the data to update
   * @param data The data to update
   * @param index The index of the buffer data to update
   * @note This function assumes that the data layout hasn't changed
  */
  void bufferSubData(size_t offset, size_t size, void* data, size_t index = 0);

  /**
   * Replaces the whole interleaved buffer data
   * @param data The data to replace the buffer data with
   * @param len The length of the data
   * @param data The data to replace the buffer data with
   * @note This function assumes that the data layout hasn't changed
   */
  void bufferReplaceData(std::size_t offset, pymol::span<const std::byte> data);

  // CPU data access for non-GL renderers (Metal)
  const std::byte* cpuData() const { return m_cpuData.data(); }
  std::size_t cpuDataSize() const { return m_cpuData.size(); }
  std::size_t cpuStride() const { return m_cpuStride; }
  const BufferDataDesc& getDesc() const { return m_cpuDesc; }
  bool hasCPUData() const { return !m_cpuData.empty(); }

private:
  void retainInterleavedCPUCopy();

  /**
   * @return Vertex buffer type (GL_ARRAY_BUFFER)
   */
  GLenum bufferType() const;

  /**
   * @brief Binds an attribute to the shader program
   * @param prg The shader program
   * @param d The buffer descriptor
   * @param glID The OpenGL buffer ID
   */
  void bind_attrib(GLuint prg, const BufferDesc& d, GLuint glID);

  /**
   * @return true if the data is interleaved
   */
  bool isInterleaved() const noexcept;

  /**
   * Generates a separate buffer for each data descriptor
   * @return Whether the buffer data was successfully buffered
   */
  bool sepBufferData();

  /**
   * Generates a single sequential buffer for all data descriptors
   * @return Whether the buffer data was successfully buffered
   */
  bool seqBufferData();

  /**
   * Generates a single interleaved buffer for all data descriptors
   * @return Whether the buffer data was successfully buffered
   */
  bool interleaveBufferData();

  /**
   * Generates GPU buffer(s) for the given data descriptor
   * @return Whether the buffer data was successfully buffered
   */
  bool evaluate();

  bool m_status{false};
  GLuint m_interleavedID{};
  MemoryUsageProperty m_memProperty{MemoryUsageProperty::GpuOnly};
  VertexBufferLayout m_layout{ VertexBufferLayout::Separate };
  std::size_t m_stride{};
  BufferDataDesc m_desc;
  std::vector<GLuint> desc_glIDs; // m_desc's gl buffer IDs

  // m_locs is only for interleaved data
  std::vector<GLint> m_locs;
  std::vector<GLint> m_attribmask;

  // CPU-side interleaved copy for non-GL renderers
  std::vector<std::byte> m_cpuData;
  std::size_t m_cpuStride{};
  BufferDataDesc m_cpuDesc;
};

/**
 * Index buffer specialization
 */
class IndexBufferGL : public IndexBuffer
{
public:

  /**
   * @brief Binds this Index Buffer
   */
  void bind() const override;

  /**
   * @brief Unbinds this Index Buffer
   */
  void unbind();

  /**
   * @return Index buffer type (GL_ELEMENT_ARRAY_BUFFER)
   */
  GLenum bufferType() const;

  /**
   * @brief Copies index data from external source to this buffer
   */
  void copyFrom(pymol::span<const std::uint32_t> data);

  /**
   * @return The OpenGL buffer ID
   */
  std::uint64_t getBufferID() const override;

  // CPU data access for non-GL renderers (Metal)
  const std::byte* cpuData() const { return m_cpuData.data(); }
  std::size_t cpuDataSize() const { return m_cpuData.size(); }
  bool hasCPUData() const { return !m_cpuData.empty(); }

private:
  void bufferSubData(std::size_t offset, pymol::span<const std::byte> data);
  GLuint m_bufferID{};
  std::vector<std::byte> m_cpuData;
};
