#pragma once
// -----------------------------------------------------------------------------
#include "GPUEnums.h"
#include "GPUVertexDesc.h"
#include "Vector.h"
#include <vector>
#include <tuple>
#include <array>
#include <type_traits>
#include <cstdlib>
#include <glm/vec2.hpp>

/**
 * @param format Vertex format
 * @return The GL type of the vertex format
*/
GLenum VertexFormatToGLType(VertexFormat format);

/**
 * @param format Vertex format
 * @return The number of components in the vertex format
*/
GLint VertexFormatToGLSize(VertexFormat format);

/**
 * @param format Vertex format
 * @return Whether the vertex format is a normalized type as a GLboolean
*/
GLboolean VertexFormatToGLNormalized(VertexFormat format);

/* different types of AttribOp */
enum attrib_op_type {
  NO_COPY = 0,
  FLOAT_TO_FLOAT,
  FLOAT2_TO_FLOAT2,
  FLOAT3_TO_FLOAT3,
  FLOAT4_TO_FLOAT4,
  FLOAT3_TO_UB3,
  FLOAT1_TO_UB_4TH,
  UB3_TO_UB3,
  UINT_INT_TO_PICK_DATA,
  UB1_INTERP_TO_CAP,
  FLOAT1_TO_INTERP,
  UB4_TO_UB4,
  PICK_DATA_TO_PICK_DATA,
  CYL_CAP_TO_CAP,
  FLOAT1_INTERP_TO_CAP,
  UB1_TO_INTERP,
  CYL_CAPS_ARE_ROUND,
  CYL_CAPS_ARE_FLAT,
  CYL_CAPS_ARE_CUSTOM,
  FLOAT4_TO_UB4
};

struct AttribDesc;

typedef void (*AttribOpFuncDataFunctionPtr)(void *varData, const float * pc, void *globalData, int idx);

/* AttribOpFuncData : This structure holds information a callback that sets/post-processes
                      data for a particular attribute.  Currently, a list of these functions
                      are attached to the AttribOp so that when vertices are created (i.e., incr_vertices > 0)
                      then for each vertex, this function is called for the particular attribute attribName.

   funcDataConversion - pointer to function that sets/post-processes the attribute data
   funcDataGlobalArg - pointer to global structure that can be used in each call to the callback
   attribName - attribute name this function is processing. (this calling function specifies the name, and the
                CGOConvertToShader() sets attrib to the associated AttribDesc.
 */
struct AttribOpFuncData {
  void (*funcDataConversion)(void *varData, const float * pc, void *globalData, int idx); // if set, should be called on every output value for this attribute
  void *funcDataGlobalArg;
  const char *attribName;
  AttribDesc *attrib;
  AttribOpFuncDataFunctionPtr _funcDataConversion;
  AttribOpFuncData(AttribOpFuncDataFunctionPtr _funcDataConversion,
                   void *_funcDataGlobalArg,
                   const char *_attribName)
  : funcDataConversion(_funcDataConversion), funcDataGlobalArg(_funcDataGlobalArg), attribName(_attribName), attrib(nullptr){}
};

using AttribOpFuncDataDesc = std::vector< AttribOpFuncData >;

/**
 * defines an operation that copies and (optionally) creates new vertices in 
 * a VBO operation for a particular CGO operation (op).
 *
 * op - the CGO operation
 * order - the order for this operation to be executed for the given CGO operation
 * offset - the offset into the CGO operation to copy
 * conv_type - type of copy (can be general or specific, see above, e.g. FLOAT3_TO_FLOAT3, UB1_TO_INTERP)
 * incr_vertices - the number of vertices (if any) that are generated for the VBO after this operation 
 *                 is executed.
 *
 */
struct AttribOp {
  AttribOp(unsigned short _op, size_t _order, size_t _conv_type, size_t _offset, size_t _incr_vertices=0, int _copyFromAttr=-1)
    : op(_op)
    , order(_order)
    , offset(_offset)
    , conv_type(_conv_type)
    , incr_vertices(_incr_vertices)
    , copyFromAttr(_copyFromAttr)
    {}
  unsigned short op { 0 };
  size_t order { 0 };
  size_t offset  { 0 };
  size_t conv_type { 0 };
  size_t incr_vertices { 0 };
  int copyFromAttr { -1 };
  struct AttribDesc *desc { 0 };
  struct AttribDesc *copyAttribDesc { 0 };
  std::vector<AttribOpFuncData> funcDataConversions;
};
using AttribDataOp = std::vector< AttribOp >;

/**
 * defines an attribute that is used in a shader.  this description has all of the necessary information
 * for our "optimize" function to generate either an array for input into the VBO or a call to the
 * related glVertexAttrib() call when this attribute has the same value throughout the CGO.
 *
 * attr_name - the name of this attribute inside the shaders
 * order - order of attribute used in VBO
 * attrOps - all AttribOp for this particular attribute.  This allows the user to define how this
 *           attribute gets populated from the primitive CGO's one or many CGO operations.
 * default_value - pointer to the default value of this attribute (optional, needs to be the same
 *                 size of the attribute's type)
 * repeat_value/repeat_value_length - specified if the attribute has repeating values
 *                                    repeat_value - a pointer to the type and data for repeat values
 *                                    repeat_value_length - number of repeat values
 * type_size - size of type for this attribute (e.g., GL_FLOAT, GL_UNSIGNED_BYTE)
 * type_dim - number of primitives (i.e., type_size) for each vertex of this attribute
 * data_norm - whether this attribute is normalized when passed to the VBO (GL_TRUE or GL_FALSE)
 *
 */
struct AttribDesc {
  AttribDesc(
      const char* _attr_name, VertexFormat _format, AttribDataOp _attrOps = {})
      : attr_name(_attr_name)
      , m_format(_format)
      , attrOps(_attrOps)
  {
  }
  const char * attr_name { nullptr };
  VertexFormat m_format { VertexFormat::Float };
  int order { 0 };
  AttribDataOp attrOps { };
  unsigned char *default_value { nullptr };
  unsigned char *repeat_value { nullptr };
  int repeat_value_length { 0 };
};
using AttribDataDesc = std::vector< AttribDesc >;

class GPUBuffer {
  friend class CShaderMgr;
public:
  virtual ~GPUBuffer() {};
  virtual size_t get_hash_id() { return _hashid; }
  virtual void bind() const = 0;
protected:
  virtual void set_hash_id(size_t id) { _hashid = id; }
private:
  size_t _hashid { 0 };
};

// Forward Decls
class FramebufferGL;
class RenderbufferGL;

/***********************************************************************
 * RENDERBUFFER
 ***********************************************************************/
namespace rbo {
  enum storage {
    DEPTH16 = 0,
    DEPTH24,
    COUNT
  };

  void unbind();
};

class RenderbufferGL : public GPUBuffer {
  friend class FramebufferGL;
  friend class CShaderMgr;
public:
  RenderbufferGL(int width, int height, rbo::storage storage) :
    _width(width), _height(height), _storage(storage) {
    genBuffer();
  }
  ~RenderbufferGL() {
    freeBuffer();
  }

  void bind() const override;
  void unbind() const;

private:
  void genBuffer();
  void freeBuffer();

protected:
  uint32_t     _id;
  int          _dim[2];
  int          _width;
  int          _height;
  rbo::storage _storage;
};

/***********************************************************************
 * TEXTURE
 ***********************************************************************/
namespace tex {
  enum class dim : int {
    D1 = 0,
    D2,
    D3,
    COUNT
  };
  enum class format : int {
    R = (int)dim::COUNT,
    RG,
    RGB,
    RGBA,
    COUNT
  };
  enum class data_type : int {
    UBYTE = (int)format::COUNT,
    FLOAT,
    HALF_FLOAT,
    COUNT
  };
  enum class filter : int {
    NEAREST = (int)data_type::COUNT,
    LINEAR,
    NEAREST_MIP_NEAREST,
    NEAREST_MIP_LINEAR,
    LINEAR_MIP_NEAREST,
    LINEAR_MIP_LINEAR,
    COUNT
  };
  enum class wrap : int {
    REPEAT = (int)filter::COUNT,
    CLAMP,
    MIRROR_REPEAT,
    CLAMP_TO_EDGE,
    CLAMP_TO_BORDER,
    MIRROR_CLAMP_TO_EDGE,
    COUNT
  };
  enum class env_name : int {
    ENV_MODE = (int)wrap::COUNT,
    COUNT
  };
  enum class env_param : int {
    REPLACE = (int)env_name::COUNT,
    COUNT
  };
  const uint32_t max_params = (int)env_param::COUNT;

  void env(tex::env_name, tex::env_param);
};

struct GPUTexture : public GPUBuffer
{
};

class TextureGL : public GPUTexture {
  friend class FramebufferGL;
public:
  // Generates a 1D texture
  TextureGL(tex::format format, tex::data_type type,
                  tex::filter mag, tex::filter min,
                  tex::wrap wrap_s) :
    _dim(tex::dim::D1), _format(format), _type(type),
    _sampling({(int)mag, (int)min, (int)wrap_s, 0, 0})
    {
      genBuffer();
    };
  // Generates a 2D texture
  TextureGL(tex::format format, tex::data_type type,
                  tex::filter mag, tex::filter min,
                  tex::wrap wrap_s, tex::wrap wrap_t) :
    _dim(tex::dim::D2), _format(format), _type(type),
    _sampling({(int)mag, (int)min, (int)wrap_s, (int)wrap_t, 0})
    {
      genBuffer();
    };
  // Generates a 3D texture
  TextureGL(tex::format format, tex::data_type type,
                  tex::filter mag, tex::filter min,
                  tex::wrap wrap_s, tex::wrap wrap_t,
                  tex::wrap wrap_r) :
    _dim(tex::dim::D3), _format(format), _type(type),
    _sampling({(int)mag, (int)min, (int)wrap_s, (int)wrap_t, (int)wrap_r})
    {
      genBuffer();
    };
  ~TextureGL() {
    freeBuffer();
  }

  void bind() const override;
  /**
   * Binds the texture to a specific texture unit
   * @param textureUnit The texture unit to bind to (0, 1, 2, etc)
   */
  void bindToTextureUnit(std::uint8_t textureUnit) const;
  void unbind() const;

  void texture_data_1D(int width, const void * data);
  void texture_data_2D(int width, int height, const void * data);
  void texture_data_3D(int width, int height, int depth, const void * data);

  /**
   * Specifies a 2D texture subimage
   * @param xoffset The x offset of the subimage
   * @param yoffset The y offset of the subimage
   * @param width The width of the subimage
   * @param height The height of the subimage
   * @param data The data to upload
  */
  void texture_subdata_2D(int xoffset, int yoffset, int width, int height, const void* data);

  // CPU-side RGBA copy of a 2D texture, retained for non-GL renderers (Metal)
  // that cannot read back from the (stubbed) GL texture. Only populated in
  // NO_OPENGL builds; empty otherwise. Used for the glyph/label atlas.
  const unsigned char* cpuData() const {
    return m_cpuPixels.empty() ? nullptr : m_cpuPixels.data();
  }
  int cpuWidth() const { return _width; }
  int cpuHeight() const { return _height; }
  // Monotonically increasing counter bumped on every CPU-copy mutation so a
  // renderer can detect when its uploaded texture is stale and re-upload.
  std::uint64_t cpuGeneration() const { return m_cpuGeneration; }

private:
  void genBuffer();
  void freeBuffer();

private:
  const tex::dim           _dim;
  const tex::format        _format;
  const tex::data_type     _type;
  const std::array<int, 5> _sampling;
  uint32_t                 _id     { 0 };
  int                      _width  { 0 };
  int                      _height { 0 };
  int                      _depth  { 0 };
  std::vector<unsigned char> m_cpuPixels;     // RGBA8, size = _width*_height*4
  std::uint64_t              m_cpuGeneration { 0 };
};

/***********************************************************************
 * FRAMEBUFFER
 ***********************************************************************/
namespace fbo {
  enum attachment {
    COLOR0 = 0,
    COLOR1,
    COLOR2,
    COLOR3,
    DEPTH,
    COUNT
  };

  // global unbind for fbos
  void unbind();
}

class FramebufferGL : public GPUBuffer {
  friend class CShaderMgr;
public:
  FramebufferGL() {
    genBuffer();
  }
  ~FramebufferGL() {
    freeBuffer();
  }

  void attach_texture(TextureGL * texture, fbo::attachment loc);
  void attach_renderbuffer(RenderbufferGL * renderbuffer, fbo::attachment loc);
  void print_fbo();

  void bind() const override;
  void unbind() const;
  void blitTo(const FramebufferGL& dest, glm::ivec2 srcExtent, glm::ivec2 dstOffset);
  void blitTo(std::uint32_t dest_id, glm::ivec2 srcExtent, glm::ivec2 dstOffset);
  std::uint32_t id() const noexcept { return _id; }

private:
  void genBuffer();
  void freeBuffer();
  void checkStatus();

protected:
  uint32_t _id { 0 };
  std::vector<std::tuple<size_t, fbo::attachment>> _attachments;
};


/***********************************************************************
 * RENDERTARGET
 *----------------------------------------------------------------------
 * A 2D render target that automatically has depth, used for postprocess
 ***********************************************************************/
struct rt_layout_t {
  enum data_type   { UBYTE, FLOAT };
  rt_layout_t(uint8_t _nchannels, data_type _type)
    : nchannels(_nchannels), type(_type) {}
  rt_layout_t(uint8_t _nchannels, data_type _type, int _width, int _height)
    : nchannels(_nchannels), type(_type), width(_width), height(_height) {}
  uint8_t     nchannels;
  data_type   type;
  int         width  { 0 };
  int         height { 0 };
};

class RenderTargetGL : public GPUBuffer {
  friend class CShaderMgr;
public:
  using shape_type = glm::ivec2;

  RenderTargetGL(shape_type size) : _size(size) {}
  RenderTargetGL(int width, int height) : _size(width, height) {}
  ~RenderTargetGL();

  void bind() const override { bind(true); };
  void bind(bool clear) const;
  void bindFBORBO() const
  {
    _fbo->bind();
    _rbo->bind();
  }

  void layout(std::vector<rt_layout_t>&& desc, RenderbufferGL * with_rbo = nullptr);
  void resize(shape_type size);

  const shape_type& size() const { return _size; };

  RenderbufferGL* rbo() const noexcept { return _rbo; }
  FramebufferGL* fbo() const noexcept { return _fbo; }
  const std::vector<TextureGL*>& textures() const noexcept { return _textures; }

  void blitTo(std::uint32_t dest_id, glm::ivec2 dstOffset);
  void blitTo(const RenderTargetGL& dest, glm::ivec2 dstOffset);

protected:
  bool _shared_rbo { false };
  shape_type _size;
  FramebufferGL * _fbo;
  RenderbufferGL * _rbo;
  std::vector<rt_layout_t> _desc;
  std::vector<TextureGL *> _textures;
};
