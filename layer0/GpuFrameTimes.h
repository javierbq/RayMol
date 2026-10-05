/*
 * GPU frame times (#616, lighting epic #610): the readout behind
 * metal_gpu_timing that #623 calibrates the shadow budget with.
 *
 * Pure C++ over plain data: no PyMOLGlobals, no Python, no Metal. The Metal
 * renderer feeds GpuFrameTimes::record() from its live command buffers'
 * completion handlers (Metal's own thread, hence the mutex) and after each
 * offscreen frame, and NSLogs the line record() returns;
 * _cmd.get_gpu_frame_stats() reads the store back. _cmd.gpu_time_summary()
 * runs GpuFrameSummarize() on given samples and _cmd.gpu_time_replay() feeds
 * given frames through record(), so CI tests the statistics, the windows and
 * the log text without a GPU.
 *
 * The log lines (metal_gpu_timing):
 *   RendererMetal: gpu_ms window n=.. median=.. p95=.. max=.. shadow_maps=.. shadow_size=..
 *       mode 1, one per ~1 s window of live frames;
 *   RendererMetal: gpu_ms frame=.. shadow_maps=.. shadow_size=.. offscreen=0|1
 *       mode 2 for every live frame, and every offscreen frame in modes 1 and 2.
 * Times are milliseconds with two decimals. The text never contains a word
 * the L4 console checks grep for (validation, MTLDebug, failed assertion,
 * -[MTL, fail, missing).
 */

#pragma once

#include <cstddef>
#include <mutex>
#include <string>
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

/// The mode-1 line: the summary of one window of live frames.
std::string GpuFrameWindowLine(
    const GpuFrameSummary& s, int shadowMaps, int shadowSize);
/// The per-frame line (mode 2, and offscreen frames).
std::string GpuFrameLine(
    double ms, int shadowMaps, int shadowSize, bool offscreen);

/**
 * A ring of the last kCapacity GPU frame times plus the open mode-1 window,
 * safe to fill from Metal's completion thread and read from the main thread.
 */
class GpuFrameTimes
{
public:
  static constexpr std::size_t kCapacity = 120;
  static constexpr double kWindowSeconds = 1.0;

  /**
   * Record one frame of `ms` GPU milliseconds that drew `shadowMaps` studio
   * shadow maps of `shadowSize` texels per side, at `nowSec` (any monotonic
   * clock, in seconds; live frames only). Returns the line to log, or "":
   * - mode <= 0, or `ms` not finite or negative: nothing is recorded, "";
   * - an offscreen frame: GpuFrameLine(.., true); it never enters a window;
   * - mode 2: GpuFrameLine(.., false) for every live frame;
   * - mode 1: the live frame joins the open window, and the window closes
   *   with GpuFrameWindowLine (over its frames, with this frame's maps and
   *   size) on the first frame after clear() -- so a single redraw logs --
   *   and then on the first frame at least kWindowSeconds after the previous
   *   line.
   * Every recorded frame also enters the ring (report()).
   */
  std::string record(double ms, int shadowMaps, int shadowSize, int mode,
      bool offscreen, double nowSec);
  /// The summary of what is held, and the latest frame. False when empty.
  bool report(GpuFrameReport& out, int mode) const;
  /// Forget everything, the open window included.
  void clear();

private:
  mutable std::mutex m_mutex;
  std::vector<double> m_ring;
  std::size_t m_next = 0;
  double m_lastMs = 0.0;
  int m_shadowMaps = 0;
  int m_shadowSize = 0;
  std::vector<double> m_window; ///< live mode-1 frames since the last line
  bool m_windowStarted = false; ///< a window line was logged since clear()
  double m_windowStart = 0.0;   ///< when the last window line was logged
};

} // namespace pymol
