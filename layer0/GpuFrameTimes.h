/*
 * GPU frame times (#616, lighting epic #610): the readout behind
 * metal_gpu_timing that #623 calibrates the shadow budget with.
 *
 * Pure C++ over plain data: no PyMOLGlobals, no Python, no Metal. The Metal
 * renderer feeds GpuFrameTimes from its command buffers' completion handlers
 * (Metal's own thread, hence the mutex); _cmd.get_gpu_frame_stats() reads it
 * back, and _cmd.gpu_time_summary() runs GpuFrameSummarize() on given samples
 * so CI can test the statistics without a GPU.
 */

#pragma once

#include <cstddef>
#include <mutex>
#include <vector>

namespace pymol
{

/// Statistics over GPU frame times (milliseconds).
struct GpuFrameSummary {
  int count = 0;      ///< samples used (finite and >= 0)
  double mean = 0.0;
  double median = 0.0; ///< the middle sample, or the mean of the two middle
  double p95 = 0.0;    ///< nearest rank: the ceil(0.95 n)-th smallest
  double max = 0.0;
};

/**
 * The summary of `samples`. NaN, infinities and negative values are dropped;
 * with nothing left every field is 0.
 */
GpuFrameSummary GpuFrameSummarize(std::vector<double> samples);

/// What _cmd.get_gpu_frame_stats() returns.
struct GpuFrameReport {
  GpuFrameSummary summary; ///< over the last kCapacity frames
  double lastMs = 0.0;     ///< the latest frame
  int mode = 0;            ///< metal_gpu_timing when it was recorded
  int shadowMaps = 0;      ///< studio shadow maps in the latest frame
  int shadowSize = 0;      ///< their texels per side (0 = none)
};

/**
 * A ring of the last kCapacity GPU frame times, safe to fill from Metal's
 * completion thread and read from the main thread.
 */
class GpuFrameTimes
{
public:
  static constexpr std::size_t kCapacity = 120;

  /// Record one frame (`ms` not finite or negative is ignored).
  void add(double ms, int shadowMaps, int shadowSize);
  /// The summary of what is held, and the latest frame. False when empty.
  bool report(GpuFrameReport& out, int mode) const;
  /// Forget everything.
  void clear();

private:
  mutable std::mutex m_mutex;
  std::vector<double> m_ring;
  std::size_t m_next = 0;
  double m_lastMs = 0.0;
  int m_shadowMaps = 0;
  int m_shadowSize = 0;
};

} // namespace pymol
